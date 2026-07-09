# SCRUM-1279 — Credenciales de Facebook App por tenant (Meta Ads)

## Fecha
2026-07-03

## Tarea solicitada (en concreto)
Migrar las credenciales del flujo OAuth de Facebook Ads de variables globales
(`FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET`, compartidas por todos los tenants)
a credenciales **por tenant** administrables desde el módulo de conexiones,
aplicando el mismo concepto que Meta Messaging. Adicionalmente, mostrar al
tenant las URLs que debe registrar en el Meta Developer Portal (solo lectura,
con botón de copiar). `FACEBOOK_REDIRECT_URI` y `FACEBOOK_FRONTEND_REDIRECT_URL`
permanecen como variables de infraestructura del servicio.

Análisis previo: `Projects/PLAN-facebook-ads-app-credentials-por-tenant.md`.

## Rama
`feature/SCRUM-1279` en ambos repos, desde `main` (pendiente de commit por el usuario).

## Módulos afectados
- `app-saas-service` — integración Facebook Ads (OAuth, refresh Temporal, settings)
- `app-saas-frontend` — vista Conexiones (card Facebook Ads)

---

## Decisión de arquitectura
`app_id`/`app_secret` se guardan **dentro del JSON `credentials`** de
`integration_config` (`platform_name="facebook_ads"`), junto al `access_token`
que ya vivía ahí. El blob completo se cifra con el mecanismo existente (Fernet,
`integration_config_repository`). **Cero migraciones Alembic** (decisión clave
por el drift activo de la BD Azure). Toda escritura del JSON pasa por un helper
puro de merge para que ninguna clave pise a las demás.

## Backend — archivos modificados/creados

1. `app/services/facebook_ads_service.py`
   - Nuevos helpers puros: `parse_credentials()` (parseo tolerante a `\x00`
     legacy, centraliza lo que estaba triplicado) y `merge_credentials()`
     (merge del JSON; `None` elimina la clave). Single source of truth de
     todos los puntos de escritura.
   - `get_app_credentials(db, tenant_id)` — lee `(app_id, app_secret)` del
     tenant; a diferencia de `get_credentials` no exige `is_active` (las app
     creds se registran antes de conectar).
   - `refresh_long_lived_token(current_token, app_id, app_secret)` — firma
     nueva; ya no usa `settings`.

2. `app/api/v1/facebook_oauth.py`
   - **Nuevo** `POST /integrations/facebook/app-credentials` — upsert con merge
     (preserva `access_token`); crea la fila con `is_active=False` si no existe;
     valida el par contra Graph API con app access token `{app_id}|{app_secret}`
     (best-effort: error de red no bloquea, error de credenciales → 400).
     Nunca devuelve el secret.
   - **Nuevo** `GET /integrations/facebook/setup-info` — expone
     `facebook_redirect_uri` y `facebook_frontend_redirect_url` (solo lectura).
   - `GET /connect` — usa el `app_id` del tenant; sin credenciales → 400
     "Facebook App credentials not configured for this tenant".
   - `GET /callback` — lee `app_id`/`app_secret` del tenant (vía `state`);
     sin ellas → redirect `?facebook=error&reason=app_credentials_missing`.
     El write del token ahora es **merge** (antes reemplazaba el JSON completo
     y habría borrado las app creds en cada reconexión).
   - `GET /status` — `is_connected` ahora depende de la presencia de
     `access_token` (antes bastaba que existiera la fila); agrega
     `has_app_credentials` y `app_id` a la respuesta.
   - `DELETE /` — desconectar quita `access_token`/`ad_account_*` y pone
     `is_active=False` **preservando** las app creds (antes soft-eliminaba la
     fila completa). Si la fila no tiene app creds, se mantiene el soft-delete.
   - `PUT /ad-account` — refactor a los helpers (mismo comportamiento).

3. `app/schemas/facebook_oauth.py`
   - Nuevos: `FacebookAppCredentialsRequest` (app_id numérico + secret, con
     strip), `FacebookAppCredentialsResponse`, `FacebookSetupInfoResponse`.
   - `FacebookStatusResponse` + `has_app_credentials` + `app_id`.

4. `app/temporal/activities_facebook_insights.py`
   - `refresh_tenant_facebook_token`: extrae `app_id`/`app_secret` del mismo
     JSON y los pasa al refresh; si faltan → status `app_credentials_missing`
     (degradado limpio, sin crash). **Workflows y schedules sin cambios.**

5. `config/settings.py`
   - Eliminados `facebook_app_id` y `facebook_app_secret`. Quedan solo las 2
     URLs. Corregido el comentario engañoso de Meta Messaging ("reusa
     facebook_app_id/secret" — nunca fue cierto: usa su propia tabla).

6. `app/api/v1/meta_messaging_webhook.py`
   - Solo docstring: la firma HMAC se valida con el app_secret del tenant.

7. **Nuevo** `scripts/backfill_facebook_app_credentials.py`
   - One-time idempotente: inyecta las credenciales globales (leídas de
     `os.environ`, no de settings) en el JSON de cada `facebook_ads` que no
     tenga las suyas. `--dry-run` y `--tenant`. Debe correrse en prod ANTES de
     retirar las vars de Azure (un token solo se refresca con la app emisora).

8. **Nuevo** `tests/unit/facebook_app_credentials/test_credentials_merge.py`
   - 13 tests de regresión de `parse_credentials`/`merge_credentials`:
     guardar app creds preserva el token, la reconexión OAuth preserva las app
     creds, el disconnect conserva la app, tolerancia a `\x00`/JSON inválido.

## Frontend — archivos modificados

1. `src/services/api.config.ts` — endpoints `FACEBOOK_APP_CREDENTIALS` y
   `FACEBOOK_SETUP_INFO`.
2. `src/services/connections.service.ts` — `saveFacebookAppCredentials()`,
   `getFacebookSetupInfo()`; tipos `FacebookAppCredentials`, `FacebookSetupInfo`;
   `FacebookStatus` + `has_app_credentials` + `app_id`.
3. `src/views/ConnectionsView.vue`
   - Card Facebook Ads: estado "Configura tu Facebook App" (ámbar) cuando
     faltan credenciales; botón "Configurar App" siempre visible; botón
     "Conectar" deshabilitado (con tooltip) hasta tener app creds.
   - **Nuevo modal "Configurar Facebook App"**: instrucción del Meta Developer
     Portal + las 2 URLs de solo lectura con `CopyButton` (patrón de
     WhatsAppIntegration) + form `app_id` (pre-rellenado si existe) y
     `app_secret` (`type="password"`, nunca pre-rellenado — patrón Meta
     Messaging). Error del backend visible en el modal.
   - `connectFacebook()` con guard: sin app creds abre el modal de configuración.
   - `disconnectFacebook()` ahora recarga el status desde backend (las app
     creds sobreviven a la desconexión).
4. `src/locales/es.json` / `en.json` — 15 claves nuevas bajo `connections.facebook.*`.

## Verificación realizada
- Backend: 13/13 tests unitarios PASSED (pytest dentro del contenedor api);
  sintaxis y `import` de todos los módulos editados OK en el contenedor; las 8
  rutas del router registradas (incluidas las 2 nuevas); grep confirma **cero**
  referencias restantes a `facebook_app_id`/`facebook_app_secret`.
- Frontend: `npm run type-check` — 0 errores en los archivos tocados (los 31
  reportados son preexistentes en `main`); `es.json`/`en.json` parsean OK.
- **Pendiente**: verificación E2E en navegador (requiere recrear el contenedor
  api para servir los endpoints nuevos: `docker compose up -d --force-recreate api`).

## Pasos operativos (usuario, al desplegar)
1. Deploy del código.
2. `python scripts/backfill_facebook_app_credentials.py --dry-run` y luego sin
   `--dry-run` dentro del contenedor de prod (con las vars aún presentes).
3. Retirar `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` del entorno de Azure.
4. Los tenants migran a su propia app cuando quieran: Configurar App → re-conectar.
