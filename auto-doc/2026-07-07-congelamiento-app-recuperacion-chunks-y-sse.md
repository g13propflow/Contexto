# Congelamiento de la app tras pérdida de SSE — recuperación de chunks + saneamiento SSE/CORS

## Fecha
2026-07-07

## Tarea solicitada (en concreto)
Ejecutar el plan definitivo (`PLAN-congelamiento-app-tras-perdida-sse.md`) que
resuelve el escenario donde la app queda inutilizable tras horas abierta: primero
falla el SSE (ERR_HTTP2_PROTOCOL_ERROR / CORS / reintentos infinitos), luego se
rompe la navegación y fallan los imports dinámicos (`Failed to fetch dynamically
imported module`, `Expected JavaScript module but received text/html`), y al
duplicar la pestaña todo queda en blanco hasta un refresh manual.

## Causa raíz (del diagnóstico previo)
1. **Principal:** redeploy del frontend con la pestaña abierta → chunks con hash
   obsoletos → nginx (`try_files ... /index.html`) devolvía `index.html`
   (`text/html`, 200) para el `.js` inexistente → el import dinámico rechaza el MIME
   → **sin `router.onError` ni `vite:preloadError`, la navegación quedaba muerta**.
2. **Secundaria:** cliente SSE con `maxReconnectAttempts = Infinity` sin backoff →
   tormenta de reconexión. En el endpoint SSE había un `Access-Control-Allow-Origin: *`
   manual; **verificado con Starlette 0.46.2** que NO producía cabecera duplicada (el
   `CORSMiddleware` la sobreescribe para orígenes permitidos), pero **sí filtraba `*`
   a orígenes NO permitidos** (hueco de seguridad). No era la causa de los errores CORS
   de los logs (esos son efecto colateral de las peticiones SSE que fallan/abortan).

## Rama
`fix/SCRUM-1325` — commiteado (frontend `3db1c819`, backend `4dc4fb5e`); **sin push**
(lo hace el usuario). Pendiente: push + PRs + rebuild de imágenes Docker para desplegar.

## Módulo(s) afectado(s)

### `app-saas-frontend`
- `src/utils/moduleReload.ts` (**nuevo**) — detección de errores de carga de módulo
  + recarga controlada con guard anti-bucle (`sessionStorage`, ventana 12 s) +
  ref reactivo `moduleReloadPrompt`.
- `src/components/ui/AppReloadPrompt.vue` (**nuevo**) — overlay "Hay una versión
  nueva disponible / Recargar" (Tailwind, i18n, accesible).
- `src/locales/es/appRecovery.ts`, `src/locales/en/appRecovery.ts` (**nuevos**) +
  registro en `src/i18n.ts` como namespace `appRecovery`.
- `src/router/index.ts` — `router.onError`: recupera navegaciones a rutas lazy cuyo
  chunk ya no existe (recarga hacia `to.fullPath`).
- `src/main.ts` — listeners `vite:preloadError` y `unhandledrejection` (gated por
  `isModuleLoadError`) como red de seguridad.
- `src/App.vue` — `onErrorCaptured` (boundary) + montaje de `AppReloadPrompt`.
- `src/stores/notifications.ts` — reconexión SSE acotada: `maxReconnectAttempts = 8`,
  backoff exponencial con jitter (1s→30s) devuelto desde `onerror`, y reintento
  espaciado (`RECONNECT_COOLDOWN_MS = 60s`) tras agotar intentos; `disconnect()`
  ahora limpia el timer pendiente.
- `nginx.conf` — `location /assets/` con `try_files $uri =404` (ya **no** cae a
  index.html) + `Cache-Control: immutable`; `location = /index.html` con
  `Cache-Control: no-cache`.

### `app-saas-service`
- `app/api/v1/sse_events.py` — se eliminó el `Access-Control-Allow-Origin: *` y
  `Access-Control-Allow-Headers` manuales del `StreamingResponse`; el CORS lo maneja
  únicamente el `CORSMiddleware` global. Verificado (Starlette 0.46.2): para el origen
  del frontend el resultado es idéntico antes/después (1 cabecera correcta) → **sin
  regresión**; el fix solo **cierra la fuga del `*` a orígenes no permitidos**.
  Requisito de deploy: `CORS_ORIGINS` de prod debe incluir el origen del frontend
  (ya se cumple, pues toda la API usa el mismo middleware y funciona).

## Verificación (realizada)
- `npm run type-check` (con `--max-old-space-size=8192`): **sin errores nuevos** en
  los archivos tocados. Los errores que reporta son pre-existentes en otros módulos
  (NotificationBell, WorkflowEditor, FHAView, etc.), ajenos a este cambio.
- **Test de regresión** `src/utils/moduleReload.test.ts` (`vitest`): **4/4 pasan**
  (detección de errores de módulo: positivos, negativos, tipos, case-insensitive).
- **Build de producción** (`vite build`): OK; emite `dist/assets/*-<hash>.js`.
- **nginx funcional** (contenedor `nginx:alpine` sirviendo el build real):
  - chunk real → `200` + `application/javascript` + `Cache-Control: immutable`.
  - chunk faltante → **`404`** (NO `text/html`).  ← fix central.
  - config **anterior** (para probar causalidad): chunk faltante → `200 text/html`.
  - ruta SPA → `200 text/html`; `/index.html` → `Cache-Control: no-cache`.
- **CORS backend** (repro con FastAPI + Starlette 0.46.2, misma versión del proyecto):
  origen permitido → 1 cabecera correcta antes y después (sin regresión); origen no
  permitido → antes `*` (fuga), después sin cabecera (bloqueado).
- **Navegador (validado por el usuario):** overlay se muestra bien y el botón Recargar
  funciona; recarga controlada por `vite:preloadError`; con SSE bloqueado en Network,
  backoff acotado en consola (attempt 7/8 retrying ~30s → Max reached, ya no infinito)
  y la app sigue navegable.

## Notas / pendientes de infraestructura (fuera del repo)
- **Bloque 4 (HTTP/2 coalescing):** confirmar si el origen de la API y el de los
  estáticos comparten IP/cert tras el mismo Traefik; si coalescen, un `GOAWAY` del
  stream SSE puede arrastrar la descarga de chunks. Revisar timeouts HTTP/2 de
  Traefik para SSE. No implementable desde estos repos.
- El `nginx.conf` del repo aplica si el frontend se sirve con ese nginx; si en prod
  el estático lo sirve otro proxy/host, replicar allí las reglas de `/assets/` 404 +
  cache-control de `index.html`.
