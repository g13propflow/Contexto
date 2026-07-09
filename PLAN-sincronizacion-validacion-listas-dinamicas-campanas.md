# PLAN — Sincronización y validación de listas dinámicas durante la creación de campañas

> Estado: **análisis / plan** (sin implementar). Historia de usuario: *"Sincronización y validación de listas dinámicas durante la creación de campañas"*.
> Rama / ticket: **`fix/SCRUM-1326`** (prefijo del commit; sin tags en comentarios de código).

## Decisiones tomadas (usuario)

1. **Canales:** aplica a **ambos** (WhatsApp `CreateCampaignWizard.vue` y Email `CreateEmailCampaignWizard.vue`).
2. **Pantalla de validación:** **panel inline** dentro del paso `audience` (Opción A recomendada). No se agrega un paso nuevo al wizard.
3. **Ticket:** `fix/SCRUM-1326`.
4. **Listas estáticas vacías:** **fuera de alcance.** El bloqueo por "lista vacía" aplica **solo a listas dinámicas**, exactamente como pide la HU. Las estáticas mantienen su comportamiento actual (no se bloquean aunque estén vacías).

---

## 1. Resumen ejecutivo

Cuando el Marketing Lead selecciona una **lista dinámica** en el flujo de creación de campaña (modo *"Usar lista existente"*), el sistema debe:

1. **Sincronizar** la lista en tiempo real (re-evaluar sus criterios → recalcular su membresía) antes de dejar avanzar.
2. **Mostrar una pantalla de validación** con la audiencia resultante: nombre, tipo (Dinámica), cantidad de leads y el listado de leads.
3. **Bloquear** la continuación si la lista queda vacía, mostrando en rojo *"Lista sin leads, por favor selecciona otra lista."* y permitiendo volver a elegir otra lista.
4. Si hay ≥1 lead, permitir **Continuar** conservando esa audiencia recién sincronizada.
5. Validar el "no vacío" **en frontend y en backend**.

**Hallazgo clave:** casi toda la maquinaria de listas dinámicas ya existe y está probada. Esta HU es principalmente **orquestación en el frontend** + **una guarda de validación en el backend**. Las "Consideraciones técnicas" de la HU (reutilizar lógica existente, no duplicar reglas, misma resolución que el envío real) se satisfacen reutilizando lo que ya hay.

---

## 2. Qué ya existe (reutilizable) — no reimplementar

### Backend (`app-saas-service`)

| Pieza | Ubicación | Rol en esta HU |
|---|---|---|
| Discriminador `list_type` (`static`/`dynamic`) + `criteria` (JSON AND/OR) | `app/db/models.py` `DistributionList` (~4611-4668) | Identifica listas dinámicas |
| Snapshot de membresía | `DistributionListLead` (~4671-4693) + `member_count`, `last_recalculated_at`, `last_recalc_status`, `last_recalc_error` | Resultado de la sincronización |
| **Resolver criterios → leads** | `app/services/lead_segment_resolver.py` (`resolve_lead_ids`, `count`) | Única fuente de verdad de "quién cumple los criterios" (aplica supresiones) |
| **Materialización (sync real)** | `app/db/repositories/distribution_list_repository.py` `materialize_dynamic_list(list_id, now)` (~295-344) | Borra + recalcula snapshot, estampa `member_count`/estado |
| Orquestador de recalc on-demand | `app/services/dynamic_list_recalc_service.py` `materialize_dynamic_list_for_send(...)` | Recalc de una lista bajo demanda (static → no-op) |
| **Endpoint recalc on-demand** | `POST /distribution-lists/{id}/recalculate` (`app/api/v1/distribution_lists.py` ~446) | La "sincronización" que dispara el frontend |
| Endpoint detalle con leads paginados | `GET /distribution-lists/{id}?page=&page_size=` (~274) devuelve `DistributionListDetailResponse` (`list_type`, `member_count`/`lead_count`, leads) | Alimenta la pantalla de validación |
| Preview-count consistente con el envío | `POST /distribution-lists/preview-count` (~255) | Alternativa/complemento para el conteo |
| Crear campaña desde lista | `POST /distribution-lists/{id}/campaigns` (~480, WhatsApp) y equivalente en `app/api/v1/email_campaigns.py` | Punto donde va la **guarda backend de "no vacío"** |
| Schemas | `app/schemas/distribution_list.py`, `app/schemas/lead_segment.py` | Reutilizar |

> **Invariante de diseño existente:** `preview == snapshot == send` (el mismo `LeadSegmentResolver` alimenta preview-count, materialización batch y el envío en vivo). Debemos preservarlo — no introducir una ruta de resolución paralela.

### Frontend (`app-saas-frontend`)

| Pieza | Ubicación | Rol |
|---|---|---|
| Wizard campaña **WhatsApp** (pasos `name→audience→template→review`) | `src/views/distribution-lists/components/CreateCampaignWizard.vue` | Flujo donde se inserta la validación |
| Wizard campaña **Email** | `src/views/email-campaigns/components/CreateEmailCampaignWizard.vue` | Idem (según alcance, ver §3) |
| Toggle audiencia "Usar lista existente" | dentro del paso `audience` de ambos wizards | Punto de entrada del escenario |
| `recalculate(id)` | `distribution-lists.service.ts` → `POST /distribution-lists/{id}/recalculate` | Dispara sync |
| `getListById(id, {page, page_size})` | `distribution-lists.service.ts` | Trae leads + conteo tras sync |
| Tipos `DistributionListType`, `DistributionList` (`list_type`, `member_count`, `last_recalc_status`, …) | `distribution-lists.service.ts` | Ya modelan lo necesario |
| Badge de tipo | `ListTypeBadge.vue` ("Dinámica"/"Estática") | Reusar en la pantalla de validación |
| Preview de leads de una lista seleccionada | `CreateCampaignWizard.vue` (~713, ya llama `getListById`) | Base a extender |
| Toast / alertas | `useToast`, `useAlertStore` | Errores de sync |

**Nota:** el wizard ya previsualiza leads de la lista seleccionada. Lo *nuevo* es: (a) forzar `recalculate` para listas **dinámicas** antes de mostrar, (b) mostrar explícitamente tipo + conteo + estado de sync, (c) **bloquear** cuando queda vacía con el mensaje en rojo, y (d) manejo de error de sync.

---

## 3. Alcance (cerrado)

- **Canales:** **ambos**. El patrón de audiencia es casi idéntico entre wizards, así que se implementa primero en WhatsApp (`CreateCampaignWizard.vue`) y se replica en Email (`CreateEmailCampaignWizard.vue`).
- **Listas estáticas:** **sin cambios** (regla de negocio explícita). La sincronización y el bloqueo aplican **solo** a `list_type === 'dynamic'`. Una lista estática vacía **no** se bloquea (fuera de alcance, confirmado por el usuario).
- **Formato de la pantalla de validación:** **panel inline** dentro del paso `audience` (ver §5). No se agrega un paso nuevo al wizard.
- **Ticket:** `fix/SCRUM-1326` (prefijo del commit; sin tags de plan/ticket en comentarios de código).

---

## 4. Diseño Backend (`app-saas-service`)

El backend ya puede sincronizar y contar. Los cambios son mínimos y se concentran en **la guarda de "no vacío" al crear la campaña** (regla: validar también en backend).

### 4.1. Sincronización al seleccionar (reutilizar tal cual)
- El frontend invoca `POST /distribution-lists/{id}/recalculate`. **No requiere cambios** salvo confirmar su respuesta (que devuelva `member_count`/`last_recalc_status` o al menos permita un `GET` posterior fiable).
- Confirmar en `distribution_lists.py` (~446) qué devuelve el endpoint hoy; si solo devuelve 200 sin cuerpo útil, considerar que responda el `DistributionListDetailResponse` actualizado para ahorrar un round-trip. (Mejora opcional, no bloqueante.)

### 4.2. Guarda "no vacío" al crear campaña (cambio principal)
En `POST /distribution-lists/{id}/campaigns` (WhatsApp) y su equivalente Email:
- Si `list.list_type == 'dynamic'`:
  1. **Re-materializar** la lista en ese momento (reutilizar `materialize_dynamic_list` / `materialize_dynamic_list_for_send`) para que la campaña use "la sincronización más reciente" (cumple regla de negocio y evita TOCTOU entre la validación en pantalla y el submit).
  2. Si el `member_count` resultante es `0` → responder **HTTP 422** con un código/mensaje claro (p. ej. `{"detail": {"code": "DYNAMIC_LIST_EMPTY", "message": "..."}}`). No crear la campaña.
- Si `list_type == 'static'`: comportamiento actual sin cambios.
- Verificar interacción con `has_sending_campaign` (al crear no hay envío en curso, debería ser seguro re-materializar).

### 4.3. Errores de sincronización
- `materialize_dynamic_list` ya estampa `last_recalc_status='error'` + `last_recalc_error` y relanza; `LeadSegmentResolver` lanza `SegmentResolverError` → hoy mapeado a 422 en preview-count.
- Asegurar que tanto `recalculate` como la creación de campaña propaguen un error claro (código distinguible del "vacío") para que el frontend muestre "error técnico, reintenta" y **no** el mensaje de "lista vacía".

### 4.4. Volúmenes grandes
- El listado de leads en la pantalla de validación se sirve **paginado** vía `GET /distribution-lists/{id}?page=&page_size=` (ya soportado). No cargar todos los leads de golpe.
- La materialización es un `delete + bulk insert` ya existente; validar que el tamaño de página por defecto sea razonable.

### 4.5. Sin migraciones
- No se anticipan cambios de esquema (todos los campos ya existen). Si finalmente no hay `alembic revision`, evitamos el *landmine* de drift/migraciones ya conocido.

---

## 5. Diseño Frontend (`app-saas-frontend`)

### 5.1. Ubicación en el wizard
Dentro del paso **`audience`**, modo *"Usar lista existente"*. Al seleccionar una lista:

- Si es **estática** → comportamiento actual (preview de leads como hoy).
- Si es **dinámica** → disparar el flujo de sincronización + validación descrito abajo.

**Opción recomendada (A): panel inline** dentro del paso `audience` (menos fricción, encaja con el stepper de 4 pasos y el gating `canAdvance` ya existente).
**Opción alternativa (B): paso dedicado** "Validar audiencia" insertado entre `audience` y `template`. Más fiel a la palabra "pantalla" de la HU pero más invasivo (cambia índices de pasos, stepper, navegación). Recomendado solo si negocio exige una pantalla separada.

### 5.2. Estados de UI (secuencia para lista dinámica)
1. **Sincronizando…** (spinner + texto "Sincronizando lista dinámica…"). Deshabilitar "Continuar". Llamar `recalculate(id)`.
2. **Sincronización OK + con leads** → mostrar tarjeta de validación:
   - Nombre de la lista.
   - Tipo (badge **Dinámica** — reutilizar `ListTypeBadge`).
   - **Cantidad total de leads** (de `member_count`/`lead_count`).
   - **Listado de leads** paginado / con carga incremental (`getListById(id, {page, page_size})`).
   - Botón **Continuar** habilitado.
   - Indicador de "sincronizado hace un momento" (`last_recalculated_at`).
3. **Sincronización OK + vacía** → mensaje en **rojo** (estilo error): **"Lista sin leads, por favor selecciona otra lista."**; "Continuar" **deshabilitado**; usuario puede volver a elegir otra lista (el selector permanece accesible).
4. **Error técnico de sync** → mensaje de error diferenciado (p. ej. "No se pudo sincronizar la lista. Intenta de nuevo."), botón **Reintentar**, "Continuar" deshabilitado. No mostrar el mensaje de "lista vacía".

### 5.3. Gating de navegación
- Extender `canAdvance` del paso `audience`: para lista dinámica, exigir `syncStatus === 'ok' && audienceCount > 0`.
- Asegurar que cambiar de lista/re-seleccionar **resetea** el estado de sync (evitar mostrar conteo en caché de una lista anterior — cumple la consideración técnica de "evitar información en caché o desactualizada").

### 5.4. Reutilización de datos hacia el submit
- Al lanzar la campaña (`createCampaign(listId, …)`), la audiencia es la del snapshot recién sincronizado. El backend re-materializa por seguridad (§4.2), por lo que ambos lados quedan consistentes.
- Manejar el caso borde: si entre la validación y el submit el backend devuelve `DYNAMIC_LIST_EMPTY` (422), volver a mostrar el estado "vacía" y regresar al paso de selección.

### 5.5. UX/UI (según preferencia registrada del proyecto)
- Estados de carga, vacío y error explícitos; feedback inmediato; usar patrones/componentes existentes (`ListTypeBadge`, toasts, tarjetas del wizard).
- **Verificación visual en navegador** de los 3 estados (con leads / vacía / error) antes de dar por lista la tarea.

---

## 6. i18n

- Añadir claves nuevas en `src/locales/es.json` y `en.json` bajo el bloque `distributionLists.wizard` (y `emailCampaigns.wizard` si aplica):
  - `syncingDynamicList`, `audienceValidationTitle`, `listName`, `listType`, `leadCount`, `emptyListError` (= "Lista sin leads, por favor selecciona otra lista."), `syncErrorRetry`, `retry`, `syncedJustNow`.
- Reutilizar el badge de tipo. (Ojo: hoy varias etiquetas de tipo/segmentación están **hardcodeadas en español** en `CreateListModal.vue`/`ListTypeBadge.vue`; no es objetivo de esta HU migrarlas, pero las claves **nuevas** sí deben ir por i18n.)

---

## 7. Manejo de errores y casos borde

- **Sync falla técnicamente** → bloquear + mensaje de error + reintentar (Escenario/consideración de la HU).
- **Lista sin leads** → mensaje rojo específico + bloqueo (Escenario 3).
- **Cambio de lista** → resetear conteo/estado previo.
- **TOCTOU** (la lista cambia entre validar y crear) → guarda backend re-materializa y puede devolver 422; frontend lo maneja.
- **Lista dinámica con campaña en envío** → verificar `has_sending_campaign` (poco probable durante creación).
- **Volumen alto** → paginación/carga incremental del listado.
- **Lista estática vacía** → fuera de alcance (comportamiento actual). No se bloquea.

---

## 8. Testing

### Backend
- Test de `POST /distribution-lists/{id}/campaigns` con lista **dinámica que resuelve a 0 leads** → 422 `DYNAMIC_LIST_EMPTY`, no crea campaña.
- Test con lista dinámica **con leads** → crea campaña usando snapshot recién materializado.
- Test de lista **estática** → sin cambios de comportamiento.
- Test de propagación de error de resolución (código distinto al de "vacío").
- (Reutilizar/extender tests existentes de `lead_segment_resolver` / materialización.)

### Frontend
- Verificación visual (navegador) de los 3 estados en el paso audience.
- Prueba de gating: "Continuar" deshabilitado en vacío/error, habilitado con leads.
- Prueba de reset al cambiar de lista.
- `npm run type-check`.

---

## 9. Plan de implementación por fases

1. **Confirmar contrato del endpoint `recalculate`** (respuesta actual) y decidir si devuelve el detalle actualizado. *(exploración corta)*
2. **Backend — guarda "no vacío" al crear campaña** (WhatsApp) + errores diferenciados. Tests.
3. **Backend — replicar guarda en Email** (`app/api/v1/email_campaigns.py`). Tests.
4. **Frontend — WhatsApp**: flujo sync → validación → bloqueo/continuar en el paso audience; i18n; gating; reset. Verificación visual (3 estados).
5. **Frontend — Email**: replicar. Verificación visual (3 estados).
6. **Auto-doc** de la tarea en `Projects/auto-doc/` (convención del proyecto) + commit con prefijo `fix/SCRUM-1326` (pedir OK antes de commitear).

---

## 10. Riesgos y notas

- **Doble materialización** (al seleccionar y al crear): costo aceptable y garantiza frescura; documentarlo.
- **Consistencia preview/envío**: preservar el uso del mismo `LeadSegmentResolver`; no crear rutas paralelas de conteo.
- **Alcance de canales**: ambos (WhatsApp + Email); duplicar el patrón con cuidado de no divergir la lógica entre wizards.
- **Migraciones**: no se prevén; si aparecieran, recordar el drift conocido de Alembic/BD Azure (el contenedor solo monta `./app`).
- **Convenciones**: sin menciones a IA en commits; sin tags de plan/ticket en comentarios de código; prefijo `SCRUM-1326` en el mensaje de commit sí.

---

## Anexo — Decisiones (cerradas)

1. Canales: **ambos** (WhatsApp + Email).
2. Pantalla de validación: **panel inline** en el paso audiencia.
3. Ticket: **`fix/SCRUM-1326`**.
4. Bloqueo por lista vacía: **solo dinámicas** (como pide la HU); estáticas sin cambios.
