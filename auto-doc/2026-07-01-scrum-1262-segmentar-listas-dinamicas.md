# SCRUM-1262 — Segmentar listas dinámicas por proyecto, motivo de descarte y palabras clave

## Fecha
2026-07-01

## Tarea solicitada (en concreto)
Ampliar el constructor de criterios de las listas dinámicas (SCRUM-1226) con tres campos
nuevos de segmentación: **proyecto**, **motivo de descarte** y **palabras clave**.

## Rama
`feature/SCRUM-1262` (commit `081866df`)

## Módulo(s) afectado(s)
`app-saas-service` — lead segmentation
- `app/services/lead_segment_resolver.py` — nuevos builders de campo (+70 líneas).
- `app/schemas/lead_segment.py` — nuevos campos/operadores en el schema (+25).
- `app/api/v1/distribution_lists.py` — `filter-options` expone los nuevos catálogos (+30).
- `tests/unit/listas_dinamicas/test_segment_resolver.py` + `test_segment_schema.py` — cobertura de los nuevos campos.

## Resumen de lo que se hizo
Extensión directa de la feature de listas dinámicas: se agregaron tres campos al
`FIELD_REGISTRY` del `LeadSegmentResolver` (proyecto, motivo de descarte, palabras
clave), con sus operadores permitidos, su validación en el schema `SegmentGroup`, y su
exposición en el endpoint `filter-options` para que el builder del front los pueble.
Se mantuvo el patrón de seguridad (parámetros enlazados, allow-list de operadores) y la
capa de supresión intacta.

## Decisiones tomadas
- Reutilizar el `FIELD_REGISTRY` existente en lugar de casos especiales: cada campo
  nuevo declara su join y operadores, manteniendo el resolver extensible.
- `filter-options` arma los catálogos desde datos reales del tenant (no listas fijas),
  consistente con la decisión de SCRUM-1226.

## Preguntas y respuestas
No hay registro de preguntas específicas para esta tarea.

## ¿Se tocó trabajo de otros desarrolladores?
No. Solo se extendió código propio de SCRUM-1226.

## Bugs de otros encontrados / resueltos
Ninguno.

## Notas / pendientes
- Verificar que los `code` de motivo de descarte y las fuentes de palabras clave existan
  por tenant antes de ofrecerlos en el builder.
- Continúa de [2026-06-26 — SCRUM-1226](./2026-06-26-scrum-1226-listas-dinamicas.md).
