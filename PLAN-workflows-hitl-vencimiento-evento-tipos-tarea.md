# PLAN — Ampliación de triggers y configuración de tareas en Workflows

> HU: nuevo trigger **HITL**, vencimiento de tareas **relativo a la visita (horas antes)** y nuevos **tipos de tarea** (Negociación / Reagendamiento / Confirmación) en el módulo de Workflows (`workflow_rules` / `workflow-rules`).
>
> Estado: **plan, no desarrollado.** Pendiente de confirmación del usuario.

---

## 0. Decisiones ya tomadas (por el usuario)

1. **Trigger HITL** → se dispara cuando `lead.control_status` pasa de `AUTOMATED` a `MANUAL`, **sin importar la causa** (fase `requires_hitl` o toma manual / handoff de agente IA).
2. **Vencimiento relativo (R2)** → el "evento" es la **visita/evento de calendario del lead** (`lead.extra_data["calendar_event_id"]`). El vencimiento = fecha/hora de la visita − N horas.
3. **Tipos de tarea (R3)** → reemplazar las listas hardcodeadas del builder por el **catálogo central** `src/types/tasks.ts` (`CREATABLE_TASK_TYPES` / `TASK_TYPE_LABELS`). Single source of truth.

---

## 1. Estado actual (hallazgos de la investigación)

### Backend (`app-saas-service`)
- Módulo `workflow_rules`: modelos `app/db/models_workflow_rules.py`, schemas `app/schemas/workflow_rule.py`, motor `app/services/workflow_rule_service.py` + `app/services/workflow_action_executor.py`, API `app/api/v1/workflow_rules.py`, repo `app/db/repositories/workflow_rule_repository.py`.
- Triggers: **no hay enum**; son strings validados. Catálogo en `WORKFLOWS_MODULE_SPEC.md §2.4` y en `_TRIGGER_LABELS` (`workflow_rule_repository.py:22-35`). `_match_trigger_params` (`workflow_rule_service.py:203-227`) devuelve `True` por defecto para triggers sin params.
- Tipos de tarea: enum `TaskType` (`app/db/models.py:3738-3750`) **ya incluye** `negociacion`, `reagendamiento`, `confirmacion`. → **R3 backend = 0 cambios.**
- Due date: `_resolve_due_date` (`workflow_action_executor.py:925-952`) **solo implementa `base=trigger_date`**; `visit_date`/`reservation_date` hacen fallback a `trigger_date` (L940-941). Solo suma (offset positivo).
- `WorkflowExecutionContext` (`workflow_action_executor.py:46-67`): tiene `lead`, `triggered_at`, `task`, labels; **no** tiene fecha de visita.
- Enriquecimiento de contexto: `_enrich_context` (`workflow_rule_service.py:483-510`) — aquí se añadiría la fecha de la visita.
- HITL: **no es una fase**. Es `LeadControlStatus.MANUAL` (`models.py:27-31`). Se pone en MANUAL en ~15 sitios (ver §2.1).
- Tareas de workflow **no** se ligan a eventos de calendario (`Task.event_id` queda NULL); su fecha vive en `Task.scheduled_datetime`.

### Frontend (`app-saas-frontend`)
- Builder en `src/components/workflows/`. Tipos en `src/types/workflow.ts`. Servicio `src/services/workflowRules.service.ts`. i18n `src/locales/{es,en}/workflowsSettings.ts`.
- Triggers: unión `WorkflowTriggerType` (`types/workflow.ts:8-20`), agrupados en `trigger/TriggerEventSelector.vue:28-33` (`EVENTS_BY_GROUP`), grupos en `trigger/TriggerGroupSelector.vue:36-41`, labels i18n `workflowsSettings.ts:53-66`.
- Due date: `actions/DueDatePicker.vue` (solo lo usa "Crear tarea"). Bases `trigger_date`/`visit_date`/`reservation_date`; solo "después" (offset positivo, `min="0"`). Default en `composables/useWorkflowEditor.ts:33`.
- Serie de tareas: `actions/forms/CreateTaskSeriesForm.vue` **no usa** DueDatePicker; usa `series_count` / `interval_days` / `start_offset_days` / `fixed_time`.
- Tipos de tarea: **hardcodeados y duplicados en 4 archivos** (`trigger/TriggerParamsForm.vue:79-84`, `actions/forms/CreateTaskForm.vue:142-147`, `actions/forms/CreateTaskSeriesForm.vue:140-145`, `conditions/ConditionValueInput.vue:132+`), con valores viejos `llamada/seguimiento/reunion/correo` — desalineados del catálogo central.

### Sin migraciones de BD
`trigger_type` es String y `config_json`/`trigger_params` son JSON. **Ninguno de los 3 requerimientos necesita migración Alembic.**

---

## 2. Requerimiento 1 — Nuevo trigger "Cuando un lead pase a HITL"

**Nuevo `trigger_type`: `lead_entered_hitl`** (sin params).

### 2.1 Punto(s) de disparo — la parte delicada
`control_status = MANUAL` se escribe en muchos sitios:
- `lead_service.py:248` (fase `requires_hitl`, ya tiene flag `hitl_flipped`) y `lead_service.py:608/646` (update explícito de control).
- `api/v1/lead_control.py:81` (toma manual).
- `hitl_service.py:265/349/541`, `marketplace_leads.py:171`.
- Handoffs de agentes IA / webhooks (bulk `.values(...)`): `agents/intake/agent.py:780/808`, `contact_repository.py:338`, `lead_reactivation_service.py:152`, `api/v1/public.py:1486`, `api/v1/leads.py:360/409/668/950/5528`, `expediente_tools.py:682`.

Para cumplir "sin importar la causa" sin parchear 15 sitios, **enfoque recomendado: helper centralizado**:

- Crear `app/services/hitl_trigger.py` (o función en `lead_service`) `fire_lead_entered_hitl(tenant_id, lead_id, actor_id, reason)` que dispara `workflow_rule_service.evaluate_trigger("lead_entered_hitl", ...)` fire-and-forget, con **guard de idempotencia**: solo dispara si la transición fue `AUTOMATED → MANUAL` (no re-dispara si ya estaba MANUAL).
- Rutas **por objeto** (fácil, alta prioridad): `lead_service.py` (reusar `hitl_flipped`, L241/251), `lead_service.py:608/646`, `lead_control.py:81`, `expediente_tools.py:682`, `marketplace_leads.py:171`.
- Rutas **bulk `.values()`** (agentes/webhooks): antes del UPDATE ya se evalúa `if control_status != MANUAL`; envolver esos sitios para llamar al helper cuando efectivamente cambian a MANUAL. (Estos representan el handoff IA→humano, que también es "entrar a HITL".)
- Guard anti-loop: igual que los demás triggers, saltar cuando `source == "workflow"`.

> **Sub-decisión a confirmar en review:** cobertura total (los ~15 sitios, más trabajo/QA) vs. cobertura de los puntos "de negocio" (fase requires_hitl + toma manual + handoff IA principal). La HU pide "sin importar la causa" → el plan asume cobertura amplia vía helper. Se marcará claramente cada sitio tocado.

### 2.2 Catálogo y motor
- `_TRIGGER_LABELS` (`workflow_rule_repository.py`): añadir `"lead_entered_hitl": "Cuando un lead pase a HITL"`.
- `WORKFLOWS_MODULE_SPEC.md §2.4`: documentar el trigger (grupo Estado del lead, sin params).
- `_match_trigger_params`: sin params → ya pasa por defecto. Sin cambios.

### 2.3 Frontend
- `types/workflow.ts`: añadir `'lead_entered_hitl'` a `WorkflowTriggerType`.
- `trigger/TriggerEventSelector.vue` (`EVENTS_BY_GROUP`): añadir al grupo `leadState`.
- `trigger/TriggerParamsForm.vue`: sin params (no requiere UI extra).
- i18n `workflowsSettings.ts` (es/en): `triggerTypes.lead_entered_hitl` = "Cuando un lead pase a HITL" / "When a lead enters HITL".
- `useWorkflowSummary.ts`: verificar que el resumen legible cubra el nuevo trigger.

---

## 3. Requerimiento 2 — Vencimiento relativo a la visita (horas antes)

### 3.1 Shape de `due_date_config` (propuesto)
Añadir modo nuevo sin romper el existente:
```jsonc
{ "base": "visit_date", "hours_before": 24 }   // vencimiento = visita − 24h
```
- Se mantiene el modo actual (`trigger_date` + `offset_days`/`offset_hours`/`fixed_time`) intacto → compatibilidad.
- Presets sugeridos en UI: 1, 2, 12, 24, 48 h + valor personalizado (entero positivo).

### 3.2 Backend
- **Resolver la fecha de la visita**: en `_enrich_context` (`workflow_rule_service.py:483-510`) poblar `ctx.visit_datetime`:
  - Leer `lead.extra_data.get("calendar_event_id")`.
  - Consultar el evento vía `app/services/calendar_microservice.py` (cliente `calendar_service`) para obtener su `start`/fecha-hora. Best-effort (try/except, igual que el resto de `_enrich_context`).
  - Añadir campo `visit_datetime: Optional[datetime]` a `WorkflowExecutionContext` (`workflow_action_executor.py:46-67`).
- **`_resolve_due_date`** (`workflow_action_executor.py:925-952`):
  - Si `base == "visit_date"` y hay `hours_before`: `due = ctx.visit_datetime - timedelta(hours=hours_before)`.
  - **Fallback** si no hay visita resoluble: crear la tarea sin `scheduled_datetime` (o con `trigger_date`, a confirmar) + `logger.warning`. La tarea nunca debe fallar por falta de visita.
  - Validación: `hours_before` entero positivo.
- **Serie de tareas** (`_create_task_series`, `workflow_action_executor.py:398-475`): también aplica la HU. Cálculo actual es inline (L449-457) y no usa `_resolve_due_date`. Propuesta: permitir anclar la serie a la visita (primera tarea = visita − `hours_before`, siguientes espaciadas por `interval_days`). → **sub-diseño a confirmar** (ver §6).

### 3.3 Frontend
- `actions/DueDatePicker.vue`:
  - Añadir opción de base "Relativo a la visita" y, cuando esté activa, un selector "N horas antes" (presets 1/2/12/24/48 + custom).
  - Ocultar `fixed_time`/offset "después" en ese modo (mutuamente excluyente).
  - Mensajería UX si el trigger elegido no garantiza una visita (ver nota UX abajo).
- `composables/useWorkflowEditor.ts`: default configs coherentes; validación (`hours_before` > 0).
- `CreateTaskSeriesForm.vue`: exponer el modo "relativo a la visita" según §3.2 (dependiente de la sub-decisión).
- i18n `workflowsSettings.ts` (es/en): labels `dueDate.visitBase`, `dueDate.hoursBefore`, presets.
- `useWorkflowSummary.ts`: reflejar "vence 24h antes de la visita" en el resumen.

> **Nota UX (memoria "Frontend best UX/UI"):** el modo "horas antes de la visita" solo tiene sentido si el lead tendrá una visita. Mostrar hint/estado cuando el trigger no la garantice, y verificar visualmente en navegador antes de dar por listo.

---

## 4. Requerimiento 3 — Nuevos tipos de tarea

Backend ya soporta `negociacion` / `reagendamiento` / `confirmacion`. **Solo frontend.**

- Eliminar las 4 constantes `TASK_TYPES` hardcodeadas y consumir el catálogo central de `src/types/tasks.ts`:
  - Selección: `CREATABLE_TASK_TYPES` (seguimiento, reunion, documento, reagendamiento, confirmacion, negociacion, otro).
  - Etiquetas: `TASK_TYPE_LABELS` (incluye labels de los deprecated para render de configs viejas).
- Archivos a tocar: `trigger/TriggerParamsForm.vue`, `actions/forms/CreateTaskForm.vue`, `actions/forms/CreateTaskSeriesForm.vue`, `conditions/ConditionValueInput.vue`.
- **Compatibilidad:** workflows viejos con `llamada`/`correo` siguen válidos en backend; el frontend debe **mostrar** su label (vía `TASK_TYPE_LABELS`) aunque ya no sean seleccionables. Verificar que un config guardado con un tipo deprecated no rompa el selector.

---

## 5. Plan de pruebas

- **Backend (`pytest`)**
  - R1: al forzar `AUTOMATED→MANUAL` por fase `requires_hitl` y por toma manual, se dispara `lead_entered_hitl` una sola vez; no dispara si ya estaba MANUAL; no dispara en bucle (`source=workflow`).
  - R2: `_resolve_due_date` con `base=visit_date`/`hours_before` = visita − N h; fallback sin visita (no crashea); `_enrich_context` resuelve `visit_datetime` desde `calendar_event_id` (mock del cliente calendar).
  - R3: sin cambios backend; confirmar que `TaskType` acepta los 3 valores desde config de workflow (test de `_create_task`).
- **Frontend (`npm run type-check` + `npm test` + verificación visual en navegador)**
  - R1: nuevo trigger aparece en grupo Estado del lead, guarda/carga bien, resumen correcto.
  - R2: DueDatePicker modo "horas antes de la visita", presets, validación; resumen; serie de tareas.
  - R3: los 3 tipos nuevos disponibles en los 4 selectores; config vieja con `llamada`/`correo` renderiza su label.
- **E2E manual:** crear workflow (trigger HITL → crear tarea "Confirmación" con vencimiento 24h antes de la visita), disparar y verificar `scheduled_datetime`.

---

## 6. Riesgos y sub-decisiones abiertas (a confirmar en review, no bloquean el plan)

1. **Cobertura del trigger HITL** (§2.1): amplia (helper en ~15 sitios) vs. puntos de negocio. Plan asume amplia.
2. **Serie de tareas + "horas antes de la visita"** (§3.2/3.3): cómo se combina una visita única con una serie espaciada. Propuesta: primera tarea = visita − `hours_before`, resto por `interval_days`. Alternativa: aplicar el modo solo a "Crear tarea" y dejar la serie como está.
3. **Fallback de vencimiento sin visita**: tarea sin `scheduled_datetime` (propuesto) vs. `trigger_date`.
4. **Costo de resolver la visita**: `_enrich_context` haría una llamada HTTP a calendar-service por ejecución cuando el config use `visit_date`. Mitigación: resolver solo si alguna acción usa `base=visit_date`.

---

## 7. Archivos afectados (resumen)

**Backend**
- `app/services/workflow_rule_service.py` (`_enrich_context`, disparo HITL)
- `app/services/workflow_action_executor.py` (`WorkflowExecutionContext`, `_resolve_due_date`, `_create_task_series`)
- `app/db/repositories/workflow_rule_repository.py` (`_TRIGGER_LABELS`)
- `app/services/hitl_trigger.py` (nuevo helper) + sitios de `control_status=MANUAL` (§2.1)
- `app/services/lead_service.py`, `app/api/v1/lead_control.py`, y demás sitios de handoff
- `WORKFLOWS_MODULE_SPEC.md` (doc)
- Tests en `tests/`

**Frontend**
- `src/types/workflow.ts`
- `src/components/workflows/trigger/{TriggerEventSelector,TriggerParamsForm}.vue`
- `src/components/workflows/actions/DueDatePicker.vue`
- `src/components/workflows/actions/forms/{CreateTaskForm,CreateTaskSeriesForm}.vue`
- `src/components/workflows/conditions/ConditionValueInput.vue`
- `src/composables/{useWorkflowEditor,useWorkflowSummary}.ts`
- `src/locales/es/workflowsSettings.ts`, `src/locales/en/workflowsSettings.ts`

**Sin migración Alembic.**

---

## 8. Al terminar
- Crear bitácora en `Projects/auto-doc/` (plantilla estándar).
- No hacer commit sin OK explícito; sin atribución IA; sin push/PR (los hace el usuario).
