# Prellenado automático del asesor al crear una tarea (SCRUM-1311)

## Fecha
2026-07-06

## Tarea solicitada (en concreto)
Al crear una **nueva tarea**, el campo **Asesor asignado** debe prellenarse
automáticamente con el asesor del **usuario autenticado** cuando este sea un
asesor, para reducir pasos manuales. Aplica a los dos puntos de entrada:
- Modal de creación de tareas (módulo de Tareas).
- Sidebar del lead.

Escenario 2: si el usuario **no** es asesor, el formulario mantiene el
comportamiento actual (campo vacío), sin cambios.

## Rama
`feature/SCRUM-1311` (creada desde `main`). Commit `c677f7fb`. Push/PR pendientes
del usuario.

## Módulo(s) afectado(s)
`app-saas-frontend` — módulo de Tareas
- `src/components/Tasks/TaskForm.vue` — único archivo modificado (5 líneas).

---

## Resumen de lo que se hizo

La infraestructura de prellenado **ya existía**: `TaskForm.vue` tiene la prop
`initialAdvisorId` que en modo creación prellena el asesor, y `loadSelectData()`
resuelve el nombre a mostrar tras cargar la lista de asesores. El modal de
"tarea de seguimiento" ya la usaba.

El cambio se hizo **en un solo lugar**: la rama de modo-creación de
`TaskForm.onMounted`. Después de aplicar la prop explícita `initialAdvisorId`
(que mantiene prioridad), se agregó un `else if`:

```ts
} else if (authStore.user?.advisorId) {
  form.value.advisor_id = authStore.user.advisorId
  selectedAdvisorId.value = authStore.user.advisorId
}
```

Como `TaskForm.vue` es el mismo componente que usan el modal del módulo de Tareas
y el sidebar del lead, el prellenado **cubre ambos puntos de entrada sin duplicar
lógica** (requisito técnico de la HU). `loadSelectData()` resuelve el nombre del
asesor prellenado ("Pruebas G13" en la prueba) al terminar de cargar la lista.

---

## Decisiones tomadas
- **Detección por `authStore.user.advisorId`** (el registro de asesor vinculado al
  usuario), no por rol. Es el dato directo y confiable — da justo el id a
  prellenar y evita la ambigüedad del `user.roles` (marcado deprecado a favor del
  RBAC store). Un usuario sin asesor asociado trae `advisorId` undefined → no entra
  al `else if` → Escenario 2 intacto.
- **Implementación dentro de `TaskForm.vue`** (no pasando la prop desde cada punto
  de entrada) para no duplicar lógica y cubrir automáticamente cualquier futuro
  punto de entrada. Solo corre en `onMounted` y solo en modo creación; edición no
  se toca.
- **`initialAdvisorId` explícito mantiene prioridad** (p. ej. el follow-up tras
  completar una tarea sigue mandando su propio asesor).

---

## Verificación
- **Prueba funcional en navegador (Escenario 1):** para poder probar con la cuenta
  de owner (que también existe como asesor pero no estaba vinculada), se ligó
  **temporalmente** en BD `users.advisor_id = 57` para el user 82; tras re-login el
  campo Asesor se prellenó correctamente. El vínculo se **revirtió a NULL** al
  terminar (estado original) y se limpió el caché Redis `user_ctx`.
- **Tests (`vitest run`):** 149/151 pasan. Los 2 fallos están en
  `postventaConfigHelpers.test.ts` (ordenamiento de opciones de financiamiento) y
  se confirmó que **ya fallaban sin este cambio** (reproducidos con el archivo
  stasheado) → pre-existentes y ajenos a esta tarea.
- **`type-check`:** `TaskForm.vue` sin errores; los errores que salen son
  pre-existentes en otros archivos no tocados.

## Pendientes / seguimiento
- Push de la rama y PR (los hace el usuario).
- Deuda previa ajena: los 2 fallos de `postventaConfigHelpers.test.ts` conviene
  avisarlos al dueño del módulo de postventa (no bloquean esta tarea).

---

## Nota de contexto (no forma parte de este commit)
Durante la sesión el backend local (`app-saas-service`) no arrancaba por drift de
migraciones: el modelo tenía `projects.zone` pero la migración `zone01` no estaba
aplicada. Se reconcilió el drift con `alembic upgrade head` a un head único
(`b4132af670df`) y se hizo idempotente `p910level01` (columna `level` de
`facebook_ad_insights` que estaba agregada a mano). **Eso es del entorno local del
usuario y NO se commitea** con esta tarea; queda como fix local. La reconciliación
de fondo de la rama Slack (SCRUM-1278) con `main` sigue pendiente como PR aparte.
