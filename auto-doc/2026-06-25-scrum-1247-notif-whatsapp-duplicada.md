# SCRUM-1247 — Evitar notificación duplicada de WhatsApp sin responder (canal HITL)

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-25

## Tarea solicitada (en concreto)
Corregir la notificación **duplicada** de "WhatsApp sin responder" que se emitía en el
canal HITL.

## Rama
`bugfix/SCRUM-1247` (commit `a2b11676`)

## Módulo(s) afectado(s)
`app-saas-service` — advisor whatsapp / notifications
- `app/services/advisor_whatsapp_sla_service.py`
- `app/services/notification_service.py`
- `tests/unit/advisor_whatsapp/test_sla_sweep.py`

## Resumen de lo que se hizo
Bugfix de idempotencia: se evitó que el SLA sweep de WhatsApp de asesores emitiera una
notificación duplicada de conversación sin responder en el canal HITL. Cubierto con test
en `test_sla_sweep.py`.

## Decisiones tomadas
Aplicar idempotencia/guarda en el servicio de SLA + notificación en vez de deduplicar
aguas abajo.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se tocó el `notification_service` compartido; cambio acotado a la guarda de duplicados.

## Bugs de otros encontrados / resueltos
- Notificación duplicada de WhatsApp sin responder (HITL) — resuelto.

## Notas / pendientes
Ninguna.
