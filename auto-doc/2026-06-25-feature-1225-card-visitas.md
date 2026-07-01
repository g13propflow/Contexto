# Feature 1225 — Card de métricas de visitas (agendadas vs. completadas)

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-25

## Tarea solicitada (en concreto)
Una card que mida la cantidad y el % de visitas **agendadas** (canceladas + no atendidas
+ atendidas) y cuántas de esas se **completaron** (atendidas), dentro del rango de fechas
y filtros seleccionados.

## Rama
`feature/1225` (commit `6e508cbb`)

## Módulo(s) afectado(s)
`app-saas-service` — marketing dashboard
- `app/db/repositories/marketing_dashboard_repository.py`
- `app/schemas/marketing_dashboard.py`

## Resumen de lo que se hizo
Se agregó el cálculo (repositorio) y el schema de respuesta para la nueva card del
dashboard de marketing: total de visitas agendadas y cuántas se completaron, respetando
el rango de fechas y filtros del dashboard.

## Decisiones tomadas
Cálculo en el repositorio del marketing dashboard, reutilizando su patrón de filtros por
fecha (ver memoria `analisis-card-visitas`).

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se extendió el repositorio del marketing dashboard; adición, sin alterar cálculos
existentes de terceros.

## Bugs de otros encontrados / resueltos
Ninguno.

## Notas / pendientes
- Contraparte de frontend en `app-saas-frontend` (no en este commit).
