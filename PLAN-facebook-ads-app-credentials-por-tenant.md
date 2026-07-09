# Plan — Credenciales de Facebook App por tenant (Meta Ads)

> HU: mover `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` de variables globales del servicio a credenciales **por tenant** en BD, para que cada tenant conecte Meta Ads con su propia Facebook App.
> Repos afectados: `app-saas-service` (backend) + `app-saas-frontend` (UI).
> Patrón de referencia: **Meta Messaging** (`TenantMetaMessagingConfig` + `meta_messaging_config.py`).

---

## 1. Resumen ejecutivo

Hoy los 3 puntos que usan credenciales de la Facebook App leen `settings.facebook_app_id` / `settings.facebook_app_secret` (globales, compartidas por todos los tenants):

| Punto | Archivo | Usa |
|---|---|---|
| Construir OAuth URL (`/connect`) | `app/api/v1/facebook_oauth.py:44-58` | `app_id` |
| Intercambio `code → token` (`/callback`) | `app/api/v1/facebook_oauth.py:82-114` | `app_id` + `app_secret` |
| Refresh de token long-lived | `app/services/facebook_ads_service.py:238-250` | `app_id` + `app_secret` |

El **token OAuth resultante** ya se guarda por tenant en `integration_config` (`platform_name="facebook_ads"`), cifrado con **Fernet** en escritura (`encryption_service.encrypt`, `integration_config_repository.py:99,241` — desde PROPFLOW-910; las filas legacy `ENCRYPTBYKEY` se leen vía la vista `vw_integration_config_decrypted` y migran a Fernet al re-guardarse). Solo falta que **`app_id` y `app_secret`** también vivan por tenant.

### Decisión de arquitectura (confirmada en revisión)
- `app_id` y `app_secret` se guardan **dentro del JSON `credentials`** de `integration_config` (junto a `access_token`, `ad_account_id`, `ad_account_name`).
- El blob `credentials` **ya se cifra completo** al escribir (hoy con **Fernet** de aplicación, no `ENCRYPTBYKEY` — PROPFLOW-910) → `app_secret` queda cifrado automáticamente con el mecanismo existente. **No se crean columnas ni tablas nuevas → cero migraciones Alembic**, ventaja operativa clave dado el drift actual de la BD Azure (revisión `slk04` fuera de `main` + DDL manual de `facebook_ad_insights.level`).
- `FACEBOOK_REDIRECT_URI` y `FACEBOOK_FRONTEND_REDIRECT_URL` **permanecen** como env vars globales (dependen del dominio del servicio, no del tenant).

### ⚠️ Trampas técnicas identificadas
1. **Merge del JSON:** `integration_config_repository.update()` **reemplaza** el blob completo cuando se le pasa `credentials` no vacío (re-cifra Fernet, línea 240-251; `""`/`None` preservan el secreto — D-35). Nunca hace merge. → Siempre **leer el JSON descifrado, actualizar las claves, y reescribir el JSON completo** antes de llamar `update`. El patrón ya existe en `/ad-account` (`facebook_oauth.py:322-337`) y en `refresh_tenant_facebook_token` (`activities_facebook_insights.py:108-128`). **El `/callback` hoy NO hace merge** (reescribe solo `{access_token, ad_account_id, ad_account_name}`, `facebook_oauth.py:154-158`) → si no se corrige, cada reconexión OAuth **borraría `app_id`/`app_secret`**. Centralizar en un helper puro `merge_credentials()` + tests de regresión de preservación.
2. **`expires_at`:** el `update` aplica semántica `exclude_unset` sobre `data` (clave presente con `None` → limpia a NULL; clave ausente → no se toca; docstring líneas 217-224). Al registrar app credentials (sin token todavía) simplemente **no incluir `expires_at` en `data`**.
3. **`create` exige `credentials`:** para registrar app credentials cuando aún no existe fila, se crea con un JSON que solo tiene `{app_id, app_secret}` e `is_active=False` (aún no conectado).
4. **`get_credentials()` (service, línea 45)** exige `access_token` **y** `ad_account_id`, devuelve `None` si falta alguno. Registrar solo app credentials NO habilita insights — correcto, pero el `status` debe distinguir "credenciales registradas" de "conectado".
5. **`/callback` no tiene auth header** (es un redirect de Facebook): el `tenant_id` sale del parámetro `state` (`facebook_oauth.py:73`). Ahí hay que leer las app credentials del tenant vía `db` + `tenant_id`, no vía `get_current_tenant`. Si el tenant no tiene app creds al llegar el callback (caso borde) → `RedirectResponse(...?facebook=error&reason=app_credentials_missing)`.
6. **`GET /status` reporta `is_connected=True` con solo existir la fila** (`facebook_oauth.py:209-234`). Con el nuevo diseño la fila puede existir con solo `{app_id, app_secret}` y sin conexión → cambiar a `is_connected = bool(creds.get("access_token"))`.
7. **`DELETE /` hace soft-delete de la fila completa** (`facebook_oauth.py:354-368`) → al desconectar se perderían también `app_id`/`app_secret`. Rediseñar: merge-write que remueve `access_token`/`ad_account_id`/`ad_account_name`, setea `is_active=False`, y **preserva las app credentials** (desconectar ≠ desconfigurar la app). Soft-delete solo si la fila no tiene app creds.

---

## 2. Alcance backend (`app-saas-service`)

### 2.1 Nueva capa de acceso a app credentials
Crear helper (en `facebook_ads_service.py` o repo) que, dado `db` + `tenant_id`:
- Lea el `integration_config` de `facebook_ads`, parsee el JSON `credentials`, devuelva `(app_id, app_secret)` o `None`.
- Helper de **merge**: recibe el JSON actual + dict de cambios → devuelve JSON fusionado para reescribir.

### 2.2 Endpoint: registrar app credentials
`POST /integrations/facebook/app-credentials` (en `facebook_oauth.py`, mismo prefix `/integrations/facebook`)
- Body: `{ app_id: str, app_secret: str }` (Pydantic, `min_length=1`).
- Lógica: upsert del registro `facebook_ads`:
  - Si existe → leer JSON, **merge** `app_id`/`app_secret`, reescribir (sin tocar `expires_at`).
  - Si no existe → `create` con JSON `{app_id, app_secret}`, `is_active=False`.
- Respuesta: sin devolver `app_secret` (solo `app_id` + booleano `configured`).

### 2.3 Endpoint: exponer URLs de setup (solo lectura)
`GET /integrations/facebook/setup-info`
- Respuesta: `{ redirect_uri: settings.facebook_redirect_uri, frontend_redirect_url: settings.facebook_frontend_redirect_url }`.
- Sin secretos; solo lectura.

### 2.4 Endpoint: estado de configuración (extender `/status`)
Extender `FacebookStatusResponse` para incluir `has_app_credentials: bool` (y opcional `app_id` para mostrar en UI). Así el frontend sabe si habilitar el botón "Conectar". Además, **corregir `is_connected`**: debe basarse en la presencia de `access_token` en el JSON, no en la existencia de la fila (trampa 6).

### 2.5 Leer app credentials del tenant en el flujo OAuth
- **`/connect`** (`facebook_oauth.py:36`): recibir `db`, leer `app_id` del tenant. Si no hay → `HTTP 400` con detalle **"Facebook App credentials not configured for this tenant"**. Usar ese `app_id` en `client_id`.
- **`/callback`** (`facebook_oauth.py:62`): leer `app_id` + `app_secret` del tenant (vía `tenant_id` del `state`) para ambos intercambios (short-lived y long-lived). Al hacer upsert del token, **merge** en el JSON (preservar `app_id`/`app_secret`, no sobrescribirlos).
- **`DELETE /`** (`facebook_oauth.py:354`): cambiar el soft-delete de la fila por un merge-write que quita `access_token`/`ad_account_*` y setea `is_active=False`, preservando las app credentials (trampa 7).

### 2.6 Refresh de token
- **`refresh_long_lived_token()`** (`facebook_ads_service.py:226`): cambiar firma para recibir las credenciales del tenant. **Recomendado:** `refresh_long_lived_token(current_token, app_id, app_secret)` (mantiene el service sin dependencia de BD).
- **Llamador** `refresh_tenant_facebook_token` (`activities_facebook_insights.py:116`): ya carga el `config` del tenant; extraer `app_id`/`app_secret` del JSON y pasarlos. Si faltan → status `no_app_credentials`.

### 2.7 Limpieza de env vars
- Eliminar `facebook_app_id` y `facebook_app_secret` de `config/settings.py:104-105`.
- Actualizar el comentario obsoleto de `settings.py:109` ("Meta Messaging reusa facebook_app_id/secret" — ya no aplica).
- Eliminar `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` del pipeline CI/CD. **Hallazgo (verificado en git):** el pipeline del repo es `pipeline/main.yml` (Azure DevOps) y **no contiene** referencias a `FACEBOOK_*`; tampoco `docker-compose.yml`, `.env` local, docs ni contracts. Las variables solo existen como configuración del entorno de producción (Azure). Retirarlas es un **paso operativo del usuario post-deploy**, después del backfill (§2.8).
- **Mantener** `facebook_redirect_uri` y `facebook_frontend_redirect_url`.

### 2.8 Migración de datos (tenants ya conectados) — **DECISIÓN: A) Backfill**
Tenants con `facebook_ads` ya conectado tienen JSON sin `app_id`/`app_secret`. Sin ellos, el **refresh fallará** al vencer el token (un token long-lived solo se refresca con la app que lo emitió).

**Decisión (2026-07-03): backfill.** Razón: no interrumpe el refresh diario ni el sync de insights (cada 6 h) de los tenants activos; forzar reconexión rompería silenciosamente todas las conexiones al primer vencimiento. Cada tenant migra a su propia app cuando quiera: guarda sus credenciales y re-conecta (re-OAuth).

Implementación: script one-time **idempotente** `scripts/backfill_facebook_app_credentials.py` que lee `FACEBOOK_APP_ID`/`FACEBOOK_APP_SECRET` del entorno (aún presentes en prod en ese momento) e inyecta las 2 keys en el JSON de cada `integration_config` `facebook_ads` activo **solo si faltan** (merge, nunca sobrescribe). Orden de corte: deploy código → ejecutar backfill dentro del contenedor de prod → retirar las vars de Azure. En local no aplica (las vars no existen y no hay conexiones).

---

## 3. Alcance frontend (`app-saas-frontend`)

Estado actual: `ConnectionsView.vue` solo tiene botón "Conectar" (OAuth) + selector de ad account. **No existe** panel de captura de app credentials para Facebook Ads (a diferencia de HubSpot/Pipedrive). Referencia de UI de captura: `components/settings/MetaMessagingIntegration.vue`.

### 3.1 Servicio y endpoints
- `src/services/api.config.ts`: agregar `FACEBOOK_APP_CREDENTIALS` (`/integrations/facebook/app-credentials`) y `FACEBOOK_SETUP_INFO` (`/integrations/facebook/setup-info`).
- `src/services/connections.service.ts`: métodos `saveFacebookAppCredentials(appId, appSecret)`, `getFacebookSetupInfo()`. Extender `FacebookStatus` con `has_app_credentials`.

### 3.2 UI en la card de Facebook Ads (`ConnectionsView.vue`)
- **Formulario** para `app_id` + `app_secret` (secret tipo password, no se re-muestra tras guardar).
- **Bloque de URLs de setup** (`redirect_uri`, `frontend_redirect_url`) como campos **solo lectura con botón copiar** + instrucción:
  > "Registra las siguientes URLs en tu Facebook App (Meta Developer Portal) en la sección Facebook Login → Valid OAuth Redirect URIs antes de conectar tu cuenta:"
- **Gating:** deshabilitar el botón "Conectar" hasta que `has_app_credentials === true`.
- i18n: nuevas claves bajo `connections.facebook.*` (es + en).

---

## 4. Orden de implementación sugerido

1. **Backend — persistencia y lectura**
   1.1 Helpers de lectura/merge de app credentials en el JSON.
   1.2 `POST /app-credentials` + `GET /setup-info` + extender `/status`.
   1.3 Adaptar `/connect`, `/callback`, `refresh_long_lived_token` + su activity.
2. **Migración de datos**: script de backfill idempotente (decisión §2.8/§5) — se ejecuta en prod antes de retirar las env vars.
3. **Limpieza de env vars** (`settings.py` + CI/CD).
4. **Frontend** — service + UI (formulario, URLs copiables, gating).
5. **Verificación multitenant** (§6).

> Nota: no se levantan servidores ni se hacen commits sin autorización explícita (política del proyecto). El backend corre en Docker.

---

## 5. Decisiones tomadas (2026-07-03, delegadas por el usuario)

1. **Estrategia de migración (§2.8): A) Backfill** — script one-time idempotente antes de retirar las vars de Azure. No interrumpe a los tenants conectados; migran a su propia app a su ritmo (guardar creds + re-OAuth).
2. **CI/CD — resuelto:** el pipeline `pipeline/main.yml` (Azure DevOps) no contiene `FACEBOOK_*`; las vars viven solo en el entorno de producción (Azure). Retirarlas: paso operativo del usuario post-deploy + backfill.
3. **Validación al registrar app credentials:** validación de formato (`app_id` numérico, ambos no vacíos) + verificación **best-effort** contra Graph API usando el app access token `{app_id}|{app_secret}` (`GET /app`): si Meta responde error de credenciales → 400 con mensaje claro; si es error de red/timeout → se guarda igual (mismo criterio best-effort que usa Meta Messaging en `/setup`). La validación definitiva sigue siendo el propio OAuth.
4. **`app_secret` en la UI:** **nunca** se devuelve al frontend — ni enmascarado. Solo `app_id` + `has_app_credentials` (patrón Meta Messaging: omitir el secreto en responses).
5. **Copy e idiomas:** se usa el texto de la HU ("Registra las siguientes URLs en tu Facebook App (Meta Developer Portal) dentro de Facebook Login → Valid OAuth Redirect URIs antes de conectar tu cuenta") en **es + en**, siguiendo el estilo de keys existente en `connections.facebook.*`.
6. **Ticket:** **SCRUM-1279** (prefijo de commits: `feat(SCRUM-1279): ...`).
7. **Diseño del panel:** sin mockup; se sigue el estilo de las cards de Connections y el formulario de `MetaMessagingIntegration.vue`.

---

## 5-bis. Estrategia de ramas — **DECISIÓN: `feature/SCRUM-1279` desde `main`** (ambos repos)

Verificado en git (2026-07-03):
- `feature/SCRUM-1278` (Slack) y `feature/SCRUM-1287` (eliminación Metabase, checkout actual en ambos repos) parten **ambas de `main` de forma independiente** (ninguna es ancestro de la otra).
- SCRUM-1278 **no toca ningún archivo del flujo Facebook Ads** en backend (`facebook_oauth.py`, `facebook_ads_service.py`, `activities_facebook_insights.py`, `schemas/facebook_oauth.py` — intactos).

Razones para partir de `main` y no de `feature/SCRUM-1278`:
1. Funcionalmente independientes: nada del código de Slack es prerequisito de esto.
2. Partir de 1278 encadenaría el PR: no podría mergearse hasta que Slack mergee, y arrastraría al diff las 4 migraciones `slk01-slk04` y todo Slack (revisión sucia).
3. PRs independientes = deploys y rollbacks independientes.

**Conflictos esperados al mergear el segundo** (pequeños y localizados, se resuelven en el merge):
- Frontend vs SCRUM-1278: `src/views/ConnectionsView.vue`, `src/locales/es.json`, `src/locales/en.json` (Slack agrega su card/keys; esto agrega las de Facebook).
- Backend vs SCRUM-1287: `config/settings.py` (Metabase elimina campos; esto elimina `facebook_app_id/secret`).

Nota operativa: ambos working trees están hoy en `feature/SCRUM-1287` — antes de empezar: `git checkout main && git pull && git checkout -b feature/SCRUM-1279` en cada repo.

---

## 6. Criterios de aceptación → verificación

| Criterio | Cómo se verifica |
|---|---|
| `FACEBOOK_APP_ID/SECRET` ya no existen como env/settings globales | grep en `settings.py` + CI/CD; app arranca sin ellas |
| Tenant registra `app_id`/`app_secret` desde configuraciones | `POST /app-credentials` persiste en JSON cifrado |
| OAuth usa credenciales del tenant desde BD | `/connect` y `/callback` leen del JSON, no de settings |
| Refresh usa credenciales del tenant | `refresh_long_lived_token` recibe app creds del tenant |
| Error claro sin credenciales | `/connect` → 400 "Facebook App credentials not configured for this tenant" |
| URLs de setup visibles, solo lectura, con copiar | `GET /setup-info` + UI |
| Meta Messaging intacto | grep confirma que no usa las globales (docstring obsoleto en webhook) |
| Multitenant aislado | Tenant A y B con Apps distintas conectan y sincronizan de forma independiente |

## 7. Fuera de alcance
- Cambios a Meta Messaging (ya multitenant).
- Nuevas funcionalidades de Facebook Ads más allá de la migración de credenciales.

---

## Anexo — Archivos afectados (mapa rápido)

**Backend**
- `app/api/v1/facebook_oauth.py` — `/connect`, `/callback`, `/status`, + nuevos `/app-credentials`, `/setup-info`
- `app/services/facebook_ads_service.py` — `refresh_long_lived_token` (firma), helper de lectura/merge
- `app/temporal/activities_facebook_insights.py` — `refresh_tenant_facebook_token` (pasar app creds)
- `app/schemas/facebook_oauth.py` — nuevos request/response models
- `config/settings.py` — quitar `facebook_app_id`/`secret`, actualizar comentario
- `app/db/repositories/integration_config_repository.py` — (sin cambios; se reutiliza, cuidando el merge)
- `scripts/backfill_facebook_app_credentials.py` — one-time, idempotente (§2.8)
- CI/CD — quitar vars

**Frontend**
- `src/services/api.config.ts` — endpoints nuevos
- `src/services/connections.service.ts` — métodos nuevos + tipo `FacebookStatus`
- `src/views/ConnectionsView.vue` — formulario app creds + URLs copiables + gating
- `src/locales/*` — claves i18n `connections.facebook.*`
