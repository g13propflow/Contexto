# Ampliación de triggers y config de tareas en Workflows + rediseño UX/UI (SCRUM-1308)

## Fecha
2026-07-07

## Tarea solicitada (en concreto)
Ampliar el módulo de **Workflows** (`workflow_rules`) con (HU):
1. **Nuevo trigger "Cuando un lead pase a HITL"** — al pasar el lead a control manual.
2. **Vencimiento de tareas relativo a la visita** — vencer *N horas antes* del evento
   (1/2/12/24/48 + personalizado) en "Crear tarea" y "Serie de tareas".
3. **Nuevos tipos de tarea**: Negociación, Reagendamiento, Confirmación.

Durante la tarea se añadió, a pedido del usuario: **cablear los triggers de visita/tarea**
que estaban en el catálogo pero no disparaban, y un **rediseño UX/UI** del builder y el
listado (responsive web + móvil).

Plan: `PLAN-workflows-hitl-vencimiento-evento-tipos-tarea.md`.

## Rama y commits
Rama **`feature/SCRUM-1308`** en ambos repos (sin push; lo hace el usuario).

**`app-saas-service`** (backend):
- `feat(workflows)`: trigger HITL + vencimiento por visita + (tipos ya existían en enum)
- `feat(workflows)`: cablear puntos de disparo de triggers de visita/tarea
- `test(workflows)`: corregir mock desactualizado en test de `send_email`

**`app-saas-frontend`**:
- `feat(workflows)`: trigger HITL (selector/i18n/resumen), DueDatePicker por visita, tipos centralizados
- `fix(workflows)`: tipado preexistente de `statusItems` en `WorkflowEditor`
- `style(workflows)`: rediseño UX/UI del builder + listado (web + móvil)

## Módulos afectados

### Backend `app-saas-service`
- `app/db/repositories/workflow_rule_repository.py` — label del trigger `lead_entered_hitl`.
- `app/services/hitl_trigger.py` (nuevo) — disparo fire-and-forget HITL.
- `app/services/workflow_trigger_dispatch.py` (nuevo) — disparo genérico (visita/tarea).
- `app/services/lead_service.py` — disparo HITL en los 2 choke points AUTOMATED→MANUAL.
- `app/agents/tools/expediente_tools.py` — HITL en escalación + `visit_scheduled`/`visit_confirmed` (schedule_visit/confirm_visit).
- `app/api/v1/tour_scheduled.py` — `visit_scheduled` (marketplace).
- `app/temporal/activities_visit_followup.py` — `visit_no_show`.
- `app/api/v1/tasks.py` — `task_completed` / `task_cancelled`.
- `app/services/workflow_action_executor.py` — `visit_datetime` en contexto, `_resolve_due_date` (visit_date/hours_before), serie anclada.
- `app/services/workflow_rule_service.py` — resolución de visita en `_enrich_context` (solo si se necesita).
- `app/services/workflow_delayed_executor.py` — pasa la acción a `_enrich_context`.
- `tests/unit/workflows/` — `test_resolve_due_date.py`, `test_hitl_trigger_catalog.py`, `test_workflow_trigger_dispatch.py` (nuevos) + fix de `test_send_email_action.py`.
- `WORKFLOWS_MODULE_SPEC.md` (repo raíz) — trigger HITL + estado de cableado.

### Frontend `app-saas-frontend`
- `src/assets/main.css` — clases reutilizables `wf-input/wf-select/wf-textarea/wf-label`.
- Builder: `WorkflowEditor`, `TriggerBlock`, `TriggerGroupSelector`, `TriggerEventSelector`, `TriggerParamsForm`, `ConditionsBlock`, `ConditionRow`, `ConditionValueInput`, `ActionsBlock`, `ActionCard`, `DueDatePicker`, `ActionDelayPicker`, `WorkflowSummary`, y forms (`CreateTaskForm`, `CreateTaskSeriesForm`, `SlackNotificationForm`, `SendEmailForm`, `ChangeStatusForm`, `AssignAdvisorForm`).
- `WorkflowList` (responsive: tabla desktop / tarjetas móvil, menú unificado), `WorkflowLogModal` (modal centrado responsive).
- `src/components/workflows/taskTypeOptions.ts` (+ test), `src/composables/useWorkflowSummary.ts`, `src/types/workflow.ts`, `src/locales/{es,en}/workflowsSettings.ts`.

---

## Decisiones tomadas (confirmadas con el usuario)
- **Trigger HITL** = transición a `control_status = MANUAL` sin importar la causa.
  Cableado en los choke points deterministas (`lead_service`) + escalación de expediente.
- **Evento de R2** = la visita del lead (`calendar_event_id`), resuelta vía calendar-service.
- **Tipos de tarea** = catálogo central (single source of truth).
- **Serie + horas antes**: escalonado hacia atrás (todas antes de la visita).
- **`visit_no_answer` NO cableado**: no existe transición de ese estado (solo `no_answer` de llamadas). Documentado como pendiente.
- **UX**: pasos siempre visibles (no acordeón); colapso a nivel de tarjeta de acción.
- **App light-only**: se evitaron clases `dark:` (Tailwind sin `darkMode`).

## Verificación
- **Backend**: `pytest tests/unit/workflows/` → **34/34** (en contenedor Docker, código montado en vivo). `py_compile` + imports OK.
- **Frontend**: **`vite build` (prod) ✓**; `type-check` sin errores en `workflows/`; `vitest` **7/7**.

## Pendientes / seguimiento (a cargo del usuario)
- **Push + PRs** (textos entregados en la sesión).
- **Verificación visual** final en navegador (desktop + móvil).
- **Docs del repo raíz** (`PLAN`, `WORKFLOWS_MODULE_SPEC.md`, esta bitácora) — versionar si se desea.
- **Reconciliación de migraciones** (`cn01` + `mp01propsel` + merge `054dcb9dce83`) en un **PR aparte**: la columna `leads.property_model_id` se aplicó a la BD de Azure durante el bring-up local; el archivo del merge se eliminó del working tree para no commitearlo con esta HU, así que repo y BD quedan desincronizados hasta ese PR.

## Nota de entorno (no forma parte de los commits de la HU)
Para levantar el local, el listado de leads reventaba (500) por `Invalid column name 'property_model_id'` — drift preexistente. Se reconcilió aplicando `cn01`+`mp01propsel`+`ec12` y un merge (`054dcb9dce83`) a la BD de Azure. Ese merge era **solo de bring-up** y se retiró del working tree; su reconciliación formal va en PR separado.
