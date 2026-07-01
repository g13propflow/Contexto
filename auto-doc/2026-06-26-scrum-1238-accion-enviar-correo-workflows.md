# SCRUM-1238 — Acción "enviar correo" en el motor de workflows

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-26

## Tarea solicitada (en concreto)
Agregar la acción **"enviar correo"** al motor de reglas/workflows, con dos modos de
destinatario: el lead del contexto del trigger, o una lista de distribución (resuelta al
disparar).

## Rama
`feature/SCRUM-1238` (commit `40105464`)

## Módulo(s) afectado(s)
`app-saas-service` — workflows / email
- `app/services/workflow_action_executor.py` — handler `_send_email` (+144).
- `app/schemas/workflow_rule.py` — schema de la acción.
- `app/db/models_email_campaigns.py`
- `tests/unit/workflows/test_send_email_action.py` + `test_workflow_action_schema_send_email.py`.

## Resumen de lo que se hizo
Se implementó el handler de la acción `send_email` en el executor de acciones de
workflow, con soporte para destinatario `lead` o `distribution_list`. Cobertura con
tests unitarios del handler y del schema de la acción. Este handler es el que después
SCRUM-1226 amplió para resolver listas dinámicas en vivo (`live=True`).

## Decisiones tomadas
- La acción cuelga de un trigger de estado, no de un timer secuencial (el `delay` se
  rechaza a nivel de schema); por eso el handler corre inline.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se extendió el motor de workflows (módulo iniciado en la fase de 06-21). Código propio
de la línea de trabajo de workflows.

## Bugs de otros encontrados / resueltos
Ninguno registrado.

## Notas / pendientes
- Base sobre la que SCRUM-1226 montó la resolución en vivo de listas dinámicas.
