# Eliminar la opción de vista "Semana Laboral" del calendario

## Fecha
2026-07-06

## Tarea solicitada (en concreto)
Retirar por completo la vista **"Semana Laboral"** del calendario: que deje de
aparecer en el selector de vistas y, además (Opción B acordada con el stakeholder),
eliminar todo su código muerto asociado del proyecto, sin afectar el funcionamiento
de las demás vistas (Día, Semana, Mes) y sin romper nada existente.

Como red de seguridad se pidió respaldar el cambio con tests antes/después.

## Rama
`main` (pendiente de commit por el usuario)

## Módulo(s) afectado(s)
`app-saas-frontend` — módulo de Calendario
- `src/views/CalendarView.vue` — eliminación total de la lógica `workweek`
- `src/views/calendarViewHelpers.ts` (**nuevo**) — lógica pura de fechas extraída
- `src/views/calendarViewHelpers.test.ts` (**nuevo**) — 12 tests de regresión
- `src/locales/es/calendar.ts`, `src/locales/en/calendar.ts` — clave `workweek` eliminada
- `src/locales/es.json`, `src/locales/en.json` — clave `workweek` eliminada

---

## Resumen de lo que se hizo

### 1. Eliminación de la opción del selector
Se quitó la entrada `{ label: t('calendar.views.workweek'), value: 'workweek' }`
del array `views` que alimenta los botones del selector. Era el **único punto** que
permitía asignar `currentView = 'workweek'`; ningún otro punto del código lo hace y
`currentView` no se persiste (arranca en `'month'`, solo el tema va a `localStorage`).
Al quitarlo, la vista quedó inalcanzable — sin estados inconsistentes posibles.

### 2. Eliminación total del código muerto (Opción B)
Con la vista ya inalcanzable, todas las ramas `workweek` restantes eran código
muerto. Se eliminaron/colapsaron en `CalendarView.vue`:
- `getWeekDays()` — borrada la rama `else if (currentView === 'workweek')` (5 días).
- `showNowLine` — `endDays = workweek ? 5 : 7` → fijo 7 días.
- `nowLineStyle` — `totalCols = workweek ? 5 : 7` → fijo 7.
- `useClusterLayout` — comentario actualizado (la condición ya era solo `'week'`).
- `previousPeriod` / `nextPeriod` — `('week' || 'workweek')` → `'week'`.
- `handleTimeSlotClick` — `('week' || 'workweek')` → `'week'`.
- Template: grids `grid-cols-[60px_repeat(5,1fr)]` (2 ocurrencias) eliminados;
  condiciones `(currentView === 'week' || currentView === 'workweek')` colapsadas
  a `currentView === 'week'`; comentarios `week/workweek` → `week`.
- Claves i18n `workweek` eliminadas en los 4 archivos de locales (ts + json, es + en).

### 3. Red de seguridad: extracción a función pura + tests
La única lógica con riesgo real era la aritmética de fechas de la semana (compartida
con la vista **Semana**, que se conserva). Se extrajo a `calendarViewHelpers.ts`
(**única fuente de verdad**, testeable sin montar el componente):
- `getMondayOf(date)` — lunes de la semana, normalizado a 00:00 (para comparaciones
  de rango). Idéntico al `getMondayOf` inline que se eliminó del componente.
- `buildWeekDays(anchor, count = 7)` — días consecutivos desde el lunes, **preservando
  la hora del ancla** (comportamiento histórico de la vista Semana).

`getWeekDays()` (rama `week`) ahora usa `buildWeekDays(current, 7)`; el `getMondayOf`
inline se reemplazó por el import.

`calendarViewHelpers.test.ts` — 12 tests que fijan el comportamiento de la vista
Semana: 7 días L→D, domingo cierra su semana, cruce de frontera de mes y de año,
días consecutivos, preservación de la hora del ancla, `count` personalizado.

---

## Decisiones tomadas
- **Opción B (borrado total) en vez de solo ocultar** — a pedido del stakeholder.
  El alcance quedó acotado 100% al frontend: la búsqueda global confirmó **0
  referencias** a `workweek`/"semana laboral" en `app-saas-service` ni en los
  microservicios. La "semana laboral" nunca fue un concepto de backend (este solo
  recibe un rango de fechas); era puramente un modo de visualización de la UI.
- **Extraer solo el cálculo de fechas** (no montar el componente completo en tests):
  es la parte con riesgo real y el patrón `*Helpers.ts` + `*Helpers.test.ts` ya es
  convención del repo (`tasksViewHelpers`, `viewModeHelpers`, etc.).
- **`buildWeekDays` preserva la hora del ancla** en vez de reutilizar `getMondayOf`
  (que normaliza a medianoche). Reutilizarlo habría cambiado el string de fecha
  (`toISOString().split('T')[0]`) en zonas horarias UTC+, alterando la vista Semana.
  El test lo fija explícitamente.

---

## Verificación
- **Tests unitarios nuevos:** 12/12 en verde (`calendarViewHelpers.test.ts`).
- **Suite completa (`npm test`):** 161 passed. Los **2 fallos** son **preexistentes**
  en `postventa/postventaConfigHelpers.test.ts` (`deriveFinancingOptions`), ajenos al
  calendario — ya fallaban en el baseline antes de este cambio.
- **`npm run build-only`:** el SFC y el template compilan sin errores (`✓ built`).
- **`npm run type-check`:** sin errores nuevos en los archivos tocados
  (`CalendarView.vue`, `calendarViewHelpers.ts`). Los errores del type-check global
  son preexistentes y en archivos no tocados.
- **Verificación visual:** realizada por el usuario — vistas Día/Semana/Mes cargan y
  navegan correctamente; la opción "Semana Laboral" ya no aparece en el selector.

## Pendientes / seguimiento
- Commit y push (los hace el usuario).
- Sin migraciones, sin cambios de backend, sin variables de entorno nuevas.
