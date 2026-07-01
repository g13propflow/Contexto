# SCRUM-1265 — Fixes de tareas (timezone, filtro de estado, autorización)

> Bitácora reconstruida desde git (`git log`/`git show`). Los campos de decisiones y
> preguntas se infieren del commit y pueden estar incompletos.

## Fecha
2026-06-30

## Tarea solicitada (en concreto)
Corregir tres defectos del módulo de tareas: manejo de **timezone**, el **filtro por
estado** de tareas, y la **autorización** en los endpoints/repositorios de tareas.

## Rama
`feature/SCRUM-1265` (commit `73377808`)

## Módulo(s) afectado(s)
`app-saas-service` — tasks
- `app/api/v1/tasks.py`
- `app/db/repositories/task_repository.py`
- `app/db/repositories/task_note_repository.py`

## Resumen de lo que se hizo
Bugfix acotado (24 inserciones / 12 borrados) sobre el módulo de tareas: ajustes de
timezone, corrección del filtro de estado y refuerzo de autorización en los repositorios
de tareas y notas de tarea.

## Decisiones tomadas
Sin registro explícito; cambios de tipo corrección directa.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Se modificó el módulo de tareas, que es un módulo compartido con otros tickets del área
de tareas. Cambios acotados a fixes, sin refactor de terceros.

## Bugs de otros encontrados / resueltos
Los tres fixes (timezone, filtro de estado, autorización) son correcciones a
comportamiento preexistente del módulo de tareas.

## Notas / pendientes
- Relacionado con el análisis en `analisis-modulo-tareas.md`.
