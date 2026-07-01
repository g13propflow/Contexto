# Feature 1198 — Notificar al asesor de nueva visita por canales configurables

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-24

## Tarea solicitada (en concreto)
Notificar al asesor cuando se agenda una nueva visita, a través de **canales
configurables** por asesor.

## Rama
`feature/1198` (commit `ffff03d6`)

## Módulo(s) afectado(s)
`app-saas-service` — advisors / notifications / tours
- `app/services/advisor_notification_service.py` (+189/-… reescritura parcial)
- `app/api/v1/tour_scheduled.py`, `app/api/v1/advisors.py`
- `app/db/models.py`, `app/schemas/advisor.py`, `app/schemas/lead.py`
- `app/agents/tools/qualification_tools.py`, `app/middleware/authentication.py`
- Migración `...02nl03_add_notification_channels_to_advisors.py`

## Resumen de lo que se hizo
Se añadieron canales de notificación configurables al modelo de asesor (migración +
modelo + schemas) y se reescribió parte del `advisor_notification_service` para respetar
esos canales al notificar una visita agendada. Se conectó desde el flujo de tour
agendado y desde las tools de calificación del agente.

## Decisiones tomadas
Canales configurables a nivel de asesor (persistidos), en vez de un canal fijo global.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se tocaron áreas compartidas: `models.py`, middleware de autenticación, tools del agente
de calificación y el flujo de tour agendado. Cambios orientados a la feature.

## Bugs de otros encontrados / resueltos
Ninguno registrado explícitamente.

## Notas / pendientes
Ninguna.
