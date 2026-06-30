# Módulo de Workflows — Resumen técnico

## Qué es

Sistema de automatización de acciones del CRM. Permite configurar reglas del tipo **"cuando ocurre X, y se cumplen las condiciones Y, ejecutar las acciones Z"**. Diseñado para que el equipo comercial automatice tareas repetitivas sin escribir código: asignar asesores, crear tareas de seguimiento, notificar en Slack, cambiar fases de leads.

---

## Arquitectura

```
┌──────────────────────────────────────────┐
│         WorkflowsView (Vue 3)            │
│  WorkflowList → WorkflowEditorDrawer     │
│  WorkflowEditor (trigger/conditions/     │
│  actions) → WorkflowLogModal             │
└──────────────────┬───────────────────────┘
                   │ GET/POST/PUT/PATCH
                   ▼
┌──────────────────────────────────────────┐
│   app-saas-service                       │
│   POST /api/v1/workflow-rules/           │
│   GET  /api/v1/workflow-rules/           │
│   PATCH /api/v1/workflow-rules/{id}/status│
│   GET  /api/v1/workflow-rules/{id}/logs  │
│   POST /api/v1/workflow-rules/{id}/duplicate│
└────────┬─────────────────────────────────┘
         │ Trigger (en cada mutación de lead)
         ▼
┌─────────────────────────────────────────────────┐
│  WorkflowRuleService.evaluate_and_fire()         │
│    1. Filtra workflows activos del tenant        │
│    2. Evalúa trigger_type                        │
│    3. Evalúa condiciones (AND)                   │
│    4. Ejecuta acciones en orden                  │
│       · delay == 0  → inmediato                  │
│       · delay > 0   → Temporal (timer durable)   │
│    5. Graba WorkflowExecution log                │
└──────────────────────────────────────────────────┘
         │
         └── Temporal: inactividad, same-status-days y acciones con delay
```

**Base de datos:** SQL Server (Azure) — tabla `workflow_rules`, `workflow_executions`.
**Multitenancy:** todos los recursos están aislados por `tenant_id`. El motor nunca cruza tenants.

---

## Triggers (12)

| Trigger | Cuándo se activa |
|---|---|
| `lead_status_changed` | El lead cambia de fase (opcionalmente desde/hasta una fase específica) |
| `lead_created` | Se crea un lead nuevo |
| `lead_assigned` | Se asigna un asesor al lead |
| `task_completed` | Se completa una tarea (filtrable por tipo) |
| `task_overdue` | Una tarea vence sin completarse |
| `task_cancelled` | Se cancela una tarea |
| `visit_scheduled` | Se agenda una visita |
| `visit_confirmed` | El lead confirma la visita |
| `visit_no_show` | El lead no se presenta |
| `visit_no_answer` | El lead no responde al contacto de visita |
| `lead_inactive_days` | El lead lleva N días sin actividad |
| `lead_same_status_days` | El lead lleva N días en la misma fase |

Los triggers de inactividad y `same_status_days` corren vía **Temporal** en un checker periódico. Los demás se disparan sincrónicamente cuando el evento ocurre en `lead_service.py`.

---

## Condiciones (8 campos)

Las condiciones se evalúan en AND. Todas son opcionales; sin condiciones el workflow aplica a todos los leads del tenant.

| Campo | Operadores |
|---|---|
| `project_id` | `in`, `not_in` |
| `status` | `is`, `is_not` |
| `source` | `is`, `is_not` (por `source_id`) |
| `has_scheduled_visit` | `yes`, `no` |
| `advisor_id` | `is`, `is_not`, `in`, `not_in` (multiselect) |
| `advisor_group_id` | `belongs_to` *(coming soon — fail-open)* |
| `task_type` | `is`, `is_not` |
| `task_source` | `is`, `in` (`system` / `manual`) |

---

## Acciones (5 tipos)

### 1. `create_task`
Crea una tarea asignada a:
- El asesor del lead
- Un asesor específico
- Un rol específico (supervisor / manager / coordinador / asesor)

Configurable: tipo, prioridad, fecha de vencimiento (base relativa al trigger), regla de duplicados (siempre / omitir si pendiente / reemplazar).

### 2. `create_task_series`
Crea N tareas espaciadas en el tiempo (ej: 7 seguimientos cada 2 días). Mismas opciones de asignación que `create_task`.

### 3. `send_slack_notification`
Envía un mensaje a un canal de Slack del tenant. Soporta tokens dinámicos (`{{lead.nombre}}`, `{{asesor.nombre}}`, `{{fecha.hoy}}`, etc.) y opción de incluir botón "Ver lead".

### 4. `change_lead_status`
Mueve el lead a otra fase del CRM. Incluye advertencia en el editor si puede generar ciclos infinitos con otros workflows de tipo `lead_status_changed`.

### 5. `assign_advisor`
Cambia el asesor del lead. Modos:
- Asesor específico
- Round Robin (entre todos los asesores activos del tenant)
- Menos leads (asigna al asesor con menor carga)

---

## Delay (ejecución diferida)

Cada acción puede configurar un delay de 0 a N horas/días. Acciones con delay arrancan un workflow de **Temporal** (`DelayedWorkflowActionWorkflow`) con un timer durable; al expirar, una activity ejecuta la acción. El contexto del lead se recarga en el momento de ejecución para evitar estados stale. El workflow_id es determinista (`delayed-action-{tenant}-{rule}-{action}-{lead}-{epoch}`), por lo que un re-disparo idéntico colapsa sobre el workflow en curso (idempotencia). Se conserva un guard de dedup (±2h) en la ejecución por seguridad ante reintentos.

---

## Log de ejecuciones

Cada disparo del workflow queda registrado en `WorkflowExecution` con:
- `status`: `success` / `partial` / `failed` / `skipped`
- Resultado de cada acción individual
- Lead, tenant, duración, timestamp
- Razón de skip (si aplica)

El log es consultable desde el editor (botón "Ver log") con paginación, filtro por estado y exportación a CSV.

---

## Editor (frontend)

El editor es un drawer lateral con 3 bloques:

**① Disparador** — selector de grupo + evento + parámetros del trigger (fase destino, días de inactividad, etc.)

**② Condiciones** — lista dinámica de condiciones con campo / operador / valor. Cada combinación campo+operador tiene su propio input (select, multiselect con Teleport, coming-soon placeholder).

**③ Acciones** — lista de acciones con:
- Drag & drop para reordenar (HTML5 nativo)
- Botones arriba/abajo como fallback de accesibilidad
- Delay configurable por acción
- Formulario específico según tipo

El editor muestra un **resumen en lenguaje natural** del workflow en tiempo real (ej: "Cuando un lead cambia de fase → si el proyecto es Torre Norte → crear tarea de seguimiento").

---

## Gestión de workflows

- **Estados:** `draft` → `active` / `inactive`
- Los drafts no pueden activarse desde el toggle de la lista; deben completarse en el editor.
- **Duplicar:** genera una copia en estado draft.
- **Permisos:** ruta protegida con `workflows.view` (RBAC).

---

## Fases de desarrollo

| Fase | Contenido |
|---|---|
| 1 | Modelo DB, migración, schemas, repositorio, router básico, WorkflowList |
| 2 | Editor completo (trigger + conditions + actions), i18n ES/EN, formularios por tipo de acción |
| 3 | Motor de ejecución (`workflow_action_executor.py`, `workflow_rule_service.py`), integración en `lead_service.py` |
| 4 | Delays con Temporal (`DelayedWorkflowActionWorkflow`), triggers de inactividad con Temporal |
| 5 | Log de ejecuciones, modal de log, exportación CSV, integración con `lead_activity_timeline` |
| 6 | Condición fuente/asesor multiselect, grupos coming-soon, DnD, rol específico, operadores `is_not`/`not_in` |

---

## Archivos principales

### Backend (`app-saas-service`)
| Archivo | Rol |
|---|---|
| `app/db/models_workflow_rules.py` | Modelos `WorkflowRule`, `WorkflowExecution` |
| `app/schemas/workflow_rule.py` | Schemas Pydantic de request/response |
| `app/db/repositories/workflow_rule_repository.py` | Acceso a datos |
| `app/services/workflow_rule_service.py` | Orquestador: evaluar trigger → condiciones → acciones |
| `app/services/workflow_action_executor.py` | Ejecutor de cada tipo de acción + evaluador de condiciones |
| `app/api/v1/workflow_rules.py` | Router FastAPI |
| `app/services/workflow_delayed_executor.py` | Lógica compartida de ejecución de acción diferida (engine-agnóstica) |
| `app/temporal/workflows_workflow_delayed.py` | `DelayedWorkflowActionWorkflow` (timer durable para acciones con delay) |
| `app/temporal/activities_workflow_delayed.py` | Activity Temporal que ejecuta la acción diferida |
| `app/temporal/activities_workflow_inactivity.py` | Activity Temporal para inactividad |

### Frontend (`app-saas-frontend`)
| Archivo | Rol |
|---|---|
| `src/views/WorkflowsView.vue` | Vista raíz |
| `src/components/workflows/WorkflowList.vue` | Tabla con toggle activo/inactivo y menú |
| `src/components/workflows/WorkflowEditor.vue` | Editor principal (3 bloques) |
| `src/components/workflows/WorkflowEditorDrawer.vue` | Contenedor drawer |
| `src/components/workflows/WorkflowSummary.vue` | Resumen en lenguaje natural |
| `src/components/workflows/WorkflowLogModal.vue` | Modal de log de ejecuciones |
| `src/components/workflows/conditions/` | ConditionsBlock, ConditionRow, ConditionValueInput |
| `src/components/workflows/actions/` | ActionsBlock, ActionCard, ActionPicker, forms/ |
| `src/composables/useWorkflowEditor.ts` | Lógica del editor (validación, guardado, estado) |
| `src/stores/workflowRules.ts` | Estado global (Pinia) |
| `src/services/workflowRules.service.ts` | Cliente HTTP |
| `src/types/workflow.ts` | Tipos TypeScript del dominio |
