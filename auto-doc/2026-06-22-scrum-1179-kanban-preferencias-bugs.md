# SCRUM-1179 — Preferencias de usuario (orden de columnas kanban) + bugfixes

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-22

## Tarea solicitada (en concreto)
Permitir mover las columnas del kanban y **guardar el estado** (preferencia por usuario);
además arreglar bugs varios y cerrar cambios del módulo nuevo de workflows.

## Rama
`feature/SCRUM-1179` (commits `68823a53`, `4694281a`, `22be7012`, `2788ea8c`)

## Módulo(s) afectado(s)
`app-saas-service` — user preferences / leads / workflows
- `app/api/v1/user_preferences.py` (**nuevo**) + migración `...add_user_preferences.py`
- `app/db/models_auth.py`, `app/main.py`
- `app/api/v1/leads.py`, `app/services/lead_service.py` (bugfixes)
- `app/api/v1/workflow_rules.py`, `app/services/workflow_action_executor.py`,
  `app/services/workflow_rule_service.py`, `app/tasks/workflow_tasks.py`,
  `app/temporal/activities_workflow_inactivity.py` (cierre del módulo de workflows)

## Resumen de lo que se hizo
Se agregó un módulo de **preferencias de usuario** (tabla + endpoints) para persistir el
orden de columnas del kanban. En paralelo se resolvieron bugs en leads/lead_service y se
cerraron los últimos cambios del nuevo módulo de workflows (fase iniciada el 06-21).

## Decisiones tomadas
Persistir las preferencias del kanban como preferencia de usuario en su propia tabla.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se tocaron `leads.py`/`lead_service.py` (módulo central compartido) para bugfixes y el
módulo de workflows en construcción.

## Bugs de otros encontrados / resueltos
Bugs varios en leads resueltos (commit "Arreglando bugs" / "Resolviendo fixs"); detalle
específico no documentado en el mensaje.

## Notas / pendientes
Ninguna.
