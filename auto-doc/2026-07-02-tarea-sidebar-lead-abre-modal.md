# Clic en tarea del sidebar del lead abre el modal (sin navegar a Tareas)

## Fecha
2026-07-02

## Tarea solicitada (en concreto)
Al hacer clic sobre una tarea en el sidebar del lead, **no** debe navegar al módulo
de Tareas: debe abrir el **mismo modal de detalle** del módulo de Tareas cargado con
esa tarea, permaneciendo en la vista del lead. El modal debe conservar toda la
funcionalidad (realizar llamada, abrir WhatsApp, completar, actualizar, cancelar),
validaciones, permisos, estados y diseño idénticos. Los cambios hechos desde el
modal deben reflejarse inmediatamente en el sidebar sin recargar.

## Rama
`feature/SCRUM-1273` (creada desde `main`). Commit `14324aff` con un único archivo:
`src/components/LeadContextSidebar.vue`. Push pendiente por el usuario.

## Módulo(s) afectado(s)
`app-saas-frontend` — sidebar de contexto del lead
- `src/components/LeadContextSidebar.vue` (único archivo)

---

## Resumen de lo que se hizo
- **Click del item de tarea:** el handler pasó de `navigateToLeadTasks(leadId, taskId)`
  (que hacía `router.push({ name: 'tasks', ... })`) a `openTaskDetail(task)`, que abre
  el modal sin salir del lead. El footer "Ver todas las tareas →" **se conserva**
  navegando al módulo (comportamiento legítimo distinto).
- **Reutilización del modal existente:** se reutiliza el mismo componente
  `TaskForm.vue` del módulo de Tareas (que ya estaba importado en el sidebar para
  *crear*). No se creó ningún componente ni lógica de negocio nuevos.
- **Carga del Task completo:** el sidebar solo maneja `LeadTaskItem` (ligero, sin
  `lead.phone`). `openTaskDetail` hace `tasksService.getTask(task.id)` para obtener el
  `Task` completo antes de abrir —mismo patrón que `TasksView.handleEditTask`— de modo
  que las CTAs de WhatsApp/llamada (que dependen de `task.lead.phone`) funcionen.
- **Modal de detalle:** nueva instancia `<TaskForm :task="selectedTaskDetail">` dentro
  de `<Teleport to="body">` (mismo patrón que el modal de creación ya existente en el
  sidebar, lo que garantiza el z-index sobre el drawer).
- **Reactividad del sidebar:** `@saved` cierra el modal y refetchea `loadLeadTasks`;
  `@task-updated` (completar/cancelar) refetchea el sidebar; así los cambios se ven
  al instante sin recargar la página.
- **Follow-up:** `@follow-up` abre una nueva instancia de `TaskForm` prellenada con el
  lead/asesor (paridad con la "tarea de seguimiento" del módulo de Tareas).
- **Cierre por cambio de lead:** el `watch(selectedLeadId)` ahora cierra el modal de
  detalle y el de follow-up al cambiar de lead, para no mostrar una tarea de otro lead.

## Decisiones tomadas
- **Reutilizar `TaskForm.vue` tal cual** en vez de crear un `TaskDetailModal`: el
  "modal de detalle" del módulo de Tareas ES `TaskForm` en modo edición
  (`isEditMode = !!props.task`). Reutilizarlo garantiza paridad funcional total
  (validaciones, permisos, estados, acciones, diseño) sin duplicar lógica.
- **Refetch como única fuente de verdad** tras editar/completar/cancelar (los tres
  handlers `saved`/`task-updated`/`follow-up` solo llaman `loadLeadTasks`): evita
  desincronizar `status`, `urgency_status` y los contadores de vencidas/hoy. Se descartó
  un parche optimista local por redundante (el refetch reemplaza el arreglo completo).

## Nota de entorno (no forma parte del cambio de la tarea)
Para poder probar en local hubo que reconciliar la BD Azure compartida: había ~25
migraciones Alembic pendientes y la imagen del contenedor tenía un `alembic/versions`
viejo. Se sincronizaron las migraciones al contenedor y se corrió `alembic upgrade head`
(BD quedó en `ec08_merge_mdlprc_sap_r5`). Los andamios temporales en migraciones/`env.py`
se revirtieron; el working tree quedó limpio. Esto es infraestructura, no parte del diff
de la tarea.
- **Se conservó `navigateToLeadTasks`** para el enlace "Ver todas las tareas →": ese sí
  debe navegar al módulo completo.

## Preguntas y respuestas
No se hicieron preguntas. Se presentó primero un análisis técnico (flujo actual,
propuesto, componentes, riesgos, casos borde, estrategia de reutilización) y el usuario
lo aprobó con "procede".

---

## ¿Se tocó trabajo de otros desarrolladores?
No. Todo el cambio está contenido en `LeadContextSidebar.vue`. `TaskForm.vue`,
`TasksView.vue`, `tasks.service.ts` y los tipos no se modificaron.

## Bugs de otros encontrados / resueltos
Ninguno relacionado. El `type-check` global reporta errores preexistentes en otros
archivos (bank, Emails, fha, models, workflows, varias views); ni `LeadContextSidebar.vue`
ni `TaskForm.vue` aparecen en la lista → mis cambios no introducen errores de tipo.

---

## Pruebas realizadas
- `npm run type-check` (`vue-tsc --build`): sin errores nuevos en `LeadContextSidebar.vue`.
  Los errores mostrados son preexistentes en archivos ajenos.
- Revisión de contrato de eventos de `TaskForm`: `saved` (guardar edición) → cierra +
  refetch; `task-updated` (completar/cancelar) → refetch; `follow-up` → abre modal de
  seguimiento. Todos cableados en el sidebar.
- **Verificación en navegador (usuario):** clic en tarea del sidebar abre el modal sin
  navegar (confirmado en logs: `GET /tasks/1716`, `/tasks/1717`).
- **Completar end-to-end verificado en BD:** tarea 1716 quedó `status = COMPLETADA`,
  `completed_at = 2026-07-02 16:31:59` → la acción del modal **persiste** correctamente.
- Aclaración: "no aparecía completada" en el módulo de Tareas resultó ser
  filtro/columna Kanban de ese módulo, ajeno a este cambio (la tarea sí estaba completada).
- Revisión final de bugs: sin bugs reales; los posibles hallazgos fueron falsos positivos
  (estado optimista muerto preexistente, exclusión de modales, doble-refetch). Único
  ajuste de estilo aplicado: se quitó un parche optimista redundante en `handleTaskDetailUpdated`.

## Notas / pendientes
- Entregado en `feature/SCRUM-1273`, commit `14324aff` (solo `LeadContextSidebar.vue`).
- **Único pendiente: `git push` (lo hace el usuario).**
- QA opcional para cero dudas: verificar visualmente cancelar/actualizar/WhatsApp/llamar
  (corren sobre el mismo `TaskForm`, paridad por construcción).
