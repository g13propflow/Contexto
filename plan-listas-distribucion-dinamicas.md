# Plan — HU-2 / HU-3: Listas de distribución estáticas y dinámicas + filtros avanzados

> Análisis y plan de implementación para que las listas de distribución soporten
> tipo **estático** y **dinámico**, con un constructor de filtros avanzados que
> alimenta el recálculo diario y se reutiliza en campañas (WhatsApp + email) y en
> workflows transaccionales.

---

## 1. Objetivo

| HU | Resumen |
|---|---|
| **HU-2** | La lista tiene tipo explícito (estática/dinámica). Badge visible en listado y detalle. Las dinámicas se recalculan a diario (se muestra fecha del último recálculo + conteo vigente). El batch diario alimenta campañas (broadcast); en workflows transaccionales el segmento se resuelve **en vivo** al trigger. Misma lista consumible por WhatsApp y email. En dinámicas no se agregan/quitan leads a mano; en estáticas sí. |
| **HU-3** | Construir el criterio de una lista dinámica con filtros avanzados (etapa, estado de atención, fuente, geografía, fechas), combinables con AND/OR y agrupación. Vista previa del conteo antes de guardar. El criterio queda persistido y alimenta el recálculo. La resolución respeta supresión (HU-11): un lead en baja nunca entra. |

---

## 2. Estado actual (lo que YA existe — la base está lista)

La infraestructura de distribución ya es **agnóstica de canal** y de **origen de membresía**, lo que reduce mucho el alcance.

| Pieza | Ubicación | Estado |
|---|---|---|
| Tabla `distribution_lists` (campo `channel = whatsapp\|email`) | `app-saas-service/app/db/models.py:4331` | ✅ |
| Tabla `distribution_list_leads` (membresía) | `app/db/models.py` (junto a la anterior) | ✅ |
| Campañas WhatsApp (`Campaign`/`CampaignMessage`) reutilizan la lista | `app/db/models.py:4314+`, `app/temporal/workflows_campaign.py` | ✅ |
| Campañas Email (`EmailCampaign`/`EmailMessage`) reutilizan la lista | `app/db/models_email_campaigns.py`, `workflows_email_campaign.py` | ⚠️ Misma **implementación**, pero cada lista está atada a un `channel` → ver §11.3 |
| Resolución de leads por lista | `app/db/repositories/distribution_list_repository.py` → `get_leads_with_data()` (teléfono), `get_leads_with_email()` (email) | ✅ |
| Workflow `send_email` modo `distribution_list` (resuelve la lista al trigger) | `app/services/workflow_action_executor.py:598` | ✅ (pero resuelve membresía materializada, no criterio) |
| Query builder de leads (~15 filtros) | `app/api/v1/leads.py:1122` `_build_lead_conditions()` | ✅ pero **solo AND plano**, sin OR ni grupos |
| Supresión por canal | `Contact.opt_in_status='opted_out'`, tabla `EmailSuppression`, `Lead.reengagement_opt_out` | ✅ (datos disponibles) |
| Estado de atención (lógica determinística reutilizable) | `app/agents/advisor_supervisor/abandonment.py` (días sin contacto), `lead_age.py` (semanas en etapa); umbrales en `TenantConfig.advisor_supervisor_config` | ✅ definición existe |
| Patrón de scheduler diario en Temporal | `app/temporal/worker.py` (`ensure_*_schedule`, p.ej. `email-campaign-scheduler` cada 5 min, daily-summary diario) | ✅ patrón a copiar |
| Frontend listas/campañas (vistas, service, stores) | `app-saas-frontend/src/views/distribution-lists/`, `src/services/distribution-lists.service.ts` | ✅ |

---

## 3. Brechas (lo que falta — el núcleo de HU-2/HU-3)

1. **Tipo estático/dinámico** no existe en el modelo.
2. **Criterio persistido** (árbol de filtros AND/OR con grupos) no existe.
3. **Resolver recursivo criterio → SQL** (el actual es AND plano).
4. **Capa de supresión** unificada y siempre aplicada en la resolución del segmento (HU-11).
5. **Recálculo batch diario** que materializa la membresía de las listas dinámicas + sella `last_recalculated_at` y conteo.
6. **Resolución en vivo** del criterio para workflows transaccionales (hoy `send_email` lee la membresía materializada, no el criterio).
7. **Guard**: en dinámicas, bloquear agregar/quitar leads a mano.
8. **Endpoint de preview de conteo** antes de guardar.
9. **Frontend**: badge, constructor de filtros AND/OR, preview de conteo, vista de detalle con fecha de recálculo + conteo y sin botones de edición manual.

---

## 4. Decisiones de diseño (confirmadas)

- **Estado de atención**: se reutiliza la definición determinística existente.
  - `descuidado` = días desde el último contacto saliente del asesor > umbral (concepto de `abandonment.py`).
  - `estancado` = semanas/días en la etapa actual (`Lead.status_changed_at`) > umbral (concepto de `lead_age.py` / trigger `lead_same_status_days`).
  - `al_dia` = ninguno de los anteriores.
  - Umbrales tomados de `TenantConfig.advisor_supervisor_config` (mismos que ya usan los KPIs); se expone una **expresión a nivel de lead** simplificada y consistente con esos módulos (ver §6.2).
- **Geografía**: se toma del **proyecto** asociado al lead (`Lead.project_id → Project.city / Project.state`).
- **Supresión (HU-11)**: un lead "en baja" = se excluye SIEMPRE del segmento si cumple **cualquiera** de:
  1. `Contact.opt_in_status = 'opted_out'`.
  2. `Lead.reengagement_opt_out = true`.
  3. `Lead.is_active = false` **o** estado terminal (`descartado` / `cerrado_perdido`).
  4. **Solo canal email**: el email está en `EmailSuppression`.
  - La supresión se aplica en **batch diario, resolución en vivo y preview** (misma función, una sola fuente de verdad).

---

## 5. Modelo de datos — cambios

### 5.1 Migración Alembic sobre `distribution_lists`

Añadir columnas (todas con default para no romper filas existentes → todas pasan a `static`):

| Columna | Tipo | Default | Uso |
|---|---|---|---|
| `list_type` | `String(10)` NOT NULL | `'static'` | `'static'` \| `'dynamic'` |
| `criteria` | `JSON` NULL | NULL | Árbol de filtros (solo dinámicas) |
| `last_recalculated_at` | `DateTime` NULL | NULL | Fecha/hora del último recálculo (HU-2) |
| `member_count` | `Integer` NOT NULL | `0` | Conteo vigente cacheado (HU-2) |
| `last_recalc_status` | `String(20)` NULL | NULL | `ok` \| `error` (observabilidad) |
| `last_recalc_error` | `Text` NULL | NULL | Mensaje del último fallo |

> Las filas existentes quedan `list_type='static'`, `criteria=NULL` → comportamiento idéntico al actual (sin regresión).

### 5.2 Esquema del árbol de criterios (`criteria` JSON)

```jsonc
{
  "op": "AND",                       // AND | OR
  "rules": [
    { "field": "pipeline_stage", "operator": "in", "value": ["contactado", "calificado"] },
    {
      "op": "OR",                    // grupo anidado
      "rules": [
        { "field": "source", "operator": "in", "value": ["meta", "tiktok", "google"] },
        { "field": "attention_state", "operator": "eq", "value": "descuidado" }
      ]
    },
    { "field": "created_at", "operator": "between", "value": ["2026-01-01", "2026-06-01"] },
    { "field": "geography_city", "operator": "in", "value": ["CDMX", "Monterrey"] }
  ]
}
```

**Catálogo de campos** (extensible vía un `FIELD_REGISTRY`):

| `field` | Mapeo backend | Operadores |
|---|---|---|
| `pipeline_stage` | `Lead.status` | `in`, `not_in` |
| `attention_state` | derivado (§6.2) | `eq`, `in` (`al_dia`/`descuidado`/`estancado`) |
| `source` | `Lead.source_id`→`lead_sources.code` (+ `LeadMeta.platform`) | `in`, `not_in` |
| `geography_city` | `Project.city` (join por `Lead.project_id`) | `in`, `not_in` |
| `geography_state` | `Project.state` | `in`, `not_in` |
| `created_at` (ingreso) | `Lead.created_at` | `between`, `before`, `after` |
| `last_action_at` (última acción) | `Lead.last_contact_date` | `between`, `before`, `after`, `older_than_days` |
| `assigned_advisor_id` | `Lead.assigned_advisor_id` | `in`, `not_in`, `is_empty` |
| `interest_level` / `purchase_intention` / `min_bant_score` | columnas Lead | (extensible, fase 2) |

---

## 6. Backend

### 6.1 Resolver de segmentos (nuevo)

`app/services/lead_segment_resolver.py` — `LeadSegmentResolver`:

- `build_conditions(criteria: dict) -> ColumnElement` — recorre el árbol recursivamente y devuelve `and_(...)`/`or_(...)` de SQLAlchemy. Cada `field` se traduce con un builder del `FIELD_REGISTRY` (que también declara los joins necesarios: `Project`, `LeadSource`, `LeadMeta`).
- `resolve_lead_ids(criteria, channel) -> list[int]` — ejecuta el `SELECT Lead.id` con condiciones del criterio **AND** la capa de supresión (§6.3), aplicando los joins. Multitenancy: siempre `Lead.tenant_id == tenant_id`.
- `count(criteria, channel) -> int` — `SELECT COUNT(*)` con el mismo predicado (para el preview).

> Reutiliza el espíritu de `_build_lead_conditions()` pero soportando el árbol AND/OR/grupos. Validación del árbol con un schema Pydantic (`SegmentCriteria`) — profundidad máxima, operadores permitidos por campo, valores no vacíos.

### 6.2 Estado de atención (expresión a nivel de lead)

Función `attention_state_condition(state)` que produce SQL determinístico (sin LLM), reutilizando los umbrales de `TenantConfig.advisor_supervisor_config`:

- `descuidado`: `Lead.last_contact_date < now - threshold_abandono_dias` (o `last_contact_date IS NULL` y `status_changed_at < now - umbral`), con el lead aún en etapa activa.
- `estancado`: `Lead.status_changed_at < now - threshold_estancado` y etapa activa.
- `al_dia`: negación de las dos anteriores.

> Se documenta que es una **simplificación a nivel de lead** consistente con `abandonment.py`/`lead_age.py` (que operan por etapa/asesor). Si se requiere paridad exacta por etapa, se itera en fase 2.

### 6.3 Capa de supresión (HU-11) — siempre aplicada

`apply_suppression(query, channel)` añade (vía join a `contacts` y filtros):

```
AND (contacts.opt_in_status IS NULL OR contacts.opt_in_status <> 'opted_out')
AND Lead.reengagement_opt_out = 0
AND Lead.is_active = 1
AND Lead.status NOT IN ('descartado', 'cerrado_perdido')
-- solo channel == 'email':
AND NOT EXISTS (SELECT 1 FROM email_suppressions s
                WHERE s.tenant_id = :t AND s.email = LOWER(Lead.email))
```

Se aplica en `resolve_lead_ids`, `count` y el recálculo batch. Única fuente de verdad para "lead en baja".

### 6.4 Recálculo batch diario (Temporal)

- Nuevo workflow `DynamicListRecalcWorkflow` + activities `list_tenants_with_dynamic_lists`, `recalc_dynamic_lists_for_tenant` (siguiendo el patrón de `activities_workflow_inactivity.py` y `worker.py:ensure_*_schedule`).
- Schedule diario (`ensure_dynamic_list_recalc_schedule`, p.ej. 03:00 hora del tenant; hora configurable más adelante).
- Por cada lista dinámica:
  1. `lead_ids = resolver.resolve_lead_ids(list.criteria, list.channel)`.
  2. Reemplazo transaccional de `distribution_list_leads` (delete + insert por lista).
  3. `last_recalculated_at = now`, `member_count = len(lead_ids)`, `last_recalc_status='ok'` (o `'error'` + mensaje).
  - Batching (50) y `heartbeat()` como en los checkers existentes.
- **Importante**: el batch materializa la membresía → las **campañas (broadcast) leen esa foto** sin cambios (usan `distribution_list_leads`).

### 6.5 Resolución en vivo para workflows transaccionales

> **Corregido tras leer el código real** (ver §11.2). El envío de broadcast **no**
> pasa por `get_leads_with_*`: las activities de Temporal (`fetch_campaign_leads` en
> `activities_campaign.py` y su gemela en `activities_email_campaign.py`) hacen
> **SQL crudo con JOIN directo a `distribution_list_leads`**. Por eso materializar la
> foto del batch en esa tabla hace que el broadcast funcione **sin tocar el send path**.

- **Broadcast (campaña)**: sin cambios. Lee `distribution_list_leads` (la foto que
  escribe el batch). Para listas dinámicas, la foto la produce el recálculo diario.
- **Workflow transaccional (`_send_email`, modo `distribution_list`)**: hoy llama
  `dl_repo.get_leads_with_email(list_id)` (`workflow_action_executor.py:671`), que lee
  la **membresía materializada** — NO el criterio en vivo (pese al comentario "Resolved
  live"). **Cambio**: si la lista es `dynamic`, resolver el criterio en vivo
  (`resolver.resolve_lead_ids(criteria, channel)` + supresión); si es `static`, leer
  membresía como hoy. El flag/branch vive en `_send_email` (y/o en una variante
  `resolve_recipients(list, live=True)` del repo), **no** en el send path de broadcast.

### 6.6 Guards y endpoints

**Guards** (en `distribution_list_repository`/endpoints):
- `add_leads` / `remove_leads` / `change_control_status`: si `list.list_type == 'dynamic'` → `409 Conflict` ("La membresía de una lista dinámica se define por criterios").
- `create` / `update`: si `list_type='dynamic'` exige `criteria` válido; si `static`, ignora `criteria`.

**Endpoints** (`app/api/v1/distribution_lists.py`):
- `POST /distribution-lists` y `PUT /distribution-lists/{id}` → aceptan `list_type` + `criteria`.
- `POST /distribution-lists/preview-count` `{ channel, criteria }` → `{ count }` (HU-3 preview, aplica supresión).
- `POST /distribution-lists/{id}/recalculate` → dispara recálculo on-demand (refresco manual / pruebas).
- `GET /distribution-lists/filter-options` → catálogos para el builder (etapas activas, fuentes, ciudades/estados de proyectos, estados de atención).

**Schemas** (`app/schemas/distribution_list.py`): añadir `list_type`, `criteria` (validado por `SegmentCriteria`), `last_recalculated_at`, `member_count` a create/response.

---

## 7. Frontend (`app-saas-frontend`)

- **Badge** "Estática"/"Dinámica": componente reutilizable mostrado en el listado (`DistributionListsView.vue`) y en el detalle (`DistributionListDetailView.vue`). (HU-2)
- **Detalle de lista dinámica**: mostrar `last_recalculated_at` (formateado) + `member_count`; **ocultar** botones de agregar/quitar leads y el `AddLeadsModal`. (HU-2)
- **Constructor de filtros** `SegmentBuilder.vue` (nuevo): filas de condición + grupos anidados con conmutador AND/OR; usa `GET /filter-options` para poblar selects. Integrado en el wizard de creación cuando `list_type='dynamic'`. (HU-3)
- **Preview de conteo**: botón "Previsualizar" que llama `preview-count` y muestra el número antes de guardar. (HU-3)
- **Service** (`distribution-lists.service.ts`): `previewCount(criteria, channel)`, `recalculate(id)`, `getFilterOptions()`; tipos `DistributionList` extendidos con `list_type`, `criteria`, `last_recalculated_at`, `member_count`.
- **i18n**: etiquetas de badge, estados de atención, operadores.

---

## 8. Plan de implementación por fases

| Fase | Entregable | Archivos clave |
|---|---|---|
| **0. Modelo** | Migración Alembic (`list_type`, `criteria`, `last_recalculated_at`, `member_count`, status/error) + modelo SQLAlchemy. | `alembic/versions/`, `app/db/models.py` |
| **1. Resolver + supresión + preview** | `LeadSegmentResolver`, `SegmentCriteria`, capa de supresión, `attention_state_condition`, endpoint `preview-count` + `filter-options`. Tests unitarios del resolver (AND/OR/grupos, supresión, atención). | `app/services/lead_segment_resolver.py`, `app/schemas/distribution_list.py`, `app/api/v1/distribution_lists.py` |
| **2. Recálculo batch** | Workflow + activities Temporal + schedule diario + materialización. | `app/temporal/workflows_dynamic_list_recalc.py`, `activities_dynamic_list_recalc.py`, `worker.py` |
| **3. Resolución en vivo** | Flag `live` en `get_leads_with_*`; `_send_email` pasa `live=True`; campañas siguen leyendo foto. Tests. | `distribution_list_repository.py`, `workflow_action_executor.py` |
| **4. Guards + CRUD criterio** | Bloqueo de edición manual en dinámicas; create/update con `criteria`. Tests. | `distribution_list_repository.py`, `app/api/v1/distribution_lists.py` |
| **5. Frontend** | Badge, detalle (fecha + conteo, sin edición manual), `SegmentBuilder`, preview, service, i18n. | `app-saas-frontend/src/views/distribution-lists/`, `src/components/`, `src/services/distribution-lists.service.ts` |
| **6. QA / deploy** | Pruebas e2e (crear dinámica → preview → recalc → campaña broadcast usa foto; workflow usa vivo; supresión excluye baja). Despliegue: backend (migración + código) → frontend. | — |

### Mapa de criterios de aceptación → fase

| Criterio (HU) | Fase |
|---|---|
| Tipo explícito estático/dinámico | 0, 4 |
| Badge en listado y detalle | 5 |
| Recálculo diario + fecha + conteo en el front | 2, 5 |
| Broadcast usa foto del batch / workflow resuelve en vivo | 2, 3 |
| Misma lista en WhatsApp y email | ⚠️ a clarificar — ver §11.3 |
| Dinámica: sin alta/baja manual; estática sí | 4, 5 |
| Filtros AND/OR + grupos sobre atributos | 1, 5 |
| Vista previa del conteo antes de guardar | 1, 5 |
| Criterio persistido alimenta el recálculo | 0, 2 |
| Resolución respeta supresión (HU-11) | 1 (aplica en 2 y 3) |

---

## 9. Riesgos y preguntas abiertas

1. **Paridad del estado de atención**: la lógica original (`abandonment.py`/`lead_age.py`) opera por etapa/asesor con poblaciones específicas. La versión a nivel de lead es una simplificación; confirmar que es aceptable para segmentar (vs. replicar por etapa).
2. **Geografía por proyecto**: leads sin `project_id` no entran a filtros geográficos (quedan fuera del `in`). Confirmar el comportamiento esperado (excluir vs. ignorar el filtro).
3. **Tamaño del segmento en vivo (workflows)**: resolver el criterio al trigger por cada lead disparador puede ser costoso si el workflow es de alta frecuencia; cachear/medir.
4. **HU-11 formal**: si HU-11 introduce una tabla/columna específica de "baja", la capa de supresión debe apuntar a esa fuente cuando exista (hoy se compone de opt-out + reengagement + inactivo/terminal + EmailSuppression).
5. **Hora del recálculo diario**: fija al inicio (p.ej. 03:00); ¿se requiere por-tenant/configurable en MVP?
6. **Listas existentes**: todas migran a `static` (sin regresión); confirmar que ninguna "lista" actual debía ser dinámica.

---

## 11. Revisión crítica — ¿es funcional? qué no se consideró

Tras releer el código real (no los resúmenes), estos son los puntos donde el plan v1
**fallaría** o estaba incompleto. Se ordenan por impacto.

### 11.1 BLOQUEANTE — Los estados del lead NO son strings fijos (catálogo por tenant)

`lead_status` es un **catálogo declarativo por tenant** (`LeadStatusCatalog`,
`models.py:3842`) con flags `is_closed`, `is_active_stage`, `is_reactivatable`,
`requires_loss_reason`. El propio comentario dice que estos flags *"reemplazan la
metadata que antes vivía hardcoded en `app.core.constants.LeadStatus`"*. Y el código
existente es **inconsistente** entre sí: el checker de inactividad excluye
`['ganado','perdido']`, `lead_age.py` usa `['descartado','cerrado_ganado']`, y mi plan
v1 escribió `['descartado','cerrado_perdido']`.

- **Corrección**: ni el filtro `pipeline_stage`, ni la exclusión de "terminal" en la
  supresión, ni la noción de "etapa activa" del estado de atención pueden hardcodear
  strings. Deben derivarse de `lead_status` por tenant (`is_closed=false` /
  `is_active_stage=true`). El endpoint `filter-options` debe poblar las etapas desde el
  catálogo del tenant, no desde una lista fija.

### 11.2 El send path de broadcast es SQL crudo, no `get_leads_with_*`

`fetch_campaign_leads` (WhatsApp) y su gemela de email arman el lote con **SQL crudo
JOIN a `distribution_list_leads`**, aplicando además guardas en el envío:
- WhatsApp: `is_active=1`, teléfono presente, `opt_in_status <> 'opted_out'`.
- Email: `is_active=1`, email presente, `NOT EXISTS email_suppressions`.

Implicaciones:
- ✅ **A favor del plan**: materializar la foto en `distribution_list_leads` hace que el
  broadcast funcione sin tocar el send path. El diseño de materialización es correcto.
- ❌ **Corrige el plan v1**: el "flag `live` en `get_leads_with_*`" estaba mal ubicado;
  el broadcast no usa ese método. El cambio de resolución en vivo es **solo** para
  `_send_email` (workflow). Ya parcheado en §6.5.

### 11.3 Decisión de diseño (con default claro) — "la misma lista en WhatsApp y email"

`distribution_lists.channel` ata cada lista a **un** canal. La creación de campañas de
email (`email_campaigns.py:_create_campaign`) **no valida** el canal de la lista, pero
el listado (`list_all`) y el front filtran por `channel`, y la creación de lista fija
un canal. → En la práctica **una lista vive en un solo canal**; no es literalmente "la
misma lista" consumida por ambos.

- **Decisión requerida**: ¿HU-2 quiere (a) una **misma fila de lista** usable por
  campañas de WhatsApp *y* de email, o (b) una **misma implementación/feature** (sin
  código duplicado), cada lista atada a su canal? El estado actual es (b).
- **Default que adopto** (no bloquea el arranque): una **lista dinámica es
  channel-agnóstica** — su criterio selecciona leads, y el destinatario se resuelve por
  canal al usarla (teléfono para WhatsApp, email para correo). El `channel` deja de ser
  obligatorio en dinámicas; las estáticas conservan el comportamiento actual. La foto
  materializada (`distribution_list_leads`) sirve a ambos send paths sin duplicar nada.
- Solo si el producto quiere explícitamente lo contrario (cada lista atada a un canal,
  como hoy) se ajusta; es un cambio menor sobre este default, no un rediseño.

### 11.4 Materialización inicial / foto vacía o vieja (omisión)

Una lista dinámica creada a las 10:00 **no tendrá miembros** hasta el batch de las
03:00. Si el usuario crea la lista y lanza un broadcast el mismo día, enviaría a 0 leads.
El plan v1 tenía `POST /recalculate` pero no lo conectaba al flujo.

- **Corrección**: recalcular **al crear/editar** una lista dinámica (síncrono o
  encolado) y/o forzar recálculo **antes de ejecutar** una campaña sobre lista dinámica
  con foto vencida. Definir TTL de "foto fresca" (p.ej. recalc si `last_recalculated_at`
  > 24 h o NULL).

### 11.5 Recálculo concurrente con un envío en curso (omisión)

El batch hace `delete + insert` sobre `distribution_list_leads`; si corre mientras un
broadcast está leyendo esa lista, el envío puede ver un set a medio escribir. La guarda
actual ("no borrar lista con campaña activa") no cubre el recálculo.

- **Corrección**: el recálculo debe **saltar** listas con una campaña en estado
  `sending` (o hacer swap transaccional/atómico por lista). Documentar el orden.

### 11.6 Fidelidad del "estado de atención" (decisión, no glosar)

`abandonment.py` calcula "último contacto saliente" desde
`Conversation`/`AdvisorWhatsAppConversation`/`AdvisorCallLog` (máximo de salientes),
**no** desde `Lead.last_contact_date`. Mi expresión simplificada usa
`last_contact_date`. Si ese campo no se mantiene idéntico, el filtro discrepará del KPI
que el usuario ve en advisor-performance.

- **Decisión**: o se acepta `last_contact_date` como proxy (más simple/rápido,
  documentado), o se replica el subquery a 3 tablas (fiel pero **caro** en el batch
  sobre toda la base de leads). Recomendado para MVP: proxy + nota; medir.

### 11.7 Granularidad de fuente Meta/TikTok/Google (verificación pendiente)

`lead_sources` es un catálogo `code/name` por tenant; `leads_meta.platform` viene de
Facebook Lead Ads (Meta/IG). **No hay garantía** de que TikTok y Google estén
diferenciados en los datos de cada tenant. HU-3 los lista explícitamente.

- **Verificar**: qué `code`s existen en `lead_sources` por tenant. Si TikTok/Google no
  se registran como fuente, ese filtro no se puede entregar tal cual; el `filter-options`
  debe reflejar solo lo realmente disponible.

### 11.8 Inyección SQL / construcción de criterios (riesgo a evitar)

Ojo: `lead_age.py` arma SQL con **f-strings** (`idl`, `stages_sql`). El resolver de
criterios **no debe** copiar ese patrón: el árbol viene del usuario. Usar siempre
parámetros enlazados / construcción con la API de SQLAlchemy y un **allow-list de
operadores por campo**, profundidad máxima del árbol y validación de valores.

### 11.9 Otras omisiones menores

- **`Lead` no tiene `deleted_at`**; el soft-delete real es `is_active` (la referencia a
  `Lead.deleted_at` en `activities_workflow_inactivity.py` es sospechosa — verificar).
  La supresión debe usar `is_active`.
- **Supresión inconsistente entre canales hoy**: email no chequea `opt_in`; WhatsApp no
  chequea `email_suppressions`; ninguno chequea `reengagement_opt_out` ni terminal. La
  capa unificada (§6.3) es **más estricta** → `member_count`/preview pueden ser menores
  que lo que enviaría el path legacy. Decidir si la supresión se hornea en la foto
  (recomendado, para que el conteo sea honesto) dejando las guardas de envío como
  defensa en profundidad.
- **Preview vs. envío real**: hoy el conteo de destinatarios (`get_leads_with_email`)
  **no** aplica supresión, pero el envío sí. Para listas dinámicas, conteo + foto +
  envío deben usar **la misma** función de resolución para no mentir en el preview.
- **RBAC**: los endpoints nuevos (`preview-count`, `recalculate`, `filter-options`)
  deben ir tras `require_permission` como el resto del módulo.
- **`project_id` de la lista** pierde sentido en dinámicas multi-proyecto; no confundir
  con el filtro geográfico (que es `Project.city` por lead).
- **Performance del batch** con filtros de atención/última acción sobre toda la base de
  leads por tenant: revisar índices (`last_contact_date`, `status_changed_at`) y batch.
- **Backfill** de `member_count` para listas estáticas existentes en la migración.

### 11.10 Veredicto

El **plan es funcional e implementable**. La decisión de materializar la foto en
`distribution_list_leads` es correcta (encaja con el send path real de broadcast). Las
observaciones de §11 **no son bloqueos**: cada una tiene un default razonable que adopto
sin necesidad de esperar respuesta:

| Punto | Default adoptado para arrancar |
|---|---|
| §11.1 estados | Derivar etapa/terminal/activa de `lead_status` (flags por tenant), nunca strings fijos. |
| §11.2 send path | Sin cambios en broadcast; resolución en vivo solo en `_send_email`. |
| §11.3 canal | Lista dinámica channel-agnóstica; canal se resuelve al usarla. |
| §11.4 foto inicial | Recalcular al crear/editar dinámica y antes de ejecutar campaña si la foto está vencida (TTL 24 h). |
| §11.5 concurrencia | El recálculo salta listas con campaña `sending`. |
| §11.6 atención | `last_contact_date` como proxy en MVP (documentado); réplica fiel en fase 2 si se requiere. |
| §11.7 fuente | `filter-options` se arma desde el catálogo real; se entrega lo que exista (Meta sí; TikTok/Google si el tenant los registra). |
| §11.8 seguridad | Resolver con parámetros enlazados + allow-list de operadores; nada de f-strings. |

Las únicas dos cosas que pediría confirmar al producto (pero **no** detienen las fases
0–2) son: la interpretación de §11.3 (si NO es channel-agnóstica) y si el proxy de
atención §11.6 es aceptable. Todo lo demás está decidido.

---

## 12. Resumen ejecutivo

La capacidad compartida (una lista, dos canales) **ya existe**: HU-2 en ese punto solo requiere verificación. El trabajo real es (a) añadir el **tipo + criterio** al modelo, (b) un **resolver recursivo** de segmentos con **supresión** integrada, (c) el **recálculo batch diario** que materializa la foto para broadcast, (d) **resolución en vivo** para workflows (un flag, reutilizando lo existente), (e) **guards** y **preview**, y (f) el **frontend** (badge, builder, fecha/conteo). El grueso del riesgo está en definir bien el estado de atención y la supresión; ambos tienen lógica/datos preexistentes que reutilizamos.
