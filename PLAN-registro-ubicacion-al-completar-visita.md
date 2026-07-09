# PLAN — Registro obligatorio de ubicación al completar una visita

> HU: capturar la **geolocalización del dispositivo del asesor** en el instante en que marca una visita como completada, almacenarla asociada al evento de la visita (lat/long/precisión/fecha-hora + dirección por reverse geocoding) y mostrarla en modo solo-lectura (con mapa) en el detalle del evento.
>
> Estado: **plan aprobado, no desarrollado.** Todas las decisiones de §0 cerradas.
> Rama: **`feature/SCRUM-1329`** (ambos repos afectados).

---

## 0. Decisiones a confirmar antes de implementar

1. **Fuente de verdad del almacenamiento** → **calendar-service**, sobre la fila del evento (`calendars.calendar_events`), porque la HU pide "ubicación asociada al **evento** de la visita" y el evento vive únicamente ahí. **Decidido** — justificación completa en §7.
2. **Enforcement + plumbing** → **Opción A**: calendar-service es el único escritor/validador; el frontend envía la ubicación a `POST /v1/events/:id/attended` **antes** de tocar el estado del lead. **Decidido** (ver §6 para el orden de llamadas; Opción B descartada).
3. **Reverse geocoding** → servicio nuevo en calendar-service, **best-effort y no bloqueante**: si falla, se guardan las coordenadas igual y la dirección queda `NULL` (resoluble después). Proveedor: Google Geocoding API con **key server-side propia** del servicio. Además, **fallback en cliente**: cuando `completion_address` venga `NULL`, resolver la dirección con el **Geocoder del propio SDK de Google Maps** ya cargado en el front (misma `VITE_GOOGLE_MAPS_API_KEY`). **Decidido.**
4. **Mapa embebido** → **`vue3-google-map` + `VITE_GOOGLE_MAPS_API_KEY`** (reusar el patrón de `AdvisorMap.vue`), envuelto en un wrapper read-only `VisitLocationMap.vue`. **Decidido** (descartado el `<iframe>`: desde lat/lng crudos la *Maps Embed API* también exige key, y la variante sin key es no oficial; el SDK ya es dependencia y da marker exacto + Geocoder para el fallback de §0.3). Ver §5.5.
5. **Permiso de visualización** → **basado en roles**; por ahora **solo el rol `owner`** ve el bloque de ubicación en el detalle del evento. **Decidido** (diseñar como gate por rol para poder ampliar a más roles después sin refactor; ver §5.5). *(Confirmar en review el nombre exacto del rol/permiso en el sistema de auth.)*
6. **Ticket SCRUM** → **`SCRUM-1329`**. Rama `feature/SCRUM-1329` en `app-saas-frontend` y `calendar-service` (y en `app-saas-service` si se hace el espejo opcional de §4). **Decidido.**

---

## 1. Estado actual (hallazgos de la investigación)

### Concepto de "completar visita"
- No existe una etapa literal "Visita completada". En la UI es **`cita_completada`** → se muestra como **"Visita Realizada"** (`src/types/leads.ts:93`, `src/locales/es/leads.ts:272`).
- Completar = lead `→ cita_completada` **y** evento de calendario `→ appointment_state = 'atendida'`.
- Los eventos viven **solo en calendar-service**. app-saas-service guarda la referencia en `Lead.extra_data["calendar_event_id"]`.

### Frontend (`app-saas-frontend`) — 3 puntos de entrada
Los tres convergen en el componente `ClosingModal` (modal de feedback de cierre de visita):
1. **CTA del card del lead** — `LeadCard.vue:200-205` emite `mark-visit-completed` → sube por `KanbanColumn`/`KanbanView` → `LeadsView.vue:2606 handleMarkVisitCompleted` → `openClosingModal(lead, 'cita_completada')`.
2. **Drag & drop a "Visita Realizada"** — `KanbanColumn.vue` `drag-change` → `LeadsView.vue:3113 handleDragChange` → rama `cita_completada` (`:3154-3162`): revierte el drag y abre `openClosingModal`.
3. **Modal de detalle del evento** — `EventModal.vue:372-390` botón "Visita realizada" → `handleMarkVisitCompleted` (`:1337`) → abre su **propia** instancia de `ClosingModal` (`:430-440`) → `submitEventVisitFeedback` (`:1355-1528`).

Handlers de persistencia:
- CTA + drag → `submitVisitFeedback` (`LeadsView.vue:2616-2714`): crea comentario, `leadsService.updateLead(id, {status:'cita_completada', ...})` (`:2663`), luego `eventService.markEventAttended(activa.id)` (`:2685-2689`) tras `getEventsByLeadId`.
- EventModal → `submitEventVisitFeedback` (`EventModal.vue:1355`): su propia versión (además crea/completa tareas).

Servicios/endpoints:
- `leads.service.ts:366 updateLead` → `apiFetch` → app-saas-service `PATCH /api/v1/leads/{id}`.
- `calendar.service.ts:280 markEventAttended(id)` → `calendarApiFetch` → **`POST /v1/events/{id}/attended`** con body `{}` hoy.

Infra reutilizable:
- **Geolocalización: NO existe** (`navigator.geolocation`, `useGeolocation`, `getCurrentPosition` → 0 resultados). Hay que crearla.
- **Mapa: SÍ existe** `vue3-google-map` (`package.json:57`) usado en `src/components/advisors/AdvisorMap.vue` con `VITE_GOOGLE_MAPS_API_KEY`.
- Modal de detalle: `EventModal.vue` (controlado por `composables/useEventModal.ts`).

### calendar-service (fuente de verdad del evento)
- Entidad `calendars.calendar_events` (`src/modules/events/entities/calendar_events.entity.js`): tiene `location` STRING(255) de **texto libre** y `metadata` TEXT/JSON. **No hay lat/long/coordenadas.**
- Ciclo de vida en `appointment_state`: `programada|atendida|no_asistio|cancelada|reagendada`. "Completada" = **`atendida`**.
- Completado: `POST /api/events/:id/attended` (`routes/events/calendar_events.routes.js:244-250`, auth dual JWT/API-key, permisos `calendario.edit|tasks.edit`) → `controller.markAttended` (`:620-639`, **hoy no lee el body**) → `commands.markAttended` (`:438`) → `_markOutcome` (`:470-519`, **idempotente**: valida `allowedFrom`, hace `event.update({appointment_state})` y registra en el timeline del lead).
- Migraciones: `src/migrations/00N_*.sql` (T-SQL, idempotentes con guardas `INFORMATION_SCHEMA`; ejemplo `003_add_appointment_state_to_calendar_events.sql`).
- El `lead_id` se obtiene de los attendees (`calendar_event_attendees.entity.js`).
- **No hay reverse geocoding ni cliente de mapas.**
- Adapters salientes a saas-service en `src/infrastructure/adapters/saas-service/` (patrón axios + `X-API-Key` + `X-Tenant-ID`, nunca lanzan). **No hay callback OUT al completar** (la dirección normal es saas → calendar).

### app-saas-service (orquestador)
- `lead_service.py:149 update_status_with_lead` — al pasar a `CITA_COMPLETADA`/`"visita_realizada"` (rama `:361-376`) llama `calendar_service.mark_attended(event_id, tenant_id)` **fire-and-forget** (un fallo no revierte la transición).
- `calendar_microservice.py:397 mark_attended` → `POST /v1/events/:id/attended` (body actual sin ubicación).
- No hay tabla de eventos local. Sí `AdvisorLocation` (`models.py:1791`: `latitude/longitude/accuracy/recorded_at`) y `LeadActivityTimeline` (`models.py:2859`, `event_metadata` JSON).
- El evento canónico "visita completada" en timeline es `stage_changed → cita_completada` (`timeline_service.py track_stage_changed`).
- **No hay reverse geocoding**; sí clientes Google (Roads/Directions/Static Maps) que sirven de patrón de feature-gate por API key.

---

## 2. Arquitectura de la solución (resumen)

```
[Asesor pulsa "completar" en cualquiera de los 3 flujos]
        │
        ▼
[Frontend] useVisitCompletion (composable centralizado)
   1. Consulta Permissions API (granted | prompt | denied/bloqueado)
   2. getCurrentPosition({enableHighAccuracy, timeout, maximumAge:0})  ← captura fresca
   3. Si denegado/bloqueado/timeout → aborta, NO completa, muestra mensaje
        │  (con {latitude, longitude, accuracy?, captured_at})
        ▼
[calendar-service] POST /v1/events/:id/attended  { completion_location: {...} }
   - Valida presencia+forma de la ubicación (en la transición real)
   - Persiste columnas completion_* (inmutable: no sobrescribe si ya existen)
   - Reverse geocoding best-effort → completion_address (o NULL si falla)
   - Transiciona appointment_state → 'atendida' (idempotente)
        │
        ▼
[Frontend] recién entonces updateLead(status='cita_completada')  (app-saas-service)
   - mark_attended interno (fire-and-forget) llega 2º → evento ya 'atendida' → no-op
        │
        ▼
[Visualización] EventModal lee completion_* del getEvent → bloque solo-lectura + mapa
```

Punto único de captura en el frontend → **evita duplicidad** entre los 3 flujos (requisito de la HU). Punto único de escritura/validación en calendar-service → integridad.

---

## 3. calendar-service — cambios (fuente de verdad)

### 3.1 Migración `008_add_completion_location_to_calendar_events.sql`
Nuevas columnas en `calendars.calendar_events` (patrón idempotente de `003_...`):
- `completion_latitude` FLOAT NULL
- `completion_longitude` FLOAT NULL
- `completion_accuracy` FLOAT NULL  *(precisión en metros; opcional)*
- `completion_captured_at` DATETIME2 NULL  *(timestamp de captura en el navegador)*
- `completion_address` NVARCHAR(500) NULL  *(reverse geocoding; diferible)*

*(Sin CHECK constraint estricto de rango para no romper inserts; la validación de rango vive en el controller/command.)*

### 3.2 Entidad `calendar_events.entity.js`
Añadir los 5 campos al modelo Sequelize (tipos `FLOAT`/`DATE`/`STRING(500)`, todos `allowNull: true`).

### 3.3 Command `_markOutcome` / `markAttended` (`calendar_events.commands.js`)
- `markAttended(eventId, tenantId, actor, completionLocation)` — nuevo parámetro.
- Validación (solo cuando se está **transicionando** a `atendida`, no en el no-op idempotente): exigir `latitude` y `longitude` numéricos y en rango (`lat∈[-90,90]`, `lng∈[-180,180]`). Si falta → error 4xx específico (`LOCATION_REQUIRED`).
- Persistir `completion_*` en el mismo `event.update(...)` que fija `appointment_state`.
- **Inmutabilidad**: si el evento ya tiene `completion_latitude`, no sobrescribir (se conserva la primera captura).
- **Fill-in ante idempotencia**: si el evento ya está `atendida` pero **sin** ubicación y llega una llamada con ubicación válida, permitir rellenar los `completion_*` (cubre el caso de que el estado se haya fijado por otra ruta antes). Esto acota el problema de orden de §6.
- Reverse geocoding: llamar al adapter (§3.5) dentro de try/catch; si resuelve, setear `completion_address`; si falla, dejar `NULL` (no abortar el guardado).

### 3.4 Controller + ruta
- `controller.markAttended` (`calendar_events.controller.js:620`): leer `req.body.completion_location` y pasarlo al command. Devolver 4xx claro si falta en la transición.
- Ruta `POST /api/events/:id/attended`: sin cambios de path; documentar el nuevo body opcional.

### 3.5 Adapter de reverse geocoding (nuevo)
- `src/infrastructure/adapters/geocoding/reverse.geocode.js` (patrón axios + timeout corto + "nunca lanza").
- Entrada `{lat, lng}` → llama Google Geocoding API (`https://maps.googleapis.com/maps/api/geocode/json?latlng=...&key=...`) → salida `address` (string) o `null`.
- Feature-gate por **`GOOGLE_MAPS_API_KEY` server-side** (nueva env var del servicio, **distinta** de la key con restricción de referrer del frontend); si no hay key o falla → retorna `null` (degradación limpia, coords se guardan igual).
- Añadir a `.env.example`.
- Complementa al **fallback de cliente** (§5.5): si aquí resuelve `address`, el front no necesita geocodificar; si retorna `null`, el front lo resuelve al visualizar con el Geocoder del SDK.

### 3.6 Lectura del evento
Verificar que el `getEvent`/serializer del evento **exponga** los campos `completion_*` en la respuesta (para que el frontend los pinte). Añadirlos al mapper de salida si filtra columnas.

---

## 4. app-saas-service — cambios (mínimos, Opción A)

Con la Opción A (calendar-service como escritor único y frontend llamando a `/attended` **antes** del cambio de estado), en el **caso normal (con evento)** el `mark_attended` interno de `lead_service.py:361` llega **segundo** y encuentra el evento ya `atendida` → no-op idempotente → **no necesita enviar ubicación**.

Pero el **caso sin evento de calendario** (§8, decidido Opción B) **sí requiere** plumbing aquí, porque no hay fila de evento donde guardar las columnas `completion_*`:
- `PATCH /leads/{id}` (schema del update) **acepta** un objeto de ubicación opcional (`{latitude, longitude, accuracy?, captured_at}`) con validación de rango.
- `update_status_with_lead`: al transicionar a `cita_completada`/`visita_realizada`, **si hay `calendar_event_id`** el flujo normal ya cubre el guardado vía calendar-service; **si no lo hay**, escribir la ubicación en el timeline.
- `timeline_service.track_stage_changed` (evento `stage_changed → cita_completada`): aceptar `location` y persistirla en `event_metadata`. (Sirve además de espejo para dashboards en el caso con evento, si se envía siempre.)
- **Obligatoriedad server-side en este camino**: si el lead no tiene evento y llega la transición sin ubicación, decidir en review si se rechaza el `PATCH` (recomendado, coherente con "ubicación obligatoria") o se registra sin ella. El gate del front ya la exige; el rechazo server-side cierra el hueco de API directa.
- El webhook `webhooks.py:613 /calcom/visit-completed` (hoy solo ack) queda **fuera de alcance**.

---

## 5. app-saas-frontend — cambios (captura + flujos + visualización)

### 5.1 Composable centralizado de captura (nuevo) — el corazón de la HU
`src/composables/useVisitLocation.ts` (o `useGeolocation.ts` + helper). Responsabilidades:
- `getPermissionState()` → usa `navigator.permissions.query({name:'geolocation'})` para distinguir `granted | prompt | denied`.
- `captureLocation()`:
  - Si `denied` (bloqueado permanentemente) → lanza `LOCATION_BLOCKED` (UI: "habilita el permiso desde la configuración del navegador").
  - Si `prompt`/`granted` → `navigator.geolocation.getCurrentPosition(success, error, {enableHighAccuracy:true, timeout:~10-15s, maximumAge:0})` (captura **fresca**, sin reutilizar).
  - Mapear errores del API: `PERMISSION_DENIED` → `LOCATION_DENIED`; `POSITION_UNAVAILABLE`/GPS off → `LOCATION_UNAVAILABLE`; `TIMEOUT` → `LOCATION_TIMEOUT`.
  - Retorna `{ latitude, longitude, accuracy?: number, captured_at: ISOString }`.
- **No** implementar diálogos custom que reemplacen el prompt nativo (regla de la HU): el prompt nativo aparece solo al llamar `getCurrentPosition`.
- Estados de carga expuestos para que el modal muestre "obteniendo ubicación…".

### 5.2 Servicio de calendario
`calendar.service.ts:280 markEventAttended(id, completionLocation)` → enviar el body `{ completion_location: {...} }` en `POST /v1/events/:id/attended`.

### 5.3 Integración en los 3 flujos (una sola lógica)
- **CTA + drag** (`submitVisitFeedback`, `LeadsView.vue:2616`): antes de persistir, `await captureLocation()`; si falla → abortar, no cambiar estado, toast de error específico. **Reordenar**: llamar `markEventAttended(activa.id, location)` **antes** de `updateLead(...)` (ver §6). **Sin evento activo** (§8, Opción B): no se bloquea; enviar la ubicación dentro del `updateLead(...)` (el `PATCH /leads` la persiste en timeline).
- **EventModal** (`submitEventVisitFeedback`, `EventModal.vue:1355`): misma llamada `captureLocation()` + `markEventAttended(event.id, location)` antes del resto.
- Idealmente, el gate de captura se invoca desde el propio `ClosingModal` (compartido por CTA+drag y reutilizado por EventModal) para no duplicar: el modal no confirma hasta tener ubicación válida, y expone estados `capturing | error`.

### 5.4 Mensajería (UX) — estados de permiso
Toasts/mensajes claros por caso (regla + escenarios 4 y 5 de la HU):
- Denegado (`denied` en esta solicitud) → "El acceso a la ubicación es obligatorio para completar la visita."
- Bloqueado permanentemente → "Habilita el permiso de ubicación en la configuración del navegador para completar la visita."
- Timeout / GPS off / sin señal → "No se pudo obtener la ubicación. Verifica el GPS e inténtalo de nuevo."
- Seguir el patrón de [[frontend-best-ux-ui]] (estados de carga, feedback, no dejar el modal en limbo).

### 5.5 Visualización solo-lectura en EventModal
Nuevo bloque en `EventModal.vue` (modo detalle), visible cuando el evento trae `completion_latitude` **y** el usuario tiene permiso de visualización.
- **Gate por rol (§0.5)**: por ahora solo el rol **`owner`**. Implementar con un check de rol reutilizable (composable/store de auth existente — confirmar helper: p. ej. `useAuth`/`userStore.roles`), **no** hardcodeado inline, para poder ampliar a más roles sin refactor. Si no es `owner`, el bloque no se renderiza.
- Dirección legible (`completion_address`; si `null` → **fallback en cliente**: resolver con el `Geocoder` del SDK de Google ya cargado por `vue3-google-map`, misma `VITE_GOOGLE_MAPS_API_KEY`; si tampoco resuelve → mostrar solo coordenadas).
- Coordenadas (lat, lng) + precisión si existe.
- Fecha/hora de captura (`completion_captured_at`, formateada a zona local).
- **Mapa embebido** con un marker en el punto. **Componente nuevo `src/components/calendar/VisitLocationMap.vue`**: wrapper **read-only** sobre `vue3-google-map` (`AdvisorMap.vue` como referencia) — un solo `Marker`/`CustomMarker`, `:disable-default-ui`, gestos/drag desactivados, zoom fijo. Props: `{ lat, lng, accuracy? }`. Reusable si otra vista necesita mostrar un punto.
- **Descartado el `<iframe>`** (ver §0.4): desde lat/lng crudos la Maps Embed API también requiere key y la variante sin key es no oficial; el SDK ya es dependencia y habilita el Geocoder del fallback de dirección.
- Todo **solo-lectura** (sin edición) — regla de inmutabilidad.
- **Caveat operativo**: confirmar que `VITE_GOOGLE_MAPS_API_KEY` tenga habilitadas *Maps JavaScript API* (mapa) y *Geocoding API* (fallback de dirección), y que las restricciones de referrer incluyan los dominios de front (prod/staging).

### 5.6 i18n
Claves nuevas en `src/locales/{es,en}/` (leads/calendar): mensajes de permiso, título del bloque de ubicación, labels (dirección/coordenadas/precisión/capturada el/mapa).

---

## 6. Punto delicado: orden de llamadas y enforcement

**Problema**: hoy `submitVisitFeedback` hace `updateLead` (que dispara el `mark_attended` interno de app-saas-service, **sin** ubicación) **antes** de `markEventAttended` (frontend directo). Como `_markOutcome` es idempotente, el primer `attended` que llegue fija el estado; si es el interno (sin ubicación), el segundo (con ubicación) sería no-op y **se perdería la ubicación**.

**Opción A (recomendada)** — bajo riesgo:
1. Frontend llama `markEventAttended(eventId, location)` **primero** → calendar-service fija `atendida` + guarda ubicación.
2. Luego `updateLead` → el `mark_attended` interno llega 2º, evento ya `atendida` → no-op.
3. Refuerzo servidor: el "fill-in ante idempotencia" (§3.3) permite que, si por cualquier ruta el estado se fijó primero sin ubicación, una llamada posterior con ubicación válida la rellene.
- *Residual*: si la transición a `cita_completada` ocurre por una vía que no pasa por el frontend (API directa), el evento podría quedar sin ubicación. Aceptable para el alcance de la HU (los 3 flujos de UI). Documentar.

**Opción B** — plumbing completo por app-saas-service:
- Frontend envía la ubicación en el `PATCH /leads/{id}`; `update_status_with_lead` la pasa a `mark_attended`; se **elimina** la llamada directa `markEventAttended` del frontend. Ownership único pero más cambios y toca el EventModal de forma distinta. No recomendada salvo que se quiera un único endpoint de entrada.

---

## 7. Almacenamiento en calendar-service — justificación (§0.1)

**Decisión: la ubicación se guarda como columnas en `calendars.calendar_events` (calendar-service) como fuente de verdad.**

### Por qué calendar-service
La ubicación es un **atributo del evento**, y el evento solo existe en calendar-service. app-saas-service **no tiene tabla de eventos**: solo guarda la referencia `Lead.extra_data["calendar_event_id"]`. La entidad "visita" (ciclo `programada → atendida`, asesor, fecha, lead) vive únicamente en `calendar_events`; separar la ubicación de esa fila sería split-brain.

1. **Cardinalidad y ciclo de vida idénticos → columna, no relación.** Es 1:1 (una visita = una ubicación), se crea al pasar a `atendida` y es inmutable después. Se escribe en el **mismo `event.update()`** que ya fija `appointment_state` (`_markOutcome`), misma transacción, sin maquinaria extra.
2. **El punto de escritura ya es el chokepoint de completado.** `POST /v1/events/:id/attended` → `_markOutcome` es *el* lugar donde una visita se completa para todos los llamadores (frontend JWT + server-to-server). Validar ahí "sin ubicación → no completa" garantiza integridad venga de donde venga. Guardarla en app-saas-service pondría la validación en un sitio distinto de donde ocurre la transición → hueco de integridad.
3. **El punto de lectura ya es ese servicio.** El EventModal ya lee el evento desde calendar-service (`getEvent`); añadir `completion_*` a esa respuesta es trivial. Guardar en app-saas-service obligaría a un segundo fetch/join solo para pintar el detalle.
4. **La auditoría de Gerencia/Ops es por-evento.** "¿Se hizo la visita en el lugar correcto?" es una consulta sobre eventos (por asesor/proyecto/fecha); esos campos (`advisor_code`, `calendar_id`, `start_datetime`, `lead_id` vía attendees) ya están en `calendar_events`. La ubicación como columna mantiene todo consultable junto a `appointment_state`/`is_confirmed`.

### El contra honesto (y su mitigación)
calendar-service **no tiene cliente de mapas**; app-saas-service sí (Roads/Directions/Static). Ese es el único argumento real a favor de app-saas: reusar reverse geocoding. Se mitiga porque el reverse geocoding es **best-effort + fallback en cliente** (§0.3), así que el adapter en calendar-service es pequeño (§3.5). El costo de ~un adapter HTTP es menor que partir la fuente de verdad; el *storage* (lo caro de mover) se queda donde pertenece.

### Cuándo se invertiría la decisión
Si el requisito fuera **reporting agregado lead-céntrico** (p. ej. "% de visitas georreferenciadas por asesor" en dashboard) en vez de "ver la ubicación de esta visita". La HU pide mostrarla **en el detalle del evento**, en solo-lectura → servicio del evento.

### Complemento y descartes
- **Complemento opcional**: espejo en `lead_activity_timeline.event_metadata` (app-saas-service) para dashboards que ya leen `stage_changed` (§4).
- **No recomendado**: guardar solo en `metadata` JSON del evento (menos consultable) o solo en `AdvisorLocation` (ese modelo es tracking continuo del asesor, semántica distinta).

---

## 8. Edge cases y reglas
- **Captura fresca siempre** (`maximumAge:0`); no reutilizar ubicaciones previas (regla HU).
- **Una sola ubicación por evento** (inmutable): si ya existe, no se sobrescribe.
- **Reverse geocoding no bloquea el guardado**: fallo → coords guardadas, `address` = `NULL`, resoluble después (o en cliente al visualizar).
- **Sin evento de calendario asociado** al lead (no hay `calendar_event_id`/no hay cita activa) → **Opción B (decidida)**: **no se bloquea**; se captura la ubicación igual y se guarda en el **timeline del lead** (`lead_activity_timeline.event_metadata` del `stage_changed → cita_completada`), ya que no hay fila de evento donde persistir las columnas `completion_*`. Implicaciones:
  - Requiere el **espejo/plumbing en app-saas-service** (§4) para este camino: el `PATCH /leads/{id}` acepta la ubicación y `track_stage_changed` la escribe en `event_metadata`. Esto deja de ser "opcional" y pasa a ser **requerido** para cubrir el caso sin evento.
  - La **captura de ubicación en el front sigue siendo obligatoria** también en este flujo (el gate del composable aplica igual).
  - **Visualización**: cuando la visita se completó sin evento, la ubicación no aparece en el EventModal (no hay evento). Mostrarla en el timeline/detalle del lead queda **fuera del alcance de esta HU** salvo que se pida; registrar como follow-up. (La HU describe la visualización sobre el detalle del **evento**.)
  - Con evento presente (caso normal de los 3 flujos), la fuente de verdad siguen siendo las columnas de `calendar_events` (§3); el timeline es complemento.
- **HTTPS**: `navigator.geolocation` solo funciona en contextos seguros (prod HTTPS y `localhost` OK; verificar dominios de staging).
- **Compatibilidad de navegadores** soportados (Permissions API para geolocation tiene buen soporte; prever fallback si `navigator.permissions` no existe → intentar `getCurrentPosition` directo).
- **Rendimiento**: la captura corre solo al confirmar completación; ninguna solicitud anticipada durante navegación (regla HU).

---

## 9. Testing
- **calendar-service** (Jest): command `markAttended` — con ubicación válida persiste columnas; sin ubicación en transición → error; idempotencia (segunda llamada no sobrescribe); fill-in cuando estaba `atendida` sin ubicación; reverse geocoding mockeado (éxito y fallo → address null pero guarda). Migración aplicable/idempotente.
- **frontend** (Vitest): composable `useVisitLocation` — mock de `navigator.geolocation`/`permissions` para `granted`/`prompt`/`denied`/`timeout`/`unavailable`; `submitVisitFeedback` y `submitEventVisitFeedback` no completan si la captura falla; orden `markEventAttended` antes de `updateLead`.
- **Verificación visual** (regla [[frontend-best-ux-ui]]): los 3 flujos con permiso concedido/denegado/bloqueado; bloque de solo-lectura + mapa en EventModal. Correr [[/verify]] y type-check antes de dar por listo.

---

## 10. Entregables por fase (orden sugerido)
1. **calendar-service**: migración 008 + entidad + command/controller/ruta + adapter reverse geocoding + exposición en getEvent + tests. Aplicar migración (T-SQL, `src/migrations/`).
2. **frontend – captura**: composable `useVisitLocation` + `markEventAttended(id, location)` + integración en los 3 flujos con reordenamiento + mensajería/i18n + tests.
3. **frontend – visualización**: componente `VisitLocationMap.vue` (wrapper read-only de `vue3-google-map`) + bloque solo-lectura en EventModal + fallback de dirección con Geocoder + i18n.
4. **app-saas-service** (requerido para el caso sin evento, §4/§8): `PATCH /leads` acepta ubicación → `update_status_with_lead` → `track_stage_changed` la escribe en `event_metadata`; validación server-side. (También sirve de espejo para dashboards.)
5. Verificación visual end-to-end + type-check + auto-doc en `Projects/auto-doc/` ([[auto-doc-cada-tarea]]).

---

## 11. Notas operativas / riesgos
- **Dos keys de Google Maps distintas**: (1) `GOOGLE_MAPS_API_KEY` **server-side** en calendar-service para el reverse geocoding (sin restricción de referrer, con *Geocoding API* habilitada) y (2) `VITE_GOOGLE_MAPS_API_KEY` **de frontend** (restricción por referrer, con *Maps JavaScript API* + *Geocoding API*) para el mapa y el fallback de dirección — esta ya existe (la usa `AdvisorMap.vue`), solo verificar APIs habilitadas y dominios. Documentar en `.env.example` y avisar para setear en Azure ([[slack-tenant-scrum-1278]] como precedente de "vars + pasos operativos los hace el usuario").
- **Migración calendar-service** corre sobre la misma SQL Server Azure compartida; coordinar deploy (schema `calendars`).
- **No push / no commit sin OK explícito** ([[never-push-only-user]], [[ask-permission-before-commit]]); scripts de prueba al scratchpad ([[no-test-scripts-in-repo]]); sin tags de plan en comentarios de código ([[no-scrum-tags-in-code-comments]]).
- Confirmar las decisiones de §0 antes de empezar a desarrollar.
