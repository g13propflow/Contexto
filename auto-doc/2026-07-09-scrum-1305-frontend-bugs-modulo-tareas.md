# Bugs de UI del módulo Tareas del commit "primeros cambios" (SCRUM-1305, frontend)

## Fecha
2026-07-09 (fixes desarrollados 2026-07-08)

## Contexto
Durante el fix de SCRUM-1305 (crear tareas con tipos reagendamiento/confirmacion/negociacion) se
detectó que el commit `27128b3d` ("Agregando primeros cambios", 2026-06-19), que reescribió el
módulo de Tareas del frontend, había dejado varios bugs. Tras revisión adversarial (3 agentes por
archivo) + verificación manual, se confirmaron 3 bugs vigentes atribuibles a ese commit y se
arreglaron. (Descartados como intencionales: quitar EN_PROGRESO del flujo y el no-op de drag
entre leads — tienen comentarios/diseño explícito.)

## Rama y commits
Repo **`app-saas-frontend`**, rama **`fixbug/SCRUM-1305`** (misma nomenclatura que el fix backend;
creada desde `main`). Sin push. Tres commits separados (uno por fix):

- `764df250` — fix(tasks): eliminar selector de estado muerto en TaskCard
- `171c3d35` — fix(tasks): "Ver las N anteriores" del Kanban abre la lista filtrada
- `6f2c7e46` — fix(tasks): refrescar contadores del asesor al cambiar estado en el Kanban

## Bugs corregidos

### #1 — Selector de estado muerto en `TaskCard.vue` (dead code)
- **Diagnóstico:** el `<select>` de estado quedó tras `v-else-if="showStatusSelector"` (default
  `false`) y ningún caller lo activa (el Kanban se reescribió y ya no usa `TaskCard`). El select,
  `handleStatusChange` y el modal de cancelación interno quedaron inalcanzables.
- **Fix:** se eliminó ese código muerto (selector, handler, modal de cancelación, prop
  `showStatusSelector`, imports/estado asociados: `tasksService`, `useAlert`,
  `CANCELLATION_REASONS`, `isSavingStatus`). El badge de estado se muestra siempre;
  Completar/Cancelar sigue vía botón Editar → modal.
- **Nota clave:** es un cambio **inocuo en runtime** — el badge ya era la única rama que
  renderizaba (spinner y select siempre estaban en false), así que el comportamiento visible no
  cambia. Solo se elimina peso muerto.

### #2 — Botón "Ver las N anteriores" del Kanban no navegaba (`TasksKanbanView.vue` + `TasksView.vue`)
- **Diagnóstico:** `goToList` hacía `router.push` a la misma ruta (`/dashboard/tasks`) con
  `?status=`, pero `TasksView` nunca lee `query.status` ni observa `route.query` → el botón solo
  cambiaba la URL, sin filtrar ni cambiar de vista.
- **Fix:** el Kanban emite `show-status`; `TasksView.handleShowStatus` cambia a la vista lista
  (`viewMode='list'`) y aplica `filters.status` (el watch de `filters` recarga). Se eliminó
  `useRouter`, que solo servía a esa navegación muerta.

### #3 — Contadores del asesor (vencidas/hoy) quedaban stale en el Kanban
- **Diagnóstico:** los badges `group.summary.total_vencidas/total_hoy` (header del asesor) vienen
  del servidor y no se recalculan; al completar/cancelar/reabrir/arrastrar una tarea, el Kanban
  mutaba el estado y llamaba al backend pero no notificaba al padre → contadores obsoletos hasta
  un refetch no relacionado.
- **Fix:** el Kanban emite `refresh` tras cada cambio de estado exitoso (drag, quick, cancelar);
  `TasksView` recarga (`@refresh="loadTasks"`).

## Módulos afectados (frontend)
- `src/components/Tasks/TaskCard.vue` — limpieza de dead-code (#1).
- `src/components/Tasks/TasksKanbanView.vue` — emits `show-status`/`refresh`, `viewAllOfStatus` (#2, #3).
- `src/views/TasksView.vue` — `handleShowStatus` + binding `@show-status`/`@refresh` (#2, #3).

## Verificación
- **type-check** (`NODE_OPTIONS=--max-old-space-size=8192 npm run type-check`; el default de Node
  hace OOM en este repo): sin errores nuevos en los archivos tocados. Los 2 errores en
  `TasksKanbanView` (`TASK_TYPE_COLORS[task.type]` con `any`) son **preexistentes**.
- **Code review final** del diff de ambas ramas: no se tocó nada fuera de alcance; #1 es
  provablemente inocuo; #2/#3 son wiring aditivo correcto.
- ⚠️ **Pendiente:** verificación **en navegador** (no se levantó dev server). Ver instrucciones de
  prueba entregadas al usuario (crear tareas de los 3 tipos; cards móviles; botón "Ver las N
  anteriores"; refresco de contadores al cambiar estado).

## Estado final (2026-07-09) — listo para PR

Commits por delante de `main` (baseline confirmado con `git rev-list --count`):
- **app-saas-service** `fixbug/SCRUM-1305`: **1 commit** (`2b8d608d` — migración + test).
- **app-saas-frontend** `fixbug/SCRUM-1305`: **3 commits** (`764df250` #1, `171c3d35` #2,
  `6f2c7e46` #3).
- Total: **4 commits**.

Textos de PR preparados (base `main` ← `fixbug/SCRUM-1305` en cada repo):
- Backend: `fix(SCRUM-1305): permitir crear tareas de tipo reagendamiento/confirmación/negociación`
  (incluye notas de deploy: verificar `alembic current`, drift, ventana de bajo tráfico).
- Frontend: `fix(SCRUM-1305): bugs de UI del módulo Tareas (selector muerto, "Ver anteriores", contadores)`.

## Pendientes del usuario
- Probar en navegador los 4 escenarios.
- **Push** + crear los 2 PRs de la rama `fixbug/SCRUM-1305` (backend y frontend).
- Aplicar la migración del backend en staging/prod.

## Bugs NO corregidos (fuera de alcance / no eran de este commit)
- Backend: al cancelar no se exige `cancellation_reason` server-side (el front sí lo obliga) — Baja.
- Kanban quick-complete no setea `completed_at` (fecha roja obsoleta) — introducido después
  (SCRUM-1265), no por `27128b3d`.
- `TasksView.vue:409` deep-link `?task_id=` borra filtros guardados en localStorage — preexistente.

Relacionado: `2026-07-08-scrum-1305-tipos-tarea-reagendamiento-confirmacion-negociacion.md` (fix backend).
