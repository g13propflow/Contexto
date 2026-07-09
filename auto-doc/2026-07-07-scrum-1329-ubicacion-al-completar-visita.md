# Registro obligatorio de ubicación al completar una visita (SCRUM-1329)

## Fecha
2026-07-07

## Tarea solicitada (en concreto)
HU: al marcar una visita como completada (desde cualquiera de los 3 flujos), el sistema
debe **capturar la geolocalización del dispositivo del asesor** (prompt nativo), hacerla
**obligatoria** (sin ubicación no se completa), almacenarla asociada al evento de la visita
(lat/long/precisión/fecha-hora + dirección por reverse geocoding) y mostrarla en
**solo-lectura con mapa** en el detalle del evento (visible por rol `owner`).

Plan: `PLAN-registro-ubicacion-al-completar-visita.md`.

## Rama y commits
Rama **`feature/SCRUM-1329`** en `calendar-service`, `app-saas-frontend` y `app-saas-service`.
Sin push ni commit todavía (los hace el usuario tras revisión).

## Decisiones de arquitectura (del plan §0/§7)
- **Fuente de verdad = calendar-service** (la ubicación es atributo del evento; el evento
  solo existe ahí). app-saas-service no tiene tabla de eventos.
- **Enforcement/orden (Opción A)** + refuerzo con **fill-in idempotente** en el command:
  si el estado se fijó a `atendida` sin ubicación y luego llega una válida, se rellena.
- **Reverse geocoding** best-effort en calendar-service (key server-side propia) + fallback
  de dirección en cliente con el Geocoder del SDK. Si falla, coords se guardan y address = NULL.
- **Mapa** con `vue3-google-map` (wrapper read-only `VisitLocationMap.vue`); degrada a enlace
  si no hay `VITE_GOOGLE_MAPS_API_KEY`.
- **Sin evento de calendario** (§8, Opción B): no se bloquea; app-saas guarda la ubicación en
  `lead.extra_data.completion_location`.
- **Visualización** gated por rol `owner` (ampliable).

## Módulos afectados

### calendar-service (fuente de verdad)
- `src/migrations/008_add_completion_location_to_calendar_events.sql` (nuevo) — columnas
  `completion_latitude/longitude/accuracy/captured_at/address` (T-SQL idempotente).
- `src/modules/events/entities/calendar_events.entity.js` — 5 campos Sequelize.
- `src/infrastructure/adapters/geocoding/reverse.geocode.js` (nuevo) — Google Geocoding API,
  best-effort, nunca lanza; gated por `GOOGLE_MAPS_API_KEY`.
- `src/modules/events/commands/calendar_events.commands.js` — `markAttended`/`_markOutcome`:
  validación de coords, obligatoriedad en la transición, inmutabilidad, fill-in, reverse
  geocoding, ubicación en el timeline metadata. `_validateCompletionLocation` (nuevo).
- `src/modules/events/controllers/calendar_events.controller.js` — lee `completion_location`
  del body; mapea `LOCATION_REQUIRED`/`LOCATION_INVALID` a 400.
- `.env.example` — `GOOGLE_MAPS_API_KEY` (server-side).
- `tests/modules/events/commands/markAttended.location.test.js` (nuevo) — 7 tests.

### app-saas-frontend
- `src/composables/useVisitLocation.ts` (nuevo) — captura centralizada (Permissions API +
  getCurrentPosition, `maximumAge:0`), errores tipados, `visitLocationErrorMessage`.
- `src/components/calendar/VisitLocationMap.vue` (nuevo) — mapa read-only (marker único).
- `src/services/calendar.service.ts` — `markEventAttended(id, completionLocation?)` envía
  `completion_location`.
- `src/views/LeadsView.vue` — gate de captura en `submitVisitFeedback` (CTA + drag); ubicación
  en `updateLead` y en `markEventAttended`.
- `src/components/calendar/EventModal.vue` — gate en `submitEventVisitFeedback`; bloque
  solo-lectura + mapa (gated por `hasRole('owner')`).
- `src/locales/{es,en}/leads.ts` — claves `visitFeedback.steps.capturingLocation` y sección
  `visitLocation` (errores + labels de visualización).
- `src/composables/useVisitLocation.test.ts` (nuevo) — 9 tests (Vitest).

### app-saas-service
- `app/services/calendar_microservice.py` — `mark_attended(..., completion_location)` +
  `_mark_outcome(..., body)` envían la ubicación en el POST.
- `app/services/lead_service.py` — `update_status_with_lead(..., completion_location)`:
  la pasa a `mark_attended` con evento; sin evento la guarda en `extra_data`.
- `app/schemas/lead.py` — `LeadCompletionLocation` (nuevo) + campo `completion_location`
  en `LeadUpdate`.
- `app/api/v1/leads.py` — PATCH extrae `completion_location` y lo propaga al servicio.

## Verificación realizada
- calendar-service: `npx jest tests/modules/events` → **29/29** (incluye 7 nuevos).
- frontend: `npm run type-check` → sin errores en archivos de la HU (resto son preexistentes
  del repo); `npx vitest run useVisitLocation.test.ts` → **9/9**.
- app-saas-service: `py_compile` OK en los 4 archivos.

## Revisión de bugs (adversarial, contexto fresco por repo) — corregidos
1. **calendar-service (auto-detectado):** el fill-in de ubicación podía escribir sobre un
   evento `cancelada`/`reagendada` (no solo `atendida`). Fix: gate `attendedNowOrAlready`
   (`willTransition || appointment_state === 'atendida'`) + test de regresión.
2. **calendar-service:** `Number(null)===0` / `Number('')===0` → coordenadas `null`/`''`/`boolean`
   se coercían a (0,0) (isla nula) pasando la validación; `accuracy: null` se guardaba como `0`.
   Fix: `toNumberOrNaN` rechaza null/''/boolean; accuracy null→null. +3 tests.
3. **app-saas-service:** con resultado `descartado` tras visitar y lead **sin** evento, la
   ubicación se perdía (el fallback a `extra_data` solo cubría `cita_completada`). Fix: rama
   unificada para `cita_completada`/`descartado`.
4. **frontend:** sin bugs de correctitud (gate aborta bien, i18n completo en es/en, sin
   shadowing, rol/mapa correctos).

Tras los fixes: calendar-service **11/11**, frontend vitest **9/9**, py_compile OK.

## Estado — PAUSADO (2026-07-08), bloqueado por API keys de Google Maps

Se pausa la tarea para avanzar en otra HU. Código **completo y commiteado**; falta la
verificación de la parte de mapa/dirección, que depende de keys de Google Maps que se le
solicitaron al jefe (ver mensaje redactado; aún no provistas).

### Ya hecho
- Los **4 commits** están en la rama `feature/SCRUM-1329` de cada repo (sin push):
  calendar-service, app-saas-frontend (2 commits: base + fallback de geocoding en cliente
  `bdac261a`), app-saas-service.
- **Migración 008 aplicada** en la BD de **dev** `PropFlow_Gerardo` (Azure), verificadas las 5
  columnas `completion_*`. *(Falta aplicarla en staging/prod al desplegar.)*
- **Probado el happy path** en navegador: al completar una visita se guarda la fila con
  `completion_latitude/longitude/accuracy/captured_at` (verificado en SQL). `completion_address`
  quedó **NULL** por no haber key server-side (comportamiento esperado).
- Se agregó **fallback de geocoding en cliente** (VisitLocationMap resuelve la dirección con el
  Geocoder del SDK y la emite; EventModal la muestra). Type-check OK.

### Pendiente de PROBAR cuando lleguen las keys
- **Mapa embebido** en el detalle del evento (no se ve hoy porque el `.env` del front **no**
  tiene `VITE_GOOGLE_MAPS_API_KEY` → degrada al enlace de coordenadas).
- **Dirección legible** — dos caminos a validar: (a) fallback en cliente (requiere la key del
  front con **Geocoding API**), y (b) persistencia en BD (`completion_address`) con la key
  **server-side** de calendar-service (**Geocoding API**).
- **Casos de permiso**: denegado (no guarda + mensaje "acceso obligatorio") y bloqueado
  permanente (mensaje "habilita en configuración").
- **Visualización con rol `owner`** del bloque read-only completo (dirección + coords + fecha + mapa).

### Keys requeridas (solicitadas al jefe)
- **Front** `VITE_GOOGLE_MAPS_API_KEY` (pública): **Maps JavaScript API + Geocoding API**,
  referrer `http://localhost:5173/*` (dev) / dominios prod.
- **Server-side** `GOOGLE_MAPS_API_KEY` en calendar-service (secreta): **Geocoding API**,
  restringida por IP.
- *Nota:* la **Roads API** (usada en tracking de asesores) **no aplica** — no hace reverse
  geocoding. Para dev se puede usar **1 sola key sin restricción de aplicación** con ambas APIs;
  para prod, 2 keys separadas (una key no puede tener restricción por referrer **e** IP a la vez).

### Otros pendientes de deploy
- Aplicar **migración 008** en staging/prod.
- Setear las 2 keys en las variables de entorno del entorno correspondiente.
- **Push + PRs** de la rama `feature/SCRUM-1329` en los 3 repos (los hace el usuario).
