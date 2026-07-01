# SCRUM-1214 — Contenedor de amenidades en startup + subida sin bloquear el event loop

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-26

## Tarea solicitada (en concreto)
Asegurar que el contenedor (Azure Blob) de amenidades exista al arrancar la app, y
corregir la subida de imágenes de amenidades para que **no bloquee el event loop**.

## Rama
`fix/SCRUM-1214` (commits `1a4ae040`, `1b8015d5`)

## Módulo(s) afectado(s)
`app-saas-service` — amenities
- `app/api/v1/amenities.py`
- `app/main.py` — asegura el contenedor en el startup.

## Resumen de lo que se hizo
Dos cambios: (1) en el startup se garantiza la existencia del contenedor de amenidades;
(2) se corrigió la subida de imágenes para no bloquear el event loop (operación de I/O
que corría síncrona dentro del loop asíncrono).

## Decisiones tomadas
Asegurar el contenedor en el arranque en vez de al primer uso (evita fallos en la
primera subida).

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Módulo de amenidades; cambios acotados. Sin refactor de terceros.

## Bugs de otros encontrados / resueltos
- Bug de bloqueo del event loop en la subida de imágenes de amenidades (comportamiento
  preexistente) — resuelto.

## Notas / pendientes
Ninguna.
