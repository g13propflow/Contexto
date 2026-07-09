# Confirmación "¿Quieres crear otra tarea?" al completar una tarea

## Fecha
2026-07-06

## Tarea solicitada (en concreto)
Al marcar una tarea como **completada** desde cualquiera de los tres puntos del
módulo de Tareas (Lista, Kanban y modal de detalle), reemplazar el mensaje de
confirmación actual ("Perfecto"/"Entendido"/toast de estado) por un **modal de
confirmación** que pregunte **"¿Quieres crear otra tarea?"**:
- **Sí** → abre el modal de creación de tarea prellenado con el **lead** y el
  **asesor asignado** de la tarea recién completada.
- **No** → cierra el flujo sin abrir el formulario.

En el modal de detalle, además, debe **cerrarse el detalle** antes de mostrar la
confirmación (Escenario 2 de la HU). El flujo debe centralizarse para no duplicar
lógica entre las tres vistas.

## Rama
`main` (pendiente de commit por el usuario)

## Módulo(s) afectado(s)
`app-saas-frontend` — módulo de Tareas
- `src/stores/taskFollowUpPrompt.ts` (**nuevo**) — store del flujo centralizado
- `src/layouts/DashboardLayout.vue` — montaje global del modal de confirmación + formulario
- `src/components/Tasks/TaskForm.vue` — completar desde el detalle → store; se quitó el prompt inline
- `src/components/Tasks/TasksListView.vue` — completar desde la lista → store
- `src/components/Tasks/TasksKanbanView.vue` — completar (botón + drag&drop) → store
- `src/views/TasksView.vue` — limpieza del follow-up viejo + refresco por `createdTick`
- `src/components/LeadContextSidebar.vue` — limpieza del follow-up viejo + refresco por `createdTick`

---

## Resumen de lo que se hizo

### Store centralizado (`taskFollowUpPrompt.ts`)
Flujo de **dos pasos** con Pinia:
1. `promptAfterComplete(task)` — hereda `lead_id`/`lead_name`/`advisor_id` de la
   tarea completada y abre el modal de confirmación (`confirmOpen`).
2. `accept()` ("Sí") — cierra la confirmación y abre el formulario (`formOpen`).
3. `reset()` ("No"/cierre/backdrop) — descarta todo.
4. `notifyCreated()` — incrementa `createdTick` (señal para que las vistas
   refresquen sus tareas) y limpia el estado.

### Montaje global (una sola vez, en `DashboardLayout`)
- `AlertModal type="confirm"` con título "Tarea completada" y mensaje
  **"¿Quieres crear otra tarea?"** (botones "Sí, crear tarea" / "No, gracias").
- `TaskForm` de creación prellenado con `initial-lead-id`/`initial-lead-name`/
  `initial-advisor-id`, `title-override="Nueva tarea"`. Al guardar → `notifyCreated`.

Se reutiliza el mismo patrón que el follow-up global existente por cambio de fase
del lead (`followUpPrompt` store), pero como flujo independiente y de dos pasos.

### Puntos de completado (todos llaman al store)
- **Lista** (`TasksListView.handleStatusChange`): al pasar a `COMPLETADA` ya **no**
  muestra el toast "Estado actualizado"; llama a `promptAfterComplete(task)`. El
  resto de cambios de estado (p. ej. Reabrir) conservan su toast.
- **Kanban** (`TasksKanbanView`): tanto el botón "Completar" (`handleQuickStatus`)
  como el **drag&drop** a la columna Completada (`handleDragChange`) llaman al store.
- **Detalle** (`TaskForm.toggleComplete`): al completar, `emit('task-updated')` →
  `emit('close')` (cierra el detalle) → `promptAfterComplete(props.task)`.

### Limpieza (evitar divergencia / doble flujo)
- `TaskForm`: se eliminó el **prompt verde inline** ("¿Crear tarea de seguimiento?")
  y el emit `follow-up`; ahora todo pasa por el store.
- `TasksView`: se borró el segundo `TaskForm` de follow-up y sus handlers
  (`handleFollowUp`, `showFollowUpModal`, etc.) y el import ya no usado de `useAuthStore`.
- `LeadContextSidebar`: se borró su `TaskForm` de follow-up y handlers
  (`handleTaskFollowUp`, `showTaskFollowUpModal`, etc.).
- Ambas vistas (`TasksView` y `LeadContextSidebar`) ahora observan
  `taskFollowUpStore.createdTick` para refrescar la lista de tareas cuando se crea
  una tarea de seguimiento desde el formulario global.

---

## Decisiones tomadas
- **Store global + montaje en `DashboardLayout`** (en vez de local por vista) porque
  el modal de detalle (`TaskForm`) es compartido por el módulo de Tareas y por el
  sidebar del lead; así el comportamiento queda idéntico "en cualquiera de los
  puntos" sin duplicar el modal ni la lógica.
- **Solo se heredan lead + asesor**, tal como pedía la HU y como ya hacía el
  follow-up manual previo (`initial-lead-id` + `initial-advisor-id`). No se fuerza
  tipo ni prioridad: quedan con los defaults del formulario, igual que al crear una
  tarea manual para un lead existente.
- **Se pasa el objeto `task` local** (fila / card / `props.task`) a
  `promptAfterComplete`, no la respuesta del PATCH, porque el objeto local conserva
  el `lead` completo (nombre) para prellenar mejor; `lead_id`/`advisor_id` no cambian
  al completar.
- **Refresco por señal (`createdTick`)** en vez de acoplar el formulario global a
  cada vista: las vistas solo observan un contador y recargan.

---

## Verificación
- `npm run type-check`: sin errores nuevos atribuibles al cambio. Los errores que
  aparecen son **preexistentes** y en archivos no tocados (NotificationBell,
  ListingMap, WorkflowEditor, etc.); los dos de `TasksKanbanView.vue:385` son de una
  expresión de plantilla no modificada (`TASK_TYPE_COLORS[task.type]`) cuyo número de
  línea solo se corrió por las líneas agregadas al `<script>`.
- **Pendiente:** verificación visual en navegador (hay dev server en `localhost:5173`)
  de los tres escenarios: completar desde Lista, Kanban (botón + arrastre) y detalle.

## Pendientes / seguimiento
- Commit y push (los hace el usuario).
- Confirmar visualmente el flujo en las tres vistas antes de dar por cerrada la HU.
