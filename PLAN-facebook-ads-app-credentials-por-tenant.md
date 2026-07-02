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

El **token OAuth resultante** ya se guarda por tenant en `integration_config` (`platform_name="facebook_ads"`), cifrado con `ENCRYPTBYKEY`. Solo falta que **`app_id` y `app_secret`** también vivan por tenant.

### Decisión de arquitectura (confirmada en revisión)
- `app_id` y `app_secret` se guardan **dentro del JSON `credentials`** de `integration_config` (junto a `access_token`, `ad_account_id`, `ad_account_name`).
- El blob `credentials` **ya se cifra completo con `ENCRYPTBYKEY`** → `app_secret` queda cifrado automáticamente. **No se crean columnas nuevas ni se usa Fernet.** (Difiere de Meta Messaging, que sí usa columnas + Fernet; la HU lo indica explícitamente para mantener consistencia con `integration_config`.)
- `FACEBOOK_REDIRECT_URI` y `FACEBOOK_FRONTEND_REDIRECT_URL` **permanecen** como env vars globales (dependen del dominio del servicio, no del tenant).

### ⚠️ Trampas técnicas identificadas
1. **Merge del JSON:** `integration_config_repository.update()` **reemplaza** el blob completo cuando se le pasa `credentials` (`ENCRYPTBYKEY(...)`, línea 195). Nunca hace merge. → Siempre **leer el JSON descifrado, actualizar las claves, y reescribir el JSON completo** antes de llamar `update`. El patrón ya existe en `/ad-account` (`facebook_oauth.py:321-334`) y en `refresh_tenant_facebook_token` (`activities_facebook_insights.py:108-128`).
2. **`expires_at`:** el `update` usa `COALESCE(:expires_at, expires_at)`. Pasar `None` **preserva** el valor existente. Al registrar app credentials (sin token todavía) no se debe tocar `expires_at`.
3. **`create` exige `credentials`:** para registrar app credentials cuando aún no existe fila, se crea con un JSON que solo tiene `{app_id, app_secret}` e `is_active=False` (aún no conectado).
4. **`get_credentials()` (service, línea 45)** exige `access_token` **y** `ad_account_id`, devuelve `None` si falta alguno. Registrar solo app credentials NO habilita insights — correcto, pero el `status` debe distinguir "credenciales registradas" de "conectado".
5. **`/callback` no tiene auth header** (es un redirect de Facebook): el `tenant_id` sale del parámetro `state` (`facebook_oauth.py:73`). Ahí hay que leer las app credentials del tenant vía `db` + `tenant_id`, no vía `get_current_tenant`.

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
Extender `FacebookStatusResponse` para incluir `has_app_credentials: bool` (y opcional `app_id` para mostrar en UI). Así el frontend sabe si habilitar el botón "Conectar".

### 2.5 Leer app credentials del tenant en el flujo OAuth
- **`/connect`** (`facebook_oauth.py:36`): recibir `db`, leer `app_id` del tenant. Si no hay → `HTTP 400` con detalle **"Facebook App credentials not configured for this tenant"**. Usar ese `app_id` en `client_id`.
- **`/callback`** (`facebook_oauth.py:62`): leer `app_id` + `app_secret` del tenant (vía `tenant_id` del `state`) para ambos intercambios (short-lived y long-lived). Al hacer upsert del token, **merge** en el JSON (preservar `app_id`/`app_secret`, no sobrescribirlos).

### 2.6 Refresh de token
- **`refresh_long_lived_token()`** (`facebook_ads_service.py:226`): cambiar firma para recibir las credenciales del tenant. **Recomendado:** `refresh_long_lived_token(current_token, app_id, app_secret)` (mantiene el service sin dependencia de BD).
- **Llamador** `refresh_tenant_facebook_token` (`activities_facebook_insights.py:116`): ya carga el `config` del tenant; extraer `app_id`/`app_secret` del JSON y pasarlos. Si faltan → status `no_app_credentials`.

### 2.7 Limpieza de env vars
- Eliminar `facebook_app_id` y `facebook_app_secret` de `config/settings.py:104-105`.
- Actualizar el comentario obsoleto de `settings.py:109` ("Meta Messaging reusa facebook_app_id/secret" — ya no aplica).
- Eliminar `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` del pipeline CI/CD **(requiere insumo: ubicación del pipeline)**.
- **Mantener** `facebook_redirect_uri` y `facebook_frontend_redirect_url`.

### 2.8 Migración de datos (tenants ya conectados) — **requiere decisión (ver §5)**
Tenants con `facebook_ads` ya conectado tienen JSON sin `app_id`/`app_secret`. Sin ellos, el **refresh fallará** al vencer el token. Dos estrategias:
- **A) Backfill (recomendada):** script one-time que inyecta los valores globales actuales de `FACEBOOK_APP_ID`/`SECRET` dentro del JSON de cada `facebook_ads` existente, **antes** de borrar las globales. Preserva conexiones activas.
- **B) Forzar reconexión:** no backfill; los tenants deben registrar su app y reconectar. Más limpio pero interrumpe.

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
2. **Migración de datos** (backfill o no, según decisión §5) — antes de tocar env vars.
3. **Limpieza de env vars** (`settings.py` + CI/CD).
4. **Frontend** — service + UI (formulario, URLs copiables, gating).
5. **Verificación multitenant** (§6).

> Nota: no se levantan servidores ni se hacen commits sin autorización explícita (política del proyecto). El backend corre en Docker.

---

## 5. Insumos que necesito de tu parte

1. **Estrategia de migración (§2.8):** ¿Backfill de las credenciales globales actuales a los tenants ya conectados (A, recomendada), o forzar reconexión (B)?
   - Si A: confirmar que `FACEBOOK_APP_ID`/`SECRET` globales actuales siguen siendo válidas y **qué tenants** las usan hoy (¿todos los `facebook_ads` activos?).
2. **Ubicación del pipeline CI/CD** donde se inyectan `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` (GitHub Actions, Azure DevOps, docker-compose de prod, secrets de Traefik/host…). No tengo visibilidad de esa config.
3. **Validación al registrar app credentials:** ¿validamos algo contra Meta al guardar (formato de `app_id`, o un ping a Graph API), o solo persistimos y dejamos que el error real aparezca en el OAuth? (Meta Messaging valida el token real; para Ads la validación natural es el propio OAuth.)
4. **Manejo de `app_secret` en la UI:** confirmar que **nunca** se devuelve al frontend (solo se muestra `app_id` + estado "configurado"). Es lo recomendado y lo que hace Meta Messaging.
5. **Texto e idiomas:** ¿confirmas el copy de la instrucción del portal y que se necesita en **es + en**? ¿Algún wording exacto que marketing/producto quiera?
6. **Número de ticket SCRUM** para el prefijo del commit (la HU no lo trae).
7. **Diseño/mockup del panel** o libertad para implementarlo siguiendo el estilo de `MetaMessagingIntegration.vue` / las cards existentes de Connections.

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
- Script/migración de backfill (si aplica) — one-time
- CI/CD — quitar vars

**Frontend**
- `src/services/api.config.ts` — endpoints nuevos
- `src/services/connections.service.ts` — métodos nuevos + tipo `FacebookStatus`
- `src/views/ConnectionsView.vue` — formulario app creds + URLs copiables + gating
- `src/locales/*` — claves i18n `connections.facebook.*`
