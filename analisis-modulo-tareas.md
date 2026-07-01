# Análisis Arquitectónico — Módulo de Tareas (PropFlow)

> Documento de referencia para futuras modificaciones del módulo de tareas. Evita re-analizar todo el módulo desde cero.
> Última actualización del análisis: 2026-06-30.

## Alcance / dónde vive el módulo

El "módulo de tareas" se reparte en **3 repos**:

- **`app-saas-service`** (Python/FastAPI) → **núcleo real** (API, negocio, datos, recordatorios).
- **`app-saas-frontend`** (Vue 3) → UI completa.
- **`calendar-service`** (Node/Express) → **solo** una herramienta MCP (`create_task`) que escribe directo a las mismas tablas SQL Server.

⚠️ El repo `task-flow` NO es código — son notas markdown de tickets, sin relación con este módulo.

El frontend usa `apiFetch` → apunta a `app-saas-service` (`:8000`, `VITE_API_BASE_URL`). Toda la API REST de tareas vive ahí.

---

## 1. Objetivo del módulo

**Problema que resuelve:** Gestionar el trabajo operativo del asesor inmobiliario sobre cada lead — qué hacer, cuándo, con qué prioridad y en qué estado va. Es el "to-do list operativo" del CRM, atado al ciclo de vida del lead.

**Responsabilidad:** CRUD de tareas + ciclo de estado (PENDIENTE → EN_PROGRESO → COMPLETADA/CANCELADA), con notas, adjuntos, auditoría (logs), recordatorios automáticos y **generación automática de tareas** según la fase del lead.

**Funcionalidades:**
- Tareas manuales (asesor desde UI) y **automáticas** (generadas por cambio de fase del lead).
- Dos vistas: **Kanban** (columnas de estado) y **Lista** (tabla con columnas configurables).
- Agrupación por asesor con resumen (pendientes / vencidas / hoy).
- **Urgencia tipo semáforo** (`urgency_status`: 0 verde / 1 hoy / 2 vencida).
- Notas + adjuntos (Azure Blob), logs de actividad, métricas.
- Recordatorios horarios (Temporal) y notificaciones (asignación, vencimiento, completado).
- Integración con motor de **workflows** (acción "crear tarea" / "crear serie de tareas").
- Integración con **agentes IA** vía MCP (`create_task`).

**Parte del negocio:** Capa de **ejecución de seguimiento comercial**. Conecta el pipeline de leads con la acción concreta del asesor (llamar, confirmar visita, reagendar, cerrar, negociar).

---

## 2. Arquitectura

```
app-saas-frontend (Vue 3)
 ├─ views/TasksView.vue                ← orquestador de la vista (filtros, kanban/lista)
 ├─ components/Tasks/
 │   ├─ TaskCard.vue                   ← tarjeta de tarea (urgencia, CTAs, cancelar)
 │   ├─ TaskForm.vue                   ← crear/editar (validaciones)
 │   ├─ TasksKanbanView.vue            ← Kanban drag&drop (vuedraggable)
 │   ├─ TasksListView.vue              ← tabla editable inline
 │   ├─ TaskNotesPanel.vue             ← notas + adjuntos (drag&drop, paste)
 │   ├─ TaskLogsModal.vue              ← timeline de auditoría
 │   ├─ TaskTableSettings.vue          ← columnas/vistas guardadas
 │   └─ TaskColumnOrderModal.vue       ← orden de columnas
 ├─ components/workflows/actions/forms/
 │   ├─ CreateTaskForm.vue             ← acción de workflow
 │   └─ CreateTaskSeriesForm.vue       ← acción de workflow (serie)
 ├─ services/tasks.service.ts          ← cliente HTTP (apiFetch → :8000)
 └─ types/tasks.ts                     ← enums + interfaces
        │ HTTP /api/v1/tasks…
        ▼
app-saas-service (FastAPI)
 ├─ api/v1/tasks.py                    ← 14 endpoints REST
 ├─ schemas/task.py                    ← Pydantic (TaskCreate/Update/Response…)
 ├─ services/
 │   ├─ auto_task_service.py           ← generación automática por fase (CIERRE, HITL, etc.)
 │   ├─ task_log_service.py            ← auditoría
 │   ├─ timeline_service.py            ← registro en lead_activity_timeline
 │   ├─ notification_service.py        ← task_assigned / due_soon / overdue
 │   └─ azure_storage_service.py       ← adjuntos en Blob
 ├─ db/repositories/
 │   ├─ task_repository.py             ← acceso a datos + queries kanban/grouped
 │   └─ task_note_repository.py        ← notas + attachments
 ├─ db/models.py                       ← Task, TaskActivityLog, TaskNote, TaskAttachment
 ├─ temporal/                          ← TaskReminderWorkflow (recordatorios horarios)
 └─ alembic/versions/…                 ← ~9 migraciones del módulo
        │ comparte SQL Server
        ▼
calendar-service (Node/Express)
 ├─ src/modules/tasks/entities/        ← Task + TaskActivityLog (Sequelize) ⚠️ desactualizadas
 └─ src/mcp/tools/tasks.tools.js       ← MCP tool `create_task` (escribe directo a DB)
```

**Relaciones:** El frontend es 100% cliente del backend Python. **No hay store Pinia dedicado** — el estado vive local en `TasksView` + optimismos locales por componente. El backend separa router → servicio/repositorio → modelos, con servicios transversales (timeline, notificaciones, storage). `calendar-service` **no** participa del flujo REST; solo su MCP escribe en las tablas compartidas.

---

## 3. Flujo completo (crear tarea manual)

```
1. Asesor pulsa "Nueva Tarea" en TasksView.vue
2. Abre TaskForm.vue → llena lead, asesor, tipo, prioridad, fecha, título
3. validate() en frontend (título 1-200, campos requeridos, descripción ≤500)
4. tasks.service.ts → createTask() → apiFetch POST /tasks/
5. api.config.ts añade Authorization: Bearer <Auth0> + X-Tenant-ID
6. app-saas-service: authentication_middleware valida token
7. Dependency: require_permission("tasks.create") + get_current_tenant/user
8. Schema TaskCreate valida (rechaza tipos deprecated si source=user)
9. TaskRepository.validate_lead_and_advisor() → verifica existencia (404 si no)
10. TaskRepository.create_task() → INSERT en tasks (status=PENDIENTE)
11. TaskLogService.log_event("TASK_CREATED")
12. TimelineService.track_task_created() → lead_activity_timeline
13. NotificationService → task_assigned (al asesor) + lead_task_created (followers)
14. TaskResponse (con urgency_status computado) → JSON
15. Frontend refetch getTasks() → re-renderiza grupos por asesor
16. (Opcional) notas pendientes del panel se suben como attachments post-creación
```

**Flujo automático:** Cambio de fase del lead → `lead_service` llama `AutoTaskService.on_phase_change()` (fire-and-forget) → `bulk_create` de un ciclo de N tareas (`source=AUTO`, `auto_kind=…`).

**Recordatorios:** `TaskReminderWorkflow` (Temporal, cada hora) → `check_due_soon_tasks` + `check_overdue_tasks` → notificaciones; si una tarea recién venció (<2h) y tiene lead, dispara el trigger `task_overdue` del motor de workflows.

---

## 4. Dependencias

**Consumen este módulo:**
- `app-saas-frontend`: `TasksView`, `LeadContextSidebar` (`getTasksByLead`), `EventModal` (tareas ligadas a evento), motor de workflows.
- **Agentes IA** vía MCP (`calendar-service` → `create_task`).
- Motor de **workflows** (acciones CreateTask / CreateTaskSeries).

**De qué depende:**
- `Lead` y `Advisor`/`User` (FKs, validación).
- `lead_activity_timeline` (registro de actividad).
- `NotificationService` + sistema de followers del lead.
- `AzureStorageService` (adjuntos).
- `Temporal` (recordatorios) + `workflow_rule_service` (trigger overdue).
- `calendar-service` indirectamente (resuelve fecha de visita para el ciclo de confirmación; `event_id`).

**Compartidas:** SQL Server (`dbo.tasks`, `task_activity_logs`, `task_notes`, `task_attachments`), Azure Blob, Auth0.

**Colas/cron:** No Celery propio del módulo. Recordatorios vía **Temporal scheduled workflow** (horario).

---

## 5. Modelo de datos

```
       leads ──1:N──┐                 advisors/users
                    │                       │
                    ▼ (lead_id, SET NULL)    ▼ (advisor_id, SET NULL)
              ┌──────────────────────────────────┐
              │              tasks               │
              │  id, tenant_id, title, desc,     │
              │  type, priority, status, source, │
              │  auto_kind, scheduled_datetime,  │
              │  completed_at, cancelled_at,     │
              │  cancellation_reason, event_id   │
              └──────────────────────────────────┘
                 │ 1:N                  │ 1:N
                 ▼ (task_id NULLABLE)   ▼ (task_id CASCADE)
        task_activity_logs        task_notes ──1:N──> task_attachments
        (auditoría)               (user_id)           (note_id SET NULL,
                                                       blob_path Azure)
```

**Tablas:** `tasks`, `task_activity_logs`, `task_notes`, `task_attachments`.

**Modelos SQLAlchemy:** `app/db/models.py` (aprox. L3532-3844): `Task`, `TaskActivityLog`, `TaskNote`, `TaskAttachment` + enums.

**Enums (SQL Server: almacenados como VARCHAR, sin CHECK estricto para valores nuevos):**
- `TaskType`: SEGUIMIENTO, REUNION, DOCUMENTO, OTRO, REAGENDAMIENTO, CONFIRMACION, NEGOCIACION + *deprecated* LLAMADA, CORREO, VISITA.
- `TaskPriority`: BAJA, MEDIA, ALTA, URGENTE.
- `TaskStatus`: PENDIENTE, EN_PROGRESO, COMPLETADA, CANCELADA.
- `TaskSource`: USER, AUTO, AGENT.
- `TaskAutoKind`: CONFIRMACION, REAGENDAMIENTO, CIERRE, NEGOCIACION, HITL.

**Frontend (`types/tasks.ts`) usa valores en minúscula** (`pendiente`, `seguimiento`, etc.); `CREATABLE_TASK_TYPES` excluye deprecated.

**Índices clave (`tasks`):** `idx_tasks_tenant`, `idx_tasks_status_type (tenant,status,type)`, `idx_tasks_advisor`, `idx_tasks_lead`, `idx_tasks_scheduled`, `idx_tasks_auto (tenant,lead,auto_kind,status)` ← idempotencia de auto-tareas.

**Constraints:** FKs con `ON DELETE SET NULL` (lead/advisor en tasks; user en notas/adjuntos) y `CASCADE` (task→notes, task→attachments). `task_activity_logs.task_id` es **nullable** a propósito (sobrevive al borrado de la tarea, para auditoría).

**Campos importantes:**
- `urgency_status` **NO existe en BD** — es *computed field* en `TaskResponse` (0/1/2 según `scheduled_datetime` vs ahora). Lógica: cerrada o sin fecha ⇒ 0; `< now` ⇒ 2; `≤ mañana` ⇒ 1; resto ⇒ 0.
- `event_id` (String 36) vincula con calendar-service **sin FK**.
- Campos legacy duplicados: `completed_date` (frontend) vs `completed_at` (BD).

---

## 6. Endpoints REST (`app/api/v1/tasks.py`)

| Método | Ruta | Permiso | Notas |
|---|---|---|---|
| POST | `/tasks/` | `tasks.create` | Crea (status=PENDIENTE), log+timeline+notif |
| GET | `/tasks` | `tasks.view` | Agrupadas por asesor; filtra por advisor si no `view_all_advisors` |
| GET | `/tasks/kanban` | `tasks.view` | Columnas pendiente/en_progreso/completada/cancelada; top 20 + total |
| GET | `/tasks/{id}` | `tasks.view` | |
| GET | `/tasks/by-lead/{lead_id}` | `tasks.view` | overdue_count, due_today_count, tasks |
| GET | `/tasks/metrics` | `tasks.view` | pending / overdue / completed_this_week |
| PATCH | `/tasks/{id}` | `tasks.edit` | Reasignar asesor exige `view_all_advisors`/admin; completar→completed_at; cancelar→cancelled_at+reason |
| DELETE | `/tasks/{id}` | `tasks.delete` | Log TASK_DELETED + timeline |
| PATCH | `/tasks/{id}/complete` | `tasks.edit` | Valida no cerrada; set COMPLETADA |
| GET | `/tasks/{id}/logs` | `tasks.view` | Timeline de auditoría |
| GET/POST | `/tasks/{id}/notes` | `tasks.view` / `tasks.edit` | Notas; GET genera SAS URLs de adjuntos |
| POST | `/tasks/{id}/attachments` | `tasks.edit` | multipart; MIME whitelist + ≤10MB; Azure Blob |
| DELETE | `/tasks/{id}/attachments/{attachment_id}` | `tasks.edit` | Borra DB + blob |

**Cliente frontend:** `services/tasks.service.ts` (`getTasks`, `getTask`, `createTask`, `updateTask`, `deleteTask`, `completeTask`, `getTasksByLead`, `getTaskMetrics`, `getTaskLogs`, `getNotes`, `createNote`, `uploadAttachment`, `deleteAttachment`, `getKanban`).

---

## 7. Reglas de negocio

| Regla | Dónde | Cómo funciona | Si cambia |
|---|---|---|---|
| Estado inicial PENDIENTE | `task_repository.create_task` / modelo | default | Afecta kanban y métricas |
| Completar setea `completed_at`; no se puede recompletar | `complete_task` (repo, ~L80) | valida estado ≠ completada/cancelada, lanza 400 | Riesgo de doble conteo en métricas |
| Cancelar setea `cancelled_at` + `cancellation_reason`; revertir limpia ambos | `PATCH /tasks/{id}` (~L317-321) | auto-set/limpieza | UI exige razón al cancelar (5 motivos predefinidos) |
| Tipos *deprecated* prohibidos en creación manual | `schemas/task.py` validador (~L65-75) | `source=USER` ⇒ solo CREATABLE_TYPES | Romper compat de tareas legadas |
| Urgencia semáforo | `TaskResponse.urgency_status` computed | <now ⇒ 2; ≤mañana ⇒ 1; resto/cerrada ⇒ 0 | Cambia colores y filtros en toda la UI |
| Reasignar asesor requiere permiso | `PATCH` (~L291-294) | exige `tasks.view_all_advisors` o system_admin | Control de transferencias |
| Asesor solo ve sus tareas | GET endpoints (~L214,260) | sin `tasks.view_all_advisors` filtra por su `advisor_id` | Visibilidad / privacidad |
| **Ciclos de auto-tareas por fase** | `auto_task_service.py` | CONFIRMACION (1-2), REAGENDAMIENTO (7), CIERRE (7), NEGOCIACION (8 en 14d), HITL (7) | Cambia volumen de tareas generadas; alto impacto operativo |
| Idempotencia de auto-tareas | `lead_ids_with_pending_auto` + `idx_tasks_auto` | no duplica ciclo activo | Riesgo de spam de tareas |
| Nunca borra auto-tareas completadas/canceladas | `delete_pending_auto` | solo borra activas | Pérdida de historial |
| Limpieza final | `_handle_limpieza_final` | descartado/cerrado_ganado ⇒ borra todas las auto activas | — |
| Horarios en hora Guatemala (UTC-6) guardados como UTC naive | `auto_task_service` constantes | 16h/07h/08h/09h/10h | Recordatorios a hora incorrecta si cambia |
| Kanban: top 20 por columna + total real | `list_tasks_kanban` (ROW_NUMBER) | window function | Performance / completitud visual |

**Ciclos de auto-tareas (`auto_task_service.py`), horarios en hora Guatemala (UTC-6) guardados como UTC naive:**
- **CONFIRMACION** (visita_agendada): si ≥24h → 2 tareas (T1 día previo 16:00, T2 día visita 07:00); si <24h → 1 tarea (T2). Borra reagendamiento pendiente previo.
- **REAGENDAMIENTO** (visita vencida sin reagendar): 7 tareas diarias 08:00.
- **CIERRE** (cita_completada): 7 tareas diarias 09:00 desde mañana.
- **NEGOCIACION**: 8 tareas 10:00, offsets [1,3,5,7,9,11,13,14] días.
- **HITL** (lead calificado → control manual): 7 tareas 10:00.
- Disparador: `on_phase_change()` (fire-and-forget desde lead_service) y `on_hitl_activated()`.

---

## 8. Permisos / autorización

- **Autenticación:** Auth0 JWT Bearer + `X-Tenant-ID` → `authentication_middleware` (backend), Auth0 SPA SDK (frontend).
- **Autorización (RBAC):** dependency `require_permission(...)` por endpoint.
- **Permisos del módulo:** `tasks.create`, `tasks.view`, `tasks.edit`, `tasks.delete`, `tasks.view_all_advisors`.
- **Regla de scope:** sin `tasks.view_all_advisors` un asesor solo ve/edita sus tareas (filtro por su `advisor_id`); con él (supervisor/manager) ve todo y puede reasignar. `system_admin` sin restricción.
- **Frontend:** ruta `/tasks` con `meta.requiresPermission: 'tasks.view'`; composable `usePermission().can('tasks.create'|'edit'|'delete')` oculta botones; transferir asesor solo `owner`/`system_admin`.
- **Doble enforcement:** el guard del router es defensa superficial; el backend es la autoridad real.

---

## 9. Validaciones

- **Frontend (TaskForm):** título 1-200, descripción ≤500, tipo/prioridad/fecha/lead/asesor requeridos; adjuntos MIME whitelist + ≤10MB.
- **Backend (Pydantic, `schemas/task.py`):** `TaskCreate` con límites de longitud + validador que **rechaza tipos deprecated** cuando `source=user`.
- **Backend (negocio/repo):** `validate_lead_and_advisor` (404), `complete_task` (400 si ya cerrada), validación de existencia al cambiar lead/advisor, validación de permiso para reasignar, validación MIME+tamaño en upload.
- **BD:** FKs, NOT NULL, longitudes de columna; enums como VARCHAR (sin CHECK estricto → validación recae en la app).
- **Adjuntos permitidos:** jpeg, png, gif, webp, pdf, doc/docx, xls/xlsx. Máx **10MB**.

---

## 10. Eventos

**Notificaciones emitidas (`notification_service.py`):** `task_assigned` (al crear, al asesor), `lead_task_created` (followers), `lead_task_completed` (followers, fire-and-forget con idempotency key), `task_due_soon` y `task_overdue` (Temporal horario).

**Timeline (`timeline_service.py`):** `track_task_created / updated / completed / deleted` → `lead_activity_timeline`.

**Logs de auditoría (`task_activity_logs`):** `TASK_CREATED`, `STATUS_CHANGED`, `TASK_UPDATED`, `TASK_DELETED`.

**Jobs:** `TaskReminderWorkflow` (Temporal, cada hora) → `check_due_soon_tasks` + `check_overdue_tasks`.

**Trigger de workflows:** `task_overdue` dispara el motor de reglas si la tarea recién venció (<2h).

**Realtime UI:** la vista se suscribe a `task_created` en el store de notificaciones.

**Sin webhooks/colas externas propias.**

---

## 11. Integraciones

- **Azure Blob Storage** (`azure_storage_service.py`, ~L1223-1294): adjuntos. Container por tenant, path `tasks/{task_id}/{uuid}.ext`, lectura vía **SAS URL** (expiry 1h). Borrado de blob no bloquea el endpoint si falla.
- **Auth0:** autenticación.
- **Temporal:** recordatorios programados.
- **Notificaciones internas** (in-app a asesor/followers) — sin email/WhatsApp directos del módulo (los CTAs WhatsApp/llamar en UI solo abren enlaces).
- **MCP / Agentes IA:** `calendar-service` expone `create_task` (Zod schema) que escribe directo en `dbo.tasks` + `task_activity_logs` vía Sequelize (no llama a app-saas-service).
- **Calendar-service:** resolución de fecha de visita para el ciclo de confirmación; `event_id`.

---

## 12. Riesgos / deuda técnica

**🔴 Alto**
- **Drift de esquema en calendar-service:** la entity Sequelize tiene esquema **viejo** (`scheduled_date` DATE en vez de `scheduled_datetime`; enum sin DOCUMENTO/CONFIRMACION/etc.; **sin** `source`/`auto_kind`/`event_id`/`cancelled_at`/`cancellation_reason`). El MCP `create_task` escribe directo a la tabla compartida — **dos servicios escriben la misma tabla sin contrato común.**
- **Lógica temporal frágil:** horarios hard-codeados en hora Guatemala guardados como UTC-naive. Tenants en otra zona o cambios de DST → recordatorios a hora incorrecta.

**🟠 Medio**
- **Generación masiva de auto-tareas:** ciclos de 7-8 tareas por lead/fase; bug en idempotencia (`idx_tasks_auto` / `lead_ids_with_pending_auto`) → spam. Concurrencia entre cambio de fase (fire-and-forget) y job Temporal de visita vencida podría duplicar.
- **Optimismo de UI sin reconciliación robusta:** múltiples estados locales (`localStatus`, `optimisticStatus`) en varios componentes.
- **Sin store Pinia:** estado y refetch dispersos → re-fetches completos tras cada cambio.
- **Kanban top-20:** se muestran 20 por columna pero el total es real → posible confusión / tareas "invisibles".

**🟡 Bajo / deuda**
- Tipos *deprecated* (LLAMADA/CORREO/VISITA) conviviendo con los nuevos → ramas de compatibilidad en front y back.
- Campos legacy duplicados (`completed_date` vs `completed_at`).
- Borrado de adjunto en Azure no transaccional con la BD (huérfanos posibles).

---

## 13. Impacto de cambios

| Cambio | Impacto | Por qué |
|---|---|---|
| Tocar enums (`TaskType/Status/AutoKind`) | **Alto** | Compartidos entre frontend, backend, MCP, migraciones y `auto_task_service`; VARCHAR sin CHECK |
| Modificar `urgency_status` | **Alto** | Computado en backend pero usado para colores/filtros/orden en toda la UI |
| Cambiar `auto_task_service` (ciclos) | **Alto** | Define volumen y timing de tareas de todo el funnel comercial |
| Esquema de tablas `tasks*` | **Alto** | Doble lector/escritor (Python + Sequelize MCP) + ~9 migraciones |
| Permisos (`tasks.*`) | **Medio** | Afecta visibilidad por asesor y guards de UI |
| Endpoints REST (firma) | **Medio** | `tasks.service.ts` + 8 componentes consumidores |
| Adjuntos/Blob | **Medio** | Aislado en panel de notas, pero toca Azure |
| Componentes de UI individuales | **Bajo** | Bien encapsulados |

---

## 14. Archivos importantes

**Backend (`app-saas-service`)**
- `app/api/v1/tasks.py` — 14 endpoints REST (núcleo de la API).
- `app/services/auto_task_service.py` — **corazón del negocio**: tareas automáticas por fase.
- `app/db/repositories/task_repository.py` — acceso a datos, kanban, agrupación, auto-tareas.
- `app/db/repositories/task_note_repository.py` — notas + adjuntos.
- `app/services/task_log_service.py` — auditoría.
- `app/schemas/task.py` — contratos + validaciones + constantes de adjuntos.
- `app/db/models.py` (~L3532-3844) — Task, TaskActivityLog, TaskNote, TaskAttachment + enums.
- `app/temporal/workflows_task_reminders.py` + `activities_task_reminders.py` — recordatorios.
- `app/services/azure_storage_service.py` (~L1223-1294) — upload/SAS/delete de adjuntos.
- `alembic/versions/` — ~9 migraciones (creación, logs nullable, event_id, notas/adjuntos, source/auto_kind, DOCUMENTO, HITL, cancellation_reason).

**Frontend (`app-saas-frontend`)**
- `src/views/TasksView.vue` — orquestador (filtros, kanban/lista, deep-links `?task_id=` / `?lead_id=`).
- `src/components/Tasks/TaskForm.vue` — crear/editar + validaciones.
- `src/components/Tasks/TasksKanbanView.vue` / `TasksListView.vue` — las dos vistas.
- `src/components/Tasks/TaskCard.vue` — tarjeta con urgencia/CTAs/cancelación.
- `src/components/Tasks/TaskNotesPanel.vue` — notas + adjuntos.
- `src/services/tasks.service.ts` — cliente HTTP.
- `src/types/tasks.ts` — enums e interfaces (fuente de verdad de tipos en UI).
- `src/components/workflows/actions/forms/CreateTask(Series)Form.vue` — integración con workflows.

**Calendar-service**
- `src/mcp/tools/tasks.tools.js` — MCP `create_task`.
- `src/modules/tasks/entities/*.entity.js` — entities Sequelize (⚠️ desactualizadas).

---

## 15. Resumen ejecutivo

**Cómo funciona:** Sistema de gestión de tareas operativas del CRM, atado al ciclo de vida del lead. Backend FastAPI + SQL Server con 14 endpoints REST; frontend Vue con vistas Kanban y Lista; estado optimista local (sin store Pinia). Tareas **manuales** (asesor) o **automáticas** — generadas por `AutoTaskService` en ciclos según la fase del lead (confirmación, reagendamiento, cierre, negociación, HITL). Recordatorios horarios vía Temporal; notificaciones, auditoría y timeline integrados. Adjuntos en Azure Blob con SAS URLs.

**Componentes principales:** `api/v1/tasks.py` · `auto_task_service.py` · `task_repository.py` · `TasksView.vue` + componentes · `TaskReminderWorkflow` · MCP `create_task`.

**Flujo principal:** UI → `tasks.service` → REST `/api/v1/tasks` (auth + RBAC + validación) → repo/servicio → SQL Server + logs + timeline + notificaciones → respuesta con `urgency_status` computado → refetch en UI.

**Riesgos clave:** (1) drift de esquema entre el MCP de calendar-service y la tabla real; (2) doble escritor sin contrato; (3) horarios hard-codeados en UTC-6; (4) posible duplicación/spam de auto-tareas; (5) deuda por tipos deprecated y estado optimista disperso.

**Puntos de extensión naturales:** nuevos `auto_kind` (ciclos), nuevos canales de notificación (email/WhatsApp en vez de solo in-app), un store Pinia para estado incremental, recurrencia manual real (hoy solo existen "series" como ciclos automáticos), y un contrato compartido para los enums entre los tres repos.

**Antes de modificar:** tratar enums y esquema de `tasks` como **contrato compartido versionado**; cuidar la sincronización con el MCP de calendar-service; externalizar horarios a config por tenant/zona; validar idempotencia de auto-tareas ante concurrencia antes de tocar `auto_task_service`.
