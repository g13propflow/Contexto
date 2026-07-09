# PLAN — Diagnóstico integral y solución definitiva del congelamiento de la app tras pérdida de conexión SSE

> **Alcance de este documento:** análisis técnico. **No** contiene cambios de código. Es la base para una implementación única y definitiva.
> **Repos analizados:** `app-saas-frontend` (Vue 3 + Vite), `app-saas-service` (FastAPI).
> **Fecha:** 2026-07-07.

---

## 0. Resumen ejecutivo (TL;DR)

El síntoma reportado ("la app se congela tras horas abierta, luego fallan los módulos, y al duplicar la pestaña queda en blanco") **no tiene una sola causa: son dos fallas independientes que ocurren en la misma ventana temporal y se confunden entre sí.**

1. **Causa raíz principal (probabilidad ALTA):** la app queda con **chunks de JavaScript obsoletos** porque se hace un **redeploy del frontend mientras la pestaña sigue abierta**. Los nombres de los chunks llevan hash; al desplegar cambian; el `index.html` que corre en la pestaña referencia hashes que **ya no existen** en el servidor. El host estático responde el **fallback SPA (`index.html`, `Content-Type: text/html`, HTTP 200)** para el `.js` faltante. Vite valida el MIME del módulo y lo rechaza → `Expected JavaScript module but received text/html` / `Failed to load module script`. **No existe ningún manejador que recupere de esto** (`router.onError`, `vite:preloadError`), así que la navegación queda muerta hasta un refresh manual.

2. **Causa raíz secundaria (probabilidad MEDIA-ALTA):** el cliente SSE está configurado para **reconectar infinitamente** (`maxReconnectAttempts = Infinity`) **sin backoff propio, con reconexión adicional por heartbeat y por `visibilitychange`**. Esto genera la "tormenta de reconexión" (ERR_HTTP2_PROTOCOL_ERROR, Failed to fetch, CORS) de la etapa 1. Si el frontend y la API comparten conexión HTTP/2 (coalescing detrás del mismo proxy/cert), un `GOAWAY`/reset en esa conexión **puede** arrastrar también a la descarga de chunks → explica por qué los imports empiezan a fallar *justo después* de que el SSE falla.

> **CORRECCIÓN (verificado empíricamente con Starlette 0.46.2):** el análisis original suponía que el endpoint SSE emitía una **cabecera CORS duplicada** (`Access-Control-Allow-Origin` del `CORSMiddleware` global **+** el `*` manual). **Es falso:** Starlette **sobreescribe** el `*` manual con el origen específico para orígenes permitidos, así que sale **una sola** cabecera correcta. Los "errores de CORS" de la etapa 1 son un **efecto colateral** de las peticiones SSE que fallan/abortan (Chrome reporta fallos de red HTTP/2 o respuestas de error del proxy sin cabeceras CORS como "CORS error"), **no** una mala configuración de cabeceras. El único bug CORS real del endpoint es que el `*` manual **se filtra a orígenes NO permitidos** (ver §3 hipótesis D corregida).

**La corrección anterior atacó los síntomas equivocados** (expiración de sesión y cuelgue de RBAC). No tocó ninguna de las dos causas reales, y en el caso del SSE incluso **empeoró** el comportamiento al volver la reconexión infinita.

**Prueba diferencial decisiva:** al **duplicar la pestaña**, la pestaña nueva arranca con un runtime JS **completamente nuevo** (Pinia/estado global vacío). Si aun así está rota, **la corrupción NO está en el estado JS ni en el SSE**: está en los **artefactos servidos (index.html cacheado + chunks inexistentes)** y en el **pool de conexiones HTTP/2 compartido entre pestañas del mismo proceso**. Esto descarta "el SSE contaminó el store global" como causa raíz.

---

## 1. Análisis de la solución previamente implementada

Reconstruida desde el código y los comentarios que la documentan (`api.config.ts`, `router/index.ts`, `stores/notifications.ts`).

### 1.1 Qué problema intentaba resolver
La app quedaba "inhabilitada" tras un rato abierta. La hipótesis de entonces fue: **la sesión/token expira o la carga de permisos se cuelga, y la app no se recupera ni redirige.**

### 1.2 Qué cambios se realizaron
- **`api.config.ts` — manejo global de 401 (`handleSessionExpired`)**: una sola vez por carga de página, limpia tokens y hace `window.location.href = '/login'`. Comentario textual: *"Evita que la app quede 'inhabilitada' tras expirar el token sin ningún reintento ni redirección."*
- **`api.config.ts` — fallback de token**: si `auth0Service.getAccessToken()` falla, se usa el token cacheado en lugar de desloguear (evitar deslogueos prematuros en SSO).
- **`router/index.ts` — timeout de RBAC (`RBAC_INIT_TIMEOUT_MS = 8000`)**: el guard no espera indefinidamente a que RBAC inicialice; si expira/falla, deja pasar la navegación y **no** rebota a `/404` (para no "inhabilitar el menú").
- **`stores/notifications.ts` — resiliencia del SSE**: heartbeat cada 30 s (reconecta si no hay eventos en 90 s), `openWhenHidden: true`, reconexión en `visibilitychange`, y `maxReconnectAttempts = Infinity`.

### 1.3 Qué escenarios quedaron cubiertos
- Expiración de token con respuesta **401 explícita** → redirección limpia a login (una vez).
- Cuelgue de la inicialización de RBAC → el menú ya no se congela por esperar permisos.
- SSE que se cae por inactividad → intenta revivir.

### 1.4 Qué escenarios NO quedaron cubiertos
- **Fallo de imports dinámicos** (`Failed to fetch dynamically imported module`, `Expected JavaScript module but received text/html`). **No hay `router.onError` ni listener de `vite:preloadError` en todo el proyecto** (verificado por búsqueda: 0 coincidencias). Una vez que un chunk falla, la ruta queda muerta.
- **Redeploy del frontend con la pestaña abierta** (chunks obsoletos). El handler de 401 **nunca se dispara** aquí, porque el servidor responde **200 + text/html**, no 401.
- **Tormenta de reconexión SSE**: no hay tope de intentos, ni backoff exponencial propio, ni coordinación entre los 3 disparadores de reconexión (auto-retry de la librería + heartbeat + visibilitychange).
- **Fuga de CORS del endpoint SSE** (el `*` manual llega a orígenes no permitidos; ver §3-D corregida, §4 y §6).
- **Coalescing HTTP/2** entre origen de API y origen estático (nivel infraestructura).

### 1.5 Qué supuestos fueron incorrectos
1. *"El congelamiento se debe a expiración de sesión/SSE muerto."* → Falso para el escenario actual: los logs muestran **200 con text/html** en los chunks, firma inequívoca de **artefactos obsoletos**, no de auth.
2. *"Mantener el SSE reconectando 'para siempre' hace la app más robusta."* → Contraproducente: reconexión infinita **sin backoff** contra una conexión rota amplifica los errores HTTP/2 y CORS de la etapa 1.
3. *"Si RBAC no rebota a /404, el menú deja de congelarse."* → Resolvió un cuelgue distinto; no tiene relación con el fallo de carga de módulos.

### 1.6 Por qué no fue suficiente
Porque **parchó los síntomas de auth/RBAC y dejó intactas las dos causas reales**: (a) ausencia total de recuperación ante imports dinámicos fallidos, y (b) reconexión SSE no acotada sobre un endpoint mal configurado (CORS) y una topología HTTP/2 potencialmente coalescida.

---

## 2. Reconstrucción cronológica del problema (relación causal, no lista de errores)

> Se cruzan las 3 etapas del reporte con el comportamiento real del código.

**T0 — App abierta y sana.** `DashboardLayout.onMounted()` llama `notificationsStore.connect()` (una conexión SSE de larga vida contra `${VITE_API_BASE_URL}/api/v1/sse/notifications`). Las rutas se cargan con `() => import(...)` (lazy). Todo funciona.

**T1 — Ocurre el disparador (uno de dos, o ambos):**
- **(a) Se despliega una nueva versión del frontend.** Los `/assets/*-<hash>.js` cambian de nombre. El `index.html` en memoria de la pestaña sigue apuntando a los hashes viejos.
- **(b) La conexión SSE se degrada.** Idle timeout del proxy, `GOAWAY`, restart del backend, o rechazo por el conflicto CORS. La librería marca error.

**T2 — Etapa 1 (SSE empieza a fallar).** `onerror` del cliente **no** aplica backoff propio ni tope (es `Infinity`), y además compiten el auto-retry de `@microsoft/fetch-event-source`, el heartbeat (90 s) y el `visibilitychange`. Resultado: **reintentos frecuentes** que, contra una conexión HTTP/2 rota, producen `ERR_HTTP2_PROTOCOL_ERROR`, `Failed to fetch` y, por el conflicto de cabeceras del endpoint, **errores de CORS**. Esto es ruido continuo en consola pero, por sí solo, **no rompe la navegación**.

**T3 — Etapa 2 (se rompe la navegación / fallan los módulos).** El usuario navega a una ruta lazy. Aquí se bifurca según la causa:
- **Camino (a) — redeploy:** el navegador pide `/assets/View-<hashViejo>.js`. El host estático no lo encuentra y sirve el **fallback SPA = `index.html`** con **HTTP 200 + `text/html`**. Vite valida el tipo del módulo y lanza `Expected JavaScript module but received text/html` / `Failed to load module script`.
- **Camino (b) — HTTP/2 coalescing:** si API y estático comparten conexión HTTP/2 (mismo IP/cert wildcard tras el mismo proxy), el `GOAWAY`/reset que tumbó al SSE **invalida la conexión compartida**, y la petición del chunk falla a nivel de red → `Failed to fetch dynamically imported module`.

En ambos casos, **como no existe `router.onError` ni handler de `vite:preloadError`, la promesa de navegación se rechaza y no pasa nada más**: la vista destino no monta, el usuario ve la pantalla anterior "colgada" o en blanco, y cada intento posterior de navegar a una ruta no cargada aún vuelve a fallar. **Aquí es donde la SPA "se congela".**

**T4 — Etapa 3 (duplicar pestaña → todo en blanco).** Al duplicar, Chrome hace una navegación nueva a la misma URL y **reusa la caché HTTP** y el **pool de conexiones del mismo proceso**:
- Si `index.html` se sirve con caché agresiva/sin revalidación, la pestaña nueva **recibe el `index.html` viejo cacheado** → referencia chunks muertos → **falla incluso el chunk de entrada** → pantalla en blanco total.
- Si la conexión HTTP/2 coalescida sigue rota en el pool del proceso, la pestaña nueva la hereda.

**T5 — Solo un refresh completo lo arregla.** Un *hard refresh* (Ctrl+Shift+R) **evita la caché**: descarga el `index.html` fresco (nuevos hashes) y abre conexiones nuevas → la app revive. Un F5 normal a veces no basta si `index.html` no trae `no-cache`.

**Conclusión de la cronología:** la etapa 1 (SSE) y la etapa 2 (módulos) **coinciden en el tiempo pero no siempre son la misma cadena causal**. La etapa 2 tiene su propia causa dominante (chunks obsoletos por redeploy) que es **independiente** del SSE. El SSE contribuye solo en el sub-camino (b) del coalescing HTTP/2.

---

## 3. Identificación de la causa raíz

No se asume que el SSE sea la causa. Se evalúan todas las pistas del enunciado:

| Hipótesis | Probabilidad | Evidencia a favor | Evidencia en contra |
|---|---|---|---|
| **A. Redeploy del frontend con pestaña abierta → chunks obsoletos + fallback SPA sirve index.html** | **ALTA** | `Expected JavaScript module but received text/html`, `Failed to load module script`, "solo un refresh completo lo arregla", "duplicar pestaña → blanco". **No hay `router.onError`/`vite:preloadError`** (confirmado). Es la firma de libro de este problema. | Requiere que efectivamente haya habido un deploy en la ventana; confirmar con timestamps de deploy. |
| **B. Coalescing HTTP/2 API↔estático + GOAWAY/reset** | **MEDIA-ALTA** | `ERR_HTTP2_PROTOCOL_ERROR`, `Failed to fetch dynamically imported module` justo tras caer el SSE. Explica la correlación temporal. | No explica las respuestas `text/html`. Depende de topología de infra (mismo IP/cert). |
| **C. Tormenta de reconexión SSE** (`Infinity` + heartbeat + visibilitychange) | **MEDIA** (amplificador, no origen) | Config confirmada en `stores/notifications.ts`. Genera el ruido de etapa 1. | Degrada el SSE y el backend, pero por sí sola **no** produce `text/html` en chunks ni pantalla en blanco en pestaña nueva. |
| **D. Fuga de CORS en el endpoint SSE** (`*` manual llega a orígenes no permitidos) | **CONFIRMADA y CORREGIDA** — pero **NO** es la causa de los errores CORS observados | El endpoint añadía `Access-Control-Allow-Origin: *` a mano. Verificado con Starlette 0.46.2: para el origen **permitido** el middleware sobreescribe el `*` → **1 sola** cabecera correcta (sin duplicado); para un origen **NO permitido** el `*` manual **se filtra** (cualquier origen podía leer el SSE). | **Descartada como causa del freeze/CORS de los logs:** no hay cabecera duplicada; los "CORS error" son efecto colateral de las peticiones que fallan (HTTP/2 roto / respuesta de error del proxy sin CORS). Solo era un hueco de seguridad, ya cerrado. |
| **E. Expiración de sesión / token** | **BAJA** para este escenario | Existe refresh + `handleSessionExpired`. | Produciría **401 JSON**, no `200 text/html`. No calza con los logs de módulos. |
| **F. Service Worker / caché contaminada por SW** | **DESCARTADA** | No hay service worker en el repo (0 coincidencias). | — |
| **G. Bloqueo del event loop por el SSE** | **BAJA** | — | El SSE del cliente es I/O no bloqueante; no bloquea el hilo principal. |

**Veredicto:** la causa raíz del **congelamiento de la navegación** (lo que hace la app inutilizable) es **A (chunks obsoletos sin recuperación)**, agravada por la **ausencia de manejo de errores de import dinámico**. La cadena SSE (B/C/D) es un problema **real y paralelo** que produce el ruido de la etapa 1 y, vía coalescing (B), puede disparar la etapa 2 antes de tiempo, pero **no es el origen del blanco total ni del "solo refresh lo arregla"**.

---

## 4. Comportamiento de los imports dinámicos (por qué llegan como `text/html`)

- **Quién devuelve el HTML:** el **host/servidor de estáticos del frontend** (o el proxy que hace el fallback de SPA). Ante `/assets/Chunk-<hash>.js` inexistente, en lugar de responder **404**, aplica la regla de SPA *"todo lo no encontrado → `index.html`"* y devuelve `index.html` con **200 + `text/html`**.
- **No es** el CDN maliciosamente, ni un login, ni un redirect de auth: es simplemente el **catch-all de SPA mal alcanzado** que engloba también a `/assets/*`.
- **Por qué solo ocurre tras el fallo inicial (tras un rato):** porque el nombre viejo solo se vuelve inexistente **después de un redeploy**. Mientras no hay deploy, los hashes coinciden y todo carga. La "espera de horas" es simplemente el tiempo hasta que cae un deploy.
- **Por qué Vite lo rechaza:** los navegadores exigen `Content-Type` JS válido para `<script type="module">`/`import()`. Un `text/html` se rechaza con `Failed to load module script` / `Expected a JavaScript module script but the server responded with a MIME type of "text/html"`.
- **Variante de red (sin text/html):** cuando el mensaje es `Failed to fetch dynamically imported module` **sin** mención de MIME, el chunk **ni siquiera se descargó** (fallo de red: HTTP/2 roto). Es el camino (b).

Distinguir estas dos firmas en los logs es clave para atribuir cada línea a A vs. B.

---

## 5. Relación entre el SSE y el resto de la aplicación

- **¿Bloquea el event loop?** No. `fetchEventSource` es asíncrono; no congela el hilo principal.
- **¿Invalida tokens / modifica interceptores / altera estado global?** No directamente. El SSE lee el token de `localStorage` en cada `connect()`; no lo reescribe. No hay interceptor global compartido que el SSE pueda corromper.
- **¿Genera reconexiones infinitas?** **Sí (confirmado).** `maxReconnectAttempts = Infinity`, más heartbeat (reconecta a los 90 s sin eventos) más `visibilitychange` (reconecta al volver visible) más el auto-retry interno de la librería. Los tres pueden solaparse y no se coordinan.
- **¿Afecta la carga de nuevos módulos?** **Solo de forma indirecta y condicional** (hipótesis B): si el origen de la API y el de los estáticos **coalescen** sobre una misma conexión HTTP/2 (mismo IP + cert que cubre ambos hostnames), un `GOAWAY`/reset provocado por el SSE roto invalida esa conexión y las siguientes descargas de chunks fallan hasta que el navegador abre otra. Si los orígenes **no** coalescen, el SSE **no** afecta a los chunks y las etapas 1 y 2 son totalmente independientes.

**Acción de verificación (infra):** confirmar en producción si `VITE_API_BASE_URL` (API) y el host de `/assets/*` comparten IP y certificado (Traefik + `*.gopropflow.com`). Esto decide si B es real.

---

## 6. Manejo de errores globales — dónde puede quedar la app en estado irrecuperable

| Componente | Estado actual | Riesgo |
|---|---|---|
| **`router` (lazy imports)** | **Sin `router.onError`.** | **CRÍTICO.** Un import fallido rechaza la navegación y no hay recuperación → congelamiento. |
| **`main.ts` / bootstrap** | Sin listener `window` de `vite:preloadError` ni de `error`/`unhandledrejection`. | **CRÍTICO.** No hay red de seguridad para forzar recarga ante chunk faltante. |
| **`App.vue`** | Sin `errorCaptured` / error boundary. | ALTO. Un error de render no se contiene. |
| **Cliente SSE (`stores/notifications.ts`)** | `Infinity` + 3 disparadores de reconexión sin backoff coordinado. | ALTO. Tormenta de reconexión; ruido HTTP/2/CORS continuo. |
| **`api.config.ts` (401)** | `handleSessionExpired` con hard redirect, una vez por carga. | MEDIO. Correcto para 401, pero **inútil** ante el fallo real (200/text/html). |
| **Endpoint SSE backend (`sse_events.py`)** | ACAO `*` manual + CORSMiddleware global con credenciales. | **CORREGIDO.** No hay cabecera duplicada (Starlette la sobreescribe); el `*` solo se filtraba a orígenes no permitidos. Hueco de seguridad, no causa del freeze. |
| **Cache de `index.html`** | No verificado en infra; el síntoma de "duplicar pestaña" sugiere que se cachea sin `no-cache`. | ALTO. Perpetúa el uso del index viejo. |
| **Fallback SPA sobre `/assets/*`** | El catch-all devuelve index.html para chunks faltantes (200/text/html). | **CRÍTICO.** Debería devolver 404 para `/assets/*`. |

---

## 7. Comportamiento al duplicar pestañas

- **Por qué una pestaña nueva arranca rota:** no hereda el estado JS (Pinia arranca vacío), pero **sí** hereda: (1) la **caché HTTP** del navegador — si `index.html` viejo está cacheado, la nueva pestaña vuelve a cargar hashes muertos; (2) el **pool de conexiones HTTP/2 del proceso** — si la conexión coalescida está en estado roto, la reusa.
- **Qué estado comparte con la anterior:** **nada de JS**. Comparte **recursos de red/caché a nivel de navegador/proceso**, no de aplicación.
- **Qué queda "contaminado":** el `index.html` cacheado (apunta a chunks inexistentes) y, en su caso, la conexión HTTP/2.
- **Por qué solo un refresh completo recupera:** el *hard refresh* **invalida la caché y fuerza conexiones nuevas**, trayendo el `index.html` con los hashes vigentes.
- **Implicación diagnóstica (clave):** que una pestaña con **runtime JS nuevo** siga rota **demuestra que la causa NO es el estado global, el store ni el SSE en memoria** — es la **capa de artefactos/red**. Esto confirma la causa A y descarta E/G como origen.

---

## 8. Plan de solución definitivo (priorizado y justificado)

> Objetivo: eliminar el escenario por completo, no mitigarlo. Se ataca **la causa A** (recuperación de chunks + ciclo de deploy) como prioridad, y en paralelo se **sanea** el SSE (B/C/D).

### Bloque 1 — Recuperación ante imports dinámicos fallidos (resuelve la causa A a nivel cliente) — PRIORIDAD MÁXIMA

1. **`router/index.ts` — añadir `router.onError`** que detecte errores de carga de módulo dinámico (mensajes tipo `Failed to fetch dynamically imported module`, `Importing a module script failed`, `Expected a JavaScript module`) y, ante ellos, **fuerce un `window.location.assign(to.fullPath)`** (recarga dura hacia la ruta destino). Debe llevar un **guard anti-bucle** (p. ej. una marca en `sessionStorage` con timestamp) para no recargar en loop si el fallo persiste por otra causa.
2. **`main.ts` — añadir listener global `window.addEventListener('vite:preloadError', ...)`** que haga `event.preventDefault()` y recargue de forma controlada (mismo guard anti-bucle). Es la red de seguridad para preloads de Vite que no pasan por el router.
3. **Añadir un error boundary de UI** (`App.vue` con `onErrorCaptured`, o un componente wrapper) que, ante un fallo de carga de vista, muestre un estado "Nueva versión disponible — recargar" con botón, en lugar de pantalla en blanco. UX explícita > recarga silenciosa cuando el auto-reload no es seguro.

### Bloque 2 — Ciclo de deploy y caché (resuelve la causa A en su origen) — infraestructura

4. **Fallback SPA: excluir `/assets/*`.** El servidor de estáticos debe responder **404** (no `index.html`) para archivos hasheados inexistentes. Así el cliente recibe un error de red claro (manejado por el Bloque 1) en vez de un `text/html` engañoso.
5. **Cabeceras de caché correctas:**
   - `index.html` → `Cache-Control: no-cache` (revalidar siempre).
   - `/assets/*-<hash>.*` → `Cache-Control: public, max-age=31536000, immutable` (son inmutables por hash).
6. **(Opcional, robustez)** conservar N versiones anteriores de `/assets/` durante el despliegue (deploy azul/verde o retención de artefactos) para que las pestañas viejas sigan resolviendo sus chunks hasta que recarguen. Reduce la necesidad de recarga forzada.

### Bloque 3 — Saneamiento del SSE (resuelve C y D; mitiga B) — cliente + backend

7. **`stores/notifications.ts` — reconexión acotada y coordinada:**
   - Sustituir `Infinity` por un **tope** con **backoff exponencial + jitter** (p. ej. 1s→2s→4s…→máx 30s), y tras N fallos pasar a estado "desconectado" con reintento espaciado (p. ej. cada 60s) en vez de martilleo.
   - **Unificar los disparadores de reconexión** (auto-retry librería + heartbeat + visibilitychange) en **un solo coordinador** para que no se solapen conexiones.
   - Degradar con gracia: si el SSE no está disponible, la app **debe seguir 100% usable** (las estadísticas se refrescan por polling puntual o al navegar).
8. **`sse_events.py` — corregir CORS:** **eliminar** el `Access-Control-Allow-Origin: *` manual del `StreamingResponse` y dejar que el `CORSMiddleware` global sea la **única** fuente de cabeceras CORS. Verificado (Starlette 0.46.2): para el origen del frontend el comportamiento es **idéntico** antes y después (1 cabecera correcta), por lo que **no hay regresión**; el fix solo **cierra la fuga del `*` a orígenes no permitidos**. (No corrige los errores CORS de los logs, que son efecto colateral de las peticiones fallidas.)

### Bloque 4 — Topología HTTP/2 (confirma/elimina B) — infraestructura

9. **Verificar coalescing** API↔estáticos (mismo IP + cert). Si aplica y se quiere aislar, servir estáticos desde un origen/host separado o ajustar la config del proxy para que un `GOAWAY` del stream SSE no afecte a los estáticos. Revisar timeouts de conexión HTTP/2 de Traefik para SSE (idle/keep-alive) para reducir los `ERR_HTTP2_PROTOCOL_ERROR`.

### Orden de implementación recomendado (justificado)

1. **Bloque 1 (cliente: router.onError + vite:preloadError + boundary).** Da recuperación inmediata y detiene el congelamiento aunque el resto de la infra no cambie. Máximo impacto, mínimo riesgo, desplegable ya.
2. **Bloque 2 (fallback 404 en /assets + caché de index.html).** Elimina la causa raíz A en el origen; convierte los `text/html` en 404 limpios que el Bloque 1 ya sabe manejar.
3. **Bloque 3 (SSE cliente + CORS backend).** Apaga la tormenta de reconexión y el ruido CORS; reduce la superficie de B.
4. **Bloque 4 (HTTP/2).** Último, porque requiere validar topología y su beneficio depende de que B se confirme.

---

## 9. Riesgos

- **Bucle de recarga (Bloque 1):** si el auto-reload no lleva guard anti-bucle y el fallo persiste por otra causa (p. ej. 404 real de un chunk que nunca existió), la app recargaría en loop. **Mitigación:** marca en `sessionStorage` con ventana temporal (máx. 1 recarga por N segundos) y, agotada, mostrar el error boundary del Bloque 3/1.
- **Pérdida de estado no guardado al recargar:** un hard reload descarta formularios en curso. **Mitigación:** preferir el error boundary con botón "recargar" en vistas con edición; auto-reload silencioso solo en navegación limpia.
- **Cambio de fallback SPA (Bloque 2):** si alguna ruta real de la app vive bajo `/assets/`, devolver 404 la rompería. **Verificar** que `/assets/` sea exclusivo de build.
- **Corrección CORS (Bloque 3):** si algún cliente dependía del `*` (p. ej. un origen no listado en `settings.cors_origins`), dejaría de conectar. **Verificar** que todos los orígenes de front estén en `cors_origins`.
- **Backoff SSE (Bloque 3):** un backoff demasiado largo retrasa la llegada de notificaciones tras una caída breve. **Mitigación:** backoff con techo moderado (30s) + reconexión inmediata en `visibilitychange`.
- **Componentes afectados:** `router/index.ts`, `main.ts`, `App.vue`, `stores/notifications.ts`, `DashboardLayout.vue` (consumidor SSE), `sse_events.py`, y config de Traefik/host estático.

---

## 10. Plan de validación (para garantizar que no reaparece)

Cada escenario debe terminar en **app usable sin refresh manual** (salvo donde se indique recarga controlada automática).

1. **Pérdida temporal del SSE:** cortar la red del endpoint SSE 30–60 s y restaurar. Esperado: reconexión con backoff, sin tormenta, app usable todo el tiempo, notificaciones reanudan.
2. **Pérdida permanente del SSE:** bloquear el endpoint SSE indefinidamente. Esperado: tras N intentos pasa a reintento espaciado; **navegación y módulos 100% funcionales**; sin cascada de errores.
3. **Expiración de sesión:** forzar token expirado/invalid_grant. Esperado: redirección limpia a `/login` (una vez), sin blanco.
4. **Caída del backend:** apagar `app-saas-service`. Esperado: errores de API manejados; el SSE no tumba la SPA; al volver, recuperación.
5. **CORS del endpoint SSE (verificado):** con Starlette 0.46.2, origen permitido → **1 sola** cabecera `Access-Control-Allow-Origin` con el origen específico (igual antes y después del fix, sin regresión); origen NO permitido → **sin** cabecera (antes se filtraba `*`). Los errores CORS de los logs no dependen de esto (son efecto de peticiones fallidas).
6. **Cambio de versión del frontend (el caso central):** con la pestaña abierta, **desplegar una versión nueva**; luego navegar a una ruta lazy no cargada aún. Esperado: recuperación automática (recarga controlada hacia la ruta) o error boundary con botón; **nunca** pantalla en blanco muda. Repetir **duplicando la pestaña**: debe abrir con el index nuevo.
7. **Fallback de `/assets/`:** pedir manualmente `/assets/inexistente-<hash>.js`. Esperado: **404**, no `index.html`.
8. **Caché de `index.html`:** verificar `Cache-Control: no-cache` en `index.html` y `immutable` en `/assets/*`.
9. **Navegación entre módulos:** recorrer todas las rutas lazy tras un deploy simulado; ninguna debe quedar muerta.
10. **Duplicación de pestañas:** tras el escenario 6, duplicar; la nueva pestaña debe cargar sana.
11. **Múltiples horas abierta + deploy real:** dejar la app abierta durante y después de un ciclo de deploy productivo y ejercitar navegación. Esperado: recuperación automática.
12. **Recuperación sin recarga manual:** criterio transversal — en todos los anteriores, salvo la recarga controlada del escenario 6, no debe requerirse Ctrl+Shift+R del usuario.

---

## 11. Entregables (checklist del enunciado)

- [x] **1.** Diagnóstico de la solución anterior — §1.
- [x] **2.** Reconstrucción cronológica con los nuevos logs — §2.
- [x] **3.** Identificación de la causa raíz — §3 (A principal; B/C/D paralelos; D confirmado en código).
- [x] **4.** Explicación técnica de todos los errores y su relación — §2, §4, §5.
- [x] **5.** Debilidades de la implementación actual — §1.4, §6.
- [x] **6.** Plan de solución definitivo, priorizado y justificado — §8.
- [x] **7.** Archivos/módulos probablemente a modificar (sin implementar) — §6 y §9:
  - `app-saas-frontend/src/router/index.ts` (`router.onError`)
  - `app-saas-frontend/src/main.ts` (`vite:preloadError`, handlers globales)
  - `app-saas-frontend/src/App.vue` (error boundary)
  - `app-saas-frontend/src/stores/notifications.ts` (reconexión acotada + backoff + coordinación)
  - `app-saas-service/app/api/v1/sse_events.py` (quitar ACAO manual)
  - Config Traefik / host estático (fallback 404 en `/assets/*`, cache-control, HTTP/2)
- [x] **8.** Plan de validación — §10.

---

## 12. Notas para el implementador (fase siguiente)

- **Confirmar con evidencia externa** antes de codificar: (a) timestamps de deploy del frontend vs. hora de los logs (valida A); (b) topología IP/cert de API vs. estáticos (valida/elimina B); (c) inspección en Network de una respuesta de chunk fallida para ver si es `200 text/html` (A) o fallo de red (B/D).
- **Este documento asume** que los logs adjuntos corresponden a las tres etapas descritas; las firmas de mensaje citadas se mapean 1:1 con esas etapas. Si algún log muestra `401` en la carga de chunks (no observado en la descripción), reabrir la hipótesis E.
- **Regla de oro de la solución:** *el SSE es un lujo; la navegación es un derecho.* Ninguna falla de notificaciones debe poder inhabilitar la SPA, y toda falla de artefactos debe auto-recuperarse o pedir recarga explícita — nunca dejar pantalla en blanco muda.
