# SCRUM-1290 — Clic en día del mes abre la vista Semana (+ arreglo de altura en vista Mes)

## Fecha
2026-07-01

## Tarea solicitada (en concreto)
En la vista mensual del calendario, al hacer clic sobre cualquier día: cambiar
automáticamente a la vista semanal, mostrar la semana que contiene esa fecha,
mantenerla como fecha activa, resaltar el día seleccionado y cargar todas las
citas/eventos de la semana (mostrando de inmediato los del día si existen).
Reutilizando la lógica existente, sin duplicar y preservando filtros/estado.

## Rama
`feature/SCRUM-1290`
- commit `5cc12bb` — clic en día de la vista Mes → vista Semana (+ fix altura Mes)
- commit `d2b6517` (2026-07-02) — se extiende la misma funcionalidad al **mini-calendario**

## Módulo(s) afectado(s)
`app-saas-frontend` — módulo calendario
- `src/views/CalendarView.vue` (único archivo)

---

## Resumen de lo que se hizo
- **Feature:** `handleDateClick` ahora, en desktop, cambia a vista Semana centrada
  en el día clicado (móvil sigue yendo a Día); fija `selectedDate`, sincroniza
  `miniCalendarDate` y recarga eventos.
- Se agregó `isSelected` en `getWeekDays()` y el resaltado (círculo índigo) del día
  seleccionado en el header de la vista Semana/Workweek.
- `loadEvents()` ahora extiende el rango en vistas de semana/día para cubrir semanas
  a caballo entre dos meses (antes solo cargaba el mes de `miniCalendarDate`).
- **Fix de bug preexistente (aprobado):** la vista Mes se estiraba cuando un día
  tenía muchos eventos (`grid-auto-rows: minmax(60px,1fr)` crecía con el contenido).
  Se limita a N eventos por celda (4 desktop / 2 móvil) con chip **"+N"**; el clic en
  la celda abre la semana/día con todos los eventos.

## Decisiones tomadas
- **Clic en día reemplaza al modal de crear evento en desktop** (antes abría el modal).
  Confirmado con el usuario; crear evento sigue disponible por botón "+" y por clic en
  slot horario.
- **Semanas entre dos meses:** se resolvió (opción elegida por el usuario) extendiendo
  el rango de carga, en lugar de dejarlo como limitación.
- **Carga siempre ≥ el mes de `miniCalendarDate`** (no solo la semana) para que al
  volver a la vista Mes no aparezca incompleta.
- **Indexado de eventos del mes por día LOCAL** (`formatDateValue`) y **ordenado por
  hora**, para consistencia con la vista semana/día (single source of truth) y para que
  el recorte "+N" oculte los más tardíos, no eventos arbitrarios.
- **Paginado de semana/día ancla `miniCalendarDate`** al mes de la fecha activa, para
  acotar el rango de carga (evita payloads que crecían sin fin al alejarse).

## Preguntas y respuestas
1. *¿Reemplazar el clic-en-día (que abría el modal de crear evento) por ir a Semana?*
   → Sí, reemplazar por vista Semana.
2. *¿Cómo tratar las semanas que cruzan dos meses?* → Resolverlo también (rango extendido).
3. *¿Arreglar ahora el "mes alargadísimo"?* → Sí, arreglarlo ahora.
4. *¿Julio (mes actual) debería tener eventos?* → Está vacío de por sí (no era bug de carga).

---

## ¿Se tocó trabajo de otros desarrolladores?
No. Todo el cambio está contenido en `CalendarView.vue`; no se modificaron servicios,
stores, tipos ni componentes de terceros.

## Bugs de otros encontrados / resueltos
- **Mes alargadísimo (preexistente):** la vista Mes se estiraba con días de muchos
  eventos. Resuelto en esta tarea (tope por celda + "+N").
- **Eventos de la tarde en día equivocado (preexistente):** el índice del mes usaba
  fecha UTC; en UTC-6 un evento nocturno caía al día siguiente. Corregido al pasar el
  índice del mes a día local.
- **`getWeekDays` usa `toISOString` → off-by-one en offsets UTC positivos:** detectado
  en el code review; es la convención de todo el módulo y no afecta a usuarios en UTC-6.
  Dejado anotado, fuera de alcance.

---

## Notas / pendientes
- **Verificación en navegador pendiente del lado del usuario** (no se pudo automatizar
  por el login Auth0). Re-test sugerido: día correcto de eventos de la tarde en Mes;
  el "+N" oculta los más tardíos; paginar semanas lejanas no ralentiza la carga.
- Code review de alto esfuerzo ejecutado: 3 hallazgos reales corregidos; el resto
  descartado con justificación (UX intencional, TZ preexistente, micro-optimizaciones).
- `npm run type-check` sin errores en `CalendarView.vue`.
- Falta `git push` (lo hace el usuario).

---

## Ampliación (2026-07-02) — Misma funcionalidad en el mini-calendario

### Tarea solicitada
Que el **mini-calendario** de la barra lateral tenga la misma funcionalidad que se
agregó en la vista Mes: al seleccionar un día, pasar a la vista Semana.

### Qué se hizo
- `selectDate` (handler del mini-calendario, único consumidor) **delega ahora en
  `handleDateClick`**, el mismo handler que usa la vista Mes. Antes solo fijaba
  `selectedDate` (resaltaba el día sin navegar).
- Resultado: clic en día del mini-calendario → **vista Semana** (desktop) / **vista
  Día** (móvil) centrada en ese día, con `miniCalendarDate` sincronizado (incluye
  días de arrastre de otro mes) y recarga de eventos del rango.

```js
const selectDate = (dateString) => {
    handleDateClick(dateString)
}
```

### Decisión
- **Delegar en `handleDateClick` en vez de duplicar la lógica** → única fuente de
  verdad; si el comportamiento del clic-en-día cambia, ambos caminos (vista Mes y
  mini-calendario) quedan consistentes automáticamente. Sin problema de TDZ/hoisting:
  `handleDateClick` solo se invoca en tiempo de clic, cuando ya está definido.

### Alcance / no se tocó trabajo de otros
- **1 archivo:** `src/views/CalendarView.vue` (+5/-2). Sin cambios en servicios,
  stores, tipos ni componentes de terceros. `selectDate` no lo consume nada más.

### Pruebas
- Diff aislado confirmado (solo `CalendarView.vue`, +5/-2).
- `npm run type-check`: sin errores en `CalendarView.vue` (los demás errores son
  preexistentes en archivos ajenos).
- No existen tests de calendario en el repo.
- Revisión del flujo runtime: `selectDate → handleDateClick → loadEvents`;
  `getWeekDays()` deriva de `selectedDate` → semana correcta y rango extendido en
  semanas a caballo entre dos meses.
- ⚠️ Verificación visual en navegador pendiente (login Auth0 bloquea automatización).

### Commit y PR
- Commit `d2b6517` en `feature/SCRUM-1290`.
- El PR contra `main` muestra solo `CalendarView.vue` (+5/-2): el merge-base es
  `5cc12bb`, así que el diff de tres puntos queda limpio pese a que la rama está
  detrás de `main`.
- Falta `git push` (lo hace el usuario).
