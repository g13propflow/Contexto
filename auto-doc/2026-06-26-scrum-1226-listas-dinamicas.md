# SCRUM-1226 — Listas de distribución dinámicas (tipo + criterio + recálculo)

## Fecha
2026-06-26

## Tarea solicitada (en concreto)
HU-2 / HU-3: que las listas de distribución soporten tipo **estático** y **dinámico**.
Las dinámicas se definen por un **criterio de filtros avanzados** (no por alta/baja
manual) y se **recalculan a diario** contra el estado actual de los leads. El front debe
mostrar la fecha del último recálculo y el conteo vigente. El batch diario alimenta las
campañas (broadcast); cuando una lista dinámica alimenta un workflow transaccional, el
segmento se resuelve **en vivo** al momento del trigger, no con la foto del batch.

## Rama
`feature/SCRUM-1226` (commit `3ab5358e`)

## Módulo(s) afectado(s)
`app-saas-service` — distribution_lists / lead segmentation / temporal
- `app/db/models.py` — nuevas columnas en `distribution_lists`.
- `alembic/versions/sc1226dynlists_add_dynamic_lists.py` — migración.
- `app/services/lead_segment_resolver.py` — **nuevo** resolver de segmentos.
- `app/schemas/lead_segment.py` — **nuevo** schema del árbol de criterios.
- `app/services/dynamic_list_recalc_service.py` — **nuevo** núcleo del recálculo.
- `app/temporal/workflows_dynamic_list_recalc.py` + `activities_dynamic_list_recalc.py` + `worker.py` — batch diario Temporal.
- `app/db/repositories/distribution_list_repository.py` — materialización + guards + resolución en vivo.
- `app/api/v1/distribution_lists.py`, `app/schemas/distribution_list.py` — endpoints y schemas (preview-count, recalculate, filter-options).
- `app/services/workflow_action_executor.py` — `_send_email` resuelve en vivo (`live=True`).
- `tests/unit/listas_dinamicas/` — tests del resolver y del schema.

---

## Resumen de lo que se hizo
Se convirtió la lista de distribución de "conjunto de leads mantenido a mano" a "regla
que el sistema evalúa sola". Cada lista ahora tiene `list_type` (`static`/`dynamic`) y,
para las dinámicas, un `criteria` (árbol de filtros AND/OR con grupos, en JSON).

Mecanismo central — la misma regla se resuelve de dos formas según quién la use:
- **Broadcast (campañas):** al arrancar el envío se **materializa** la membresía en
  `distribution_list_leads` (la "foto") justo antes de leerla. Sella
  `last_recalculated_at`, `member_count`, `last_recalc_status`. El send path de broadcast
  lee esa foto tal cual (SQL crudo con JOIN a `distribution_list_leads`), sin cambios.
  El recálculo se hace **on-demand al enviar**, no en lote a diario (ver Actualización
  2026-07-02).
- **Workflow transaccional:** `_send_email` en modo `distribution_list` llama
  `get_email_recipients(list_id, live=True)`, que para listas dinámicas ignora la foto y
  **resuelve el criterio en vivo** al trigger vía `LeadSegmentResolver`.

`LeadSegmentResolver` es una sola fuente de verdad usada en preview, batch y vivo, y
**siempre** aplica la capa de supresión (HU-11): un lead en baja (opt-out, inactivo,
terminal, en `email_suppressions`) nunca entra al segmento. Esto garantiza que
preview = foto = envío.

Guards: en dinámicas se bloquea alta/baja manual; el recálculo salta listas con campaña
en `sending`; al crear/editar se recalcula para no arrancar con foto vacía.

## Decisiones tomadas
- **Estados del lead NO hardcodeados**: etapa activa / terminal se derivan del catálogo
  por tenant (`lead_status` flags), no de strings fijos (había inconsistencias en el
  código previo).
- **Lista dinámica channel-agnóstica**: el criterio selecciona leads; el destinatario
  (teléfono/email) se resuelve por canal al usarla.
- **Estado de atención por proxy**: se usa `Lead.last_contact_date` como proxy a nivel
  de lead (más barato) en vez de replicar el subquery a 3 tablas de `abandonment.py`;
  documentado, réplica fiel diferida a fase 2.
- **Seguridad del resolver**: árbol construido con la API de SQLAlchemy (parámetros
  enlazados) + allow-list de operadores por campo; nunca f-strings (se evitó el patrón
  de `lead_age.py`).
- **Foto materializada** en `distribution_list_leads` (no resolver en vivo para
  broadcast) por costo/predecibilidad en envíos masivos.

## Preguntas y respuestas
Durante el análisis se dejaron 2 preguntas abiertas a producto (no bloquean fases 0–2):
1. **§11.3 canal** — ¿"la misma lista" quiere decir una misma fila usable por WhatsApp
   y email, o la misma feature con cada lista atada a su canal? → Default adoptado:
   lista dinámica channel-agnóstica. Pendiente confirmación de producto.
2. **§11.6 estado de atención** — ¿es aceptable el proxy `last_contact_date` en MVP vs.
   replicar la lógica exacta por etapa/asesor? → Default adoptado: proxy + nota.

## ¿Se tocó trabajo de otros desarrolladores?
Parcialmente. Se modificó `workflow_action_executor.py` (motor de workflows, SCRUM-1238)
para la resolución en vivo, y el send path de campañas (broadcast) se **respetó sin
tocar** (se descubrió que usa SQL crudo a `distribution_list_leads`, por eso materializar
la foto fue suficiente). El resto es código nuevo del propio ticket.

## Bugs de otros encontrados / resueltos
Encontrados durante el análisis (documentados, no todos resueltos aquí):
- **Inconsistencia de estados terminales** entre módulos (`abandonment.py` usa
  `['ganado','perdido']`, `lead_age.py` `['descartado','cerrado_ganado']`). Se evitó
  heredar el bug derivando del catálogo por tenant.
- **Supresión inconsistente** entre canales en el código legacy (email no chequeaba
  opt-in; WhatsApp no chequeaba `email_suppressions`; ninguno `reengagement_opt_out`).
  La nueva capa unificada es más estricta.
- **Preview mentía**: el conteo legacy (`get_leads_with_email`) no aplicaba supresión
  pero el envío sí. Se unificó para que el conteo sea honesto.

## Notas / pendientes
- Frontend (badge, `SegmentBuilder`, preview de conteo, detalle con fecha+conteo) va en
  `app-saas-frontend` (fase 5 del plan).
- Extensión posterior en `feature/SCRUM-1262` (2026-07-01): filtros por proyecto, motivo
  de descarte y palabras clave.
- Referencia: `plan-listas-distribucion-dinamicas.md` en la raíz del workspace.

---

## Actualización 2026-07-02 — recálculo on-demand (no más batch diario)

### Qué pidieron
El recálculo de los leads de una lista dinámica ya **no** debe correr 1×/día; debe
hacerse **cada vez que se va a enviar la lista, bajo demanda**, para no saturar el
sistema (el batch diario recalculaba todas las listas de todos los tenants aunque no se
fueran a enviar).

### Qué se hizo
El recálculo pasó de batch programado a on-demand, disparado al arrancar cada campaña,
justo antes de leer la foto. Aplica a **ambos canales** (email y WhatsApp), que leen
`distribution_list_leads`.

- `app/services/dynamic_list_recalc_service.py` — nueva `materialize_dynamic_list_for_send(tenant_id, list_id)`:
  recalcula **una** lista. Estática → no-op; criterio inválido → sella
  `last_recalc_status='error'` y propaga (mejor fallar que enviar foto vieja).
- `app/temporal/activities_dynamic_list_recalc.py` — nueva activity
  `materialize_dynamic_list_on_demand`.
- `app/temporal/workflows_email_campaign.py` y `app/temporal/workflows_campaign.py` —
  se llama esa activity **antes** de `fetch_email_leads` / `fetch_campaign_leads`. En ese
  punto el `status` ya es `sending`, por eso NO se aplica el guard `has_sending_campaign`
  (esta campaña es la que envía).
- `app/temporal/worker.py` — se reemplazó `ensure_dynamic_list_recalc_schedule` por
  `remove_dynamic_list_recalc_schedule`, que **borra** el schedule diario en cualquier
  entorno que lo tuviera; se registró la nueva activity.

### Qué se conservó
El `DynamicListRecalcWorkflow` + sus activities de batch quedan registrados como
**refresco masivo disparable a mano** desde Temporal (ya no corre por schedule). El path
transaccional (`live=True`) no cambia: ya resolvía on-demand. En el detalle de la lista
se mantiene el botón manual **Recalcular**.

### Frontend (`app-saas-frontend`)
Se corrigió el texto que decía que la lista dinámica se "recalcula a diario", que ya no
es cierto:
- `src/views/distribution-lists/components/ListTypeBadge.vue` — tooltip → "Membresía
  definida por criterios; se recalcula al enviar".
- `src/views/distribution-lists/components/CreateListModal.vue` — opción Dinámica → "Definida
  por criterios, se recalcula al enviar".

### Ramas / commits
- `app-saas-service` → rama `feature/SCRUM-1293`, commit `f8ac348d` (6 archivos backend).
- `app-saas-frontend` → rama `feature/SCRUM-1293`, commit `6da214ff` (2 archivos de texto).

### Verificación
`pytest tests/unit/listas_dinamicas/` → **40 passed** (en Docker, contenedor `api`).
