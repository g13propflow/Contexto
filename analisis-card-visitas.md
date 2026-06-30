# Análisis — Card de Visitas (Agendadas / Visitadas / %)

> **Tarea:** Agregar una card que mida la cantidad y % de visitas que se agendaron (canceladas + no atendidas + atendidas) y cuántas se completaron (atendidas), dentro del rango de fechas y filtros seleccionados.
> Ej: *Agendadas 10, Visitadas 6, 60%*.
>
> **Estado:** ✅ **IMPLEMENTADO en local** (2026-06-25). Migraciones `003`-`007` aplicadas en `PropFlow_Gerardo`; backend (`cancelled` + derivados en `appointment-metrics`) y frontend (card 70/30 en Marketing) listos. **Pendiente:** aplicar migraciones en **producción**, reiniciar servicios para tomar el código, QA visual, y commit (lo hace el usuario).
>
> Autocontenido — incluye lo investigado en los 3 repos para no re-explorar. Última actualización: 2026-06-24.

---

## 0. Veredicto

La card es **factible y de bajo esfuerzo**: casi toda la tubería ya existe.
- El dato de asistencia (`appointment_state`) **existe y está poblado** en `calendars.calendar_events` (feature agregado en calendar-service, migración `003`, 2026-06-23, con backfill histórico).
- Ya hay un endpoint (`GET /marketing/dashboard/appointment-metrics`) que calcula attended/no_show/etc. con los filtros que pide la tarea.
- **Único cambio backend real:** exponer también el conteo de `cancelada` (hoy no se devuelve como campo propio).
- **Frontend:** 1 `KpiCard` nueva en el dashboard de Marketing.
- **calendar-service:** cero cambios.

> ⚠️ Corrección histórica: una exploración previa (con OneDrive desincronizado) concluyó erróneamente que la asistencia "no existía". Con los últimos cambios bajados, **sí existe end-to-end**.

---

## 1. Dónde vive el dato (verificado en código)

### 1.1 calendar-service — fuente de verdad del estado de la cita
- **Columna:** `calendars.calendar_events.appointment_state` (VARCHAR(20), NULLABLE).
  Migración: `calendar-service/src/migrations/003_add_appointment_state_to_calendar_events.sql`.
- **Valores (CHECK constraint):** `programada | atendida | no_asistio | cancelada | reagendada`. NULL para no-citas (solo aplica a `event_type IN ('visit','appointment')`).
- **Ciclo de vida** (`src/modules/events/commands/calendar_events.commands.js`):
  - `markAttended` → `atendida` (desde `programada` o corrige `no_asistio`). Línea ~438.
  - `markNoShow` → `no_asistio` (solo desde `programada`). Línea ~456. Lo dispara Temporal (VisitFollowUp) a las **+8h** del inicio.
  - cancelar → `status='cancelled', appointment_state='cancelada'`. Línea ~990.
  - reagendar → la cita vieja queda `reagendada`, se crea una nueva `programada`. Línea ~192/220.
  - Cada desenlace se registra también en `lead_activity_timeline` (`visit_attended` / `visit_no_show`).
- **Endpoints REST:** `POST /api/events/:id/attended`, `POST /api/events/:id/no-show` (controller línea ~618).
- **Migraciones de backfill:** `004` (atendida desde lead status), `005` (colas de reschedule → reagendada), `006`/`007` (NULL para programadas huérfanas/perdidas).
- Campos para filtrar/agrupar: `tenant_id`, `calendar_id`, `advisor_code`, `start_datetime`, `event_type`, `status`, `is_confirmed`, `parent_event_id`; lead vía `calendar_event_attendees.lead_id`.

### 1.2 app-saas-service — capa de analytics que ya consume el dato
- **Endpoint:** `GET /marketing/dashboard/appointment-metrics` (`app/api/v1/marketing_dashboard.py:268`).
- **Query:** `app/db/repositories/marketing_dashboard_repository.py:2351` (método de appointment metrics). Hoy calcula:
  ```
  total_slots, unique_appointments,
  rescheduled (=reagendada), confirmed (=programada & is_confirmed),
  attended (=atendida), no_show (=no_asistio),
  ever_confirmed, attended_confirmed
  ```
  - Filtra: `event_type IN ('visit','appointment')`, `appointment_state IS NOT NULL`, **`created_at BETWEEN :start AND :end`**, + filtros (advisor/project/source vía joins).
  - **NO devuelve un conteo propio de `cancelada`** (aunque sí entra en `total_slots`).
- **Schema de respuesta:** `AppointmentMetricsResponse` (`app/schemas/marketing_dashboard.py`, también `marketing_dashboard.py:412`): `total_slots, unique_appointments, rescheduled, confirmed, attended, no_show, ever_confirmed, attendance_rate, confirmed_attendance_rate`.
- **Filtros soportados (los que pide la tarea):** `_filters_dependency()` → `date_from`, `date_to`, `source_id`, `advisor_id`, `project_id`, `campaign_id`, `agent_variant`.
- **Segunda fuente (NO usar para esta card):** `GET /marketing/dashboard/appointments` cuenta agendadas/atendidas desde `lead_activity_timeline` (`stage_changed → visita_agendada / cita_completada`). No tiene `cancelada` limpio → la card debe usar `appointment_state`, no el timeline.

### 1.3 Frontend — dónde y cómo se agrega la card
- **Vista:** `app-saas-frontend/src/views/MarketingDashboardView.vue` (dashboard nativo de Marketing, ruta `/dashboard`, tab marketing).
- **Componentes:** `src/components/marketing/KpiCard.vue` (card individual reutilizable), `AppointmentMetricsTable.vue` (ya muestra attended/no_show/attendance_rate).
- **Servicio:** `src/services/marketingDashboard.service.ts` → `getAppointmentMetrics(filters)`.
- **Tipos:** `src/types/marketingDashboard.ts` → `AppointmentMetricsResponse`, `MarketingDashboardFilters`.
- **Filtros:** `MarketingFilters.vue` + objeto `filters` en la vista; `watch` con debounce dispara `loadAll()`. Se propagan solos a cualquier card nueva.

---

## 2. Mapeo de la fórmula pedida → datos

| Término de la tarea | `appointment_state` | ¿Disponible hoy? |
|---|---|---|
| Visitadas (atendidas) | `atendida` | ✅ `attended` |
| No atendidas | `no_asistio` | ✅ `no_show` |
| Canceladas | `cancelada` | ❌ **falta exponer** |
| **Agendadas** = canceladas + no atendidas + atendidas | suma de los 3 | ❌ derivable al exponer `cancelada` |
| **%** = atendidas / Agendadas | `atendida / (cancelada+no_asistio+atendida)` | ❌ derivable |

- ⚠️ `total_slots` **NO** sirve como "Agendadas": incluye `programada` y `reagendada`.
- ⚠️ `attendance_rate` existente (`atendida/(atendida+no_asistio)`) **NO** es el % pedido: no incluye `cancelada`.

---

## 3. Impacto por capa

| Capa | Cambio | Esfuerzo |
|---|---|---|
| **calendar-service** | Ninguno (feature ya implementado) | — |
| **Backend app-saas** | Agregar `SUM(CASE WHEN appointment_state='cancelada' THEN 1 ELSE 0 END) AS cancelled` a la query (`marketing_dashboard_repository.py:2353-2361`) + campo `cancelled` (y opcional `scheduled_outcomes`, `attended_over_outcomes_pct`) en `AppointmentMetricsResponse`. Reusa filtros/joins. | **Bajo** |
| **Tipos TS** | +1 campo `cancelled` en `AppointmentMetricsResponse` | Trivial |
| **Frontend** | 1 `KpiCard` (Agendadas / Visitadas / %) en `MarketingDashboardView`, junto a `AppointmentMetricsTable`. Cálculo: `agendadas = attended+no_show+cancelled`, `visitadas = attended`, `pct = visitadas/agendadas`. | **Bajo** |

**Riesgos:**
1. **Semántica del rango de fechas** (ver §4-Q1) — cambia qué mide la card.
2. **Calidad del dato** (ver §5) — el % depende de que los desenlaces se registren bien.
3. **Consistencia con otras cards** del mismo dashboard (la card de "Cita→Visita" usa otra base) — pueden no cuadrar a la vista; aclarar en el label.

---

## 4. Decisiones de producto — RESUELTAS (2026-06-25)

**Q1 — ¿Por qué fecha se filtra?** ✅ **Seguir la lógica actual** = filtrar por **`created_at`**, igual que el resto de métricas de citas. **No se cambia la query de fecha**; se reutiliza tal cual el WHERE existente de `appointment-metrics`.

**Q2 — ¿"Agendadas" incluye las `programada`/`reagendada`?** ✅ **NO.** Agendadas = `cancelada` + `no_asistio` + `atendida` (solo desenlaces). Se excluyen `programada` (pendientes/futuras) y `reagendada`.

**Q3 — ¿Dónde va la card?** ✅ Dashboard de **Marketing** (`MarketingDashboardView`), **a la derecha de la tabla de métricas de citas** (`AppointmentMetricsTable`), en una fila con layout **70% tabla / 30% card**.

---

## 5. Verificación de calidad de dato (recomendada antes de publicar)

El % es tan bueno como el registro de desenlaces:
- `atendida` la marca el asesor (lead → `cita_completada`) o el followup.
- `no_asistio` la pone Temporal automáticamente a las **+8h**.
- Si los asesores **no** marcan "visita realizada", visitas reales atendidas quedan como `no_asistio` → el % saldría artificialmente bajo.

Consulta read-only para ver si el dato luce sano (distribución de estados) — **requiere haber aplicado primero la migración `003`** (ver §6 bloqueante #0; hoy falla con `Invalid column name`):
```sql
SELECT appointment_state, COUNT(*) AS n
FROM calendars.calendar_events
WHERE event_type IN ('visit','appointment')
GROUP BY appointment_state
ORDER BY n DESC;
```
Esperado: cantidades razonables en `atendida` y `no_asistio`. Si casi todo es `no_asistio` o NULL → revisar el proceso operativo antes de mostrar la card.

---

## 6. Qué falta para comenzar el desarrollo

**Bloqueante #0 — DATOS (RESUELTO en dev, pendiente prod):**
0. **Migraciones `003`-`007` de calendar-service** → ✅ **aplicadas en `PropFlow_Gerardo`** (2026-06-24, vía runner Node que reusa la conexión Sequelize; calendar-service no tiene runner propio ni script `migrate`). La columna `appointment_state` ya existe y los backfills corrieron.
   - **Distribución resultante (visit/appointment):** programada 292 · NULL 186 · reagendada 136 · cancelada 92 · atendida 81 · **no_asistio 0**.
   - ⚠️ **`no_asistio = 0` histórico**: el backfill dejó ambiguos en NULL en vez de adivinar no-show; se poblará a futuro vía Temporal (+8h). El histórico de desenlaces es parcial (muchas `programada`/NULL).
   - ✅ Efecto colateral: esto **arregla el 500** del endpoint `appointment-metrics` de app-saas contra esta BD.
   - ⏳ **PENDIENTE: aplicar las mismas migraciones en PRODUCCIÓN** (orden `003 → 007`) antes de liberar la card. calendar-service no tiene runner → aplicar a mano (SSMS/Azure Data Studio) o con un runner equivalente.

**Bloqueantes de producto:** ✅ **TODOS RESUELTOS** (ver §4):
1. ✅ **Q1** — filtrar por `created_at` (lógica actual, sin cambios de query).
2. ✅ **Q2** — Agendadas = solo desenlaces (cancelada+no_asistio+atendida).
3. ✅ **Q3** — Marketing, a la derecha de `AppointmentMetricsTable`, layout 70/30.

**Pendiente operativo (no bloquea el código):**
- Aplicar migraciones 003-007 en **producción** antes de liberar.
- Definir copy/formato del % (entero "60%" vs 1 decimal) — *default: entero*.

**Plan de implementación (LISTO para ejecutar):**
- **Backend** (`marketing_dashboard_repository.py:~2351`): agregar `SUM(CASE WHEN x.appointment_state='cancelada' THEN 1 ELSE 0 END) AS cancelled` a la query existente (sin tocar el WHERE de fecha, Q1). Exponer `cancelled` en `AppointmentMetricsResponse` (`marketing_dashboard.py` + `schemas/marketing_dashboard.py`).
- **Frontend**:
  - `types/marketingDashboard.ts`: +`cancelled: number` en `AppointmentMetricsResponse`.
  - `MarketingDashboardView.vue`: envolver la `AppointmentMetricsTable` y la card nueva en una fila (grid `lg:grid-cols-10` → tabla `col-span-7`, card `col-span-3`; apilar en móvil). Computar `agendadas = attended+no_show+cancelled`, `visitadas = attended`, `pct = agendadas ? round(visitadas/agendadas*100) : 0`. Reusa `metrics` ya cargado (no requiere otra llamada).
  - Card: reusar `KpiCard` o un bloque a medida que muestre las 3 cifras (Agendadas / Visitadas / %).
- **QA:** verificar por rango/proyecto/asesor; que `agendadas = cancelled+no_show+attended` cuadre con la tabla; manejar `agendadas=0` (mostrar "—" o 0%).

---

## 7. Archivos clave

### calendar-service
| Archivo | Rol |
|---|---|
| `src/migrations/003_add_appointment_state_to_calendar_events.sql` | Columna + CHECK + backfill inicial |
| `src/migrations/004-007_*.sql` | Backfills históricos de estados |
| `src/modules/events/commands/calendar_events.commands.js` | `markAttended`/`markNoShow`/`_markOutcome`, cancelar/reagendar |
| `src/modules/events/controllers/calendar_events.controller.js` | Rutas `/attended`, `/no-show` (~618) |

### app-saas-service
| Archivo | Rol |
|---|---|
| `app/api/v1/marketing_dashboard.py` | Endpoint `appointment-metrics` (268), schema `AppointmentMetricsResponse` (412), filtros (`_filters_dependency`) |
| `app/db/repositories/marketing_dashboard_repository.py` | Query de appointment metrics (~2351) ← **aquí se agrega `cancelled`** |
| `app/schemas/marketing_dashboard.py` | Schemas Pydantic |
| `app/services/calendar_microservice.py` | `mark_attended`/`mark_no_show` (397-421) |

### app-saas-frontend
| Archivo | Rol |
|---|---|
| `src/views/MarketingDashboardView.vue` | Vista del dashboard ← **aquí se agrega la card** |
| `src/components/marketing/KpiCard.vue` | Card individual reutilizable |
| `src/components/marketing/AppointmentMetricsTable.vue` | Tabla de métricas de citas (referencia) |
| `src/services/marketingDashboard.service.ts` | `getAppointmentMetrics(filters)` |
| `src/types/marketingDashboard.ts` | `AppointmentMetricsResponse`, `MarketingDashboardFilters` |
| `src/components/marketing/MarketingFilters.vue` | Filtros (rango fechas, proyecto, asesor…) |
