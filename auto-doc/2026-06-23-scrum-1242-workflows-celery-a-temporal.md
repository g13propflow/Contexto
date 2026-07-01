# SCRUM-1242 — Migrar acciones diferidas de workflows de Celery a Temporal (+ fix webhook)

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-23

## Tarea solicitada (en concreto)
Migrar las **acciones diferidas** del motor de workflows de Celery a **Temporal**, y
corregir el disparo del webhook `calcom/visit-completed`.

## Rama
`feature/SCRUM-1242` (commits `684eeeb9`, `35554c33`, `30755145`)

## Módulo(s) afectado(s)
`app-saas-service` — workflows / temporal / webhooks
- `app/services/workflow_delayed_executor.py` (renombrado desde el ejecutor Celery)
- `app/services/workflow_rule_service.py`
- `app/temporal/workflows_workflow_delayed.py` + `activities_workflow_delayed.py` + `worker.py`
- `app/celery_app.py` (−41: se retiró la tarea Celery)
- `app/api/v1/webhooks.py`

## Resumen de lo que se hizo
Se migró la ejecución de acciones diferidas de workflow desde Celery a un workflow de
Temporal (`DelayedWorkflowActionWorkflow`), retirando la tarea Celery correspondiente.
Se corrigió el uso de `asyncio.sleep` dentro del workflow diferido, y se repuntó el
webhook `calcom/visit-completed` a `start_negotiation_workflow`.

## Decisiones tomadas
- Usar Temporal (flujos durables) en lugar de Celery para acciones diferidas de workflow.
- `asyncio.sleep` para el delay dentro del workflow de Temporal.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se tocó `celery_app.py` (infraestructura compartida de tasks) para retirar la tarea
migrada, y `webhooks.py`. Cambios acotados a la migración.

## Bugs de otros encontrados / resueltos
- Webhook `calcom/visit-completed` apuntaba al flujo equivocado — repuntado a
  `start_negotiation_workflow`.

## Notas / pendientes
Ninguna.
