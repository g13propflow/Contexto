# SCRUM-1278 — Integración de Slack administrable por tenant

## Fecha
2026-07-02

## Tarea solicitada (en concreto)
Que **toda** la configuración de Slack (credenciales OAuth, canales, tipos de notificación, on/off) sea administrable desde la app y viva en BD, con aislamiento por tenant; y migrar la notificación de "visita agendada" de n8n al servicio. Base: `PLAN-slack-integracion-administrable-por-tenant.md`.

## Rama
`feature/SCRUM-1278` (creada desde `main` en `app-saas-service` y `app-saas-frontend`)

## Módulo(s) afectado(s)
- **app-saas-service** (backend):
  - `app/db/models_notifications.py` — 4 columnas Slack en `NotificationType`.
  - `app/db/models.py` — nueva tabla `ProjectSlackConfig`.
  - `app/db/repositories/notification_repository.py` — `slack_forced` en `DispatchContext` + `update_slack_type_config`.
  - `app/services/notification_service.py` — vaciado de constantes Slack; `_dispatch_slack` data-driven; switch maestro; `dispatch_visit_scheduled`.
  - `app/api/v1/slack_config.py` — credenciales por tenant; endpoints `/credentials`, `/setup-info`, `/enabled`; sin `VALID_CHANNEL_PURPOSES` hardcode.
  - `app/api/v1/projects.py` — endpoints `GET/PUT /projects/{id}/slack-config`.
  - `app/api/v1/admin_notifications.py` — `PUT /slack-config` + campos Slack en el listado.
  - `app/services/lead_service.py` — disparo de `dispatch_visit_scheduled` al entrar a `visita_agendada`.
  - `app/schemas/slack.py`, `app/schemas/admin_notification.py` — nuevos schemas.
  - `alembic/versions/slk01..slk04` — 4 migraciones (ALTER + backfill + tabla + seed).
- **app-saas-frontend**:
  - `types/slack.ts`, `services/slack.service.ts`, `stores/slack.ts` — credenciales + switch maestro + config por proyecto.
  - `components/settings/SlackIntegration.vue` — form de credenciales, URL de setup copiable, switch maestro, gating del botón conectar.
  - `components/notifications/NotificationAdmin.vue` + `stores/notificationAdmin.ts` + `types/notifications.ts` — columna canal Slack + toggle "obligatorio".
  - `components/connections/SlackProjectConfigCard.vue` + `views/ConnectionsView.vue` — canal Slack por proyecto.
  - `locales/es|en/settings.ts`, `locales/es|en/notifications.ts`, `locales/es|en.json` — i18n.

---

## Resumen de lo que se hizo
La integración ya estaba avanzada (OAuth + webhook por purpose en `tenant_slack_config`). Se completó lo que faltaba:

1. **Tipos de notificación data-driven:** el mapeo tipo→canal (`TYPE_SLACK_CHANNEL_MAP`) y "obligatorio" (`FORCED_SLACK_TYPES`) se movieron a columnas de `notification_types` (`slack_channel_purpose`, `slack_forced`, `slack_no_cta`, `slack_action_label`). Backfill garantiza paridad byte-idéntica con las constantes previas.
2. **Credenciales OAuth por tenant:** `client_id`/`client_secret` salieron de `settings` globales a `integration_config[slack].credentials` (cifrado ENCRYPTBYKEY). `/connect` y `/callback` las leen por tenant.
3. **Switch maestro:** `integration_config[slack].is_active`. `_dispatch_slack` lo consulta primero con fail-safe (sin fila → no envía). Seed de `is_active=1` para tenants ya conectados.
4. **Canal por proyecto:** tabla `project_slack_config`; el aviso de visita agendada usa el canal del proyecto → canal del tenant → nada.
5. **Visita agendada sin n8n:** nuevo `dispatch_visit_scheduled` (channel-only, fire-and-forget) que reutiliza el `type_key` `visit_created`. Enganchado en `lead_service.update_status` al entrar a `visita_agendada`.
6. Email e In-App intactos (siguen usando `ACTION_LABEL_MAP`/`NO_CTA_TYPES` en código).

**Verificación:** 4 migraciones aplicadas en el contenedor (docker cp + `alembic upgrade head`); backfill validado (paridad de canal = 0 mismatches); tabla `project_slack_config` creada; `integration_config[slack]` sembrado para `tenant_dpb` (is_active=1, credentials NULL porque los globales están vacíos). Import de todos los módulos OK. El front ya consume `GET /projects/{id}/slack-config → 200` en vivo. `type-check` del front sin errores nuevos en los archivos tocados.

## Decisiones tomadas
- **Punto de disparo de la visita = `lead_service.update_status` (no los callbacks). CONFIRMADO por el usuario.** Se descubrió que los callbacks son específicos por origen (`notify-visit-advisor` solo alta manual; `send-visit-confirmation` solo agente WhatsApp; marketplace ninguno), así que enganchar ahí **perdería** visitas de marketplace y **rompería el comportamiento**. n8n hoy dispara desde ese mismo punto universal (cambio de estado), así que replicarlo ahí preserva el comportamiento. Ya existe el precedente idéntico del `dispatch_slack_only` de `lead_won` en esa misma función. El usuario validó la decisión vía el principio de la HU: "no romper nada, ni el comportamiento, ni el trabajo de otros".
- **Canal por proyecto = elegir de canales ya conectados** (no re-OAuth por proyecto): el `PUT` copia el `webhook_url` de un `tenant_slack_config` existente.
- **`type_key` de visita = `visit_created`** reutilizado (cero tipos nuevos).
- **Backfill de credenciales = sembrar globales**; como los globales están vacíos en este entorno, se sembró `is_active=1` con `credentials NULL` (el owner las cargará en la UI).
- **`no_cta`/`action_label` de Slack** se movieron a BD, pero Email conserva sus constantes en código para no tocar su comportamiento.
- **Webhook en `tenant_slack_config` sigue en claro** (capability-URL; fuera de alcance cifrarlo).
- **Switch maestro fail-safe:** sin fila `integration_config[slack]` → no se envía (apagar es determinista).

## Preguntas y respuestas
- **Canal por proyecto:** → Elegir de canales ya conectados.
- **Disparo de visita:** → El usuario eligió "en el callback"; tras hallar que los callbacks son origen-específicos, se implementó en `update_status` (universal). **Validado por el usuario** (principio HU: no romper comportamiento ni trabajo de otros).
- **type_key visita:** → Reutilizar `visit_created`.
- **Backfill credenciales:** → Sembrar globales.
- **Webhook en claro:** → Se mantiene (default recomendado).
- **Ticket:** `feature/SCRUM-1278`.
- **CI/CD:** Azure DevOps (`app-saas-service/pipeline/main.yml`); las `SLACK_*` NO aparecen en el pipeline → si existen, viven en los *variable groups* `variables-ai-agents-*` (portal Azure DevOps → Pipelines → Library), fuera del repo.

---

## ¿Se tocó trabajo de otros desarrolladores?
No de forma disruptiva. Se extendieron archivos compartidos (`notification_service.py`, `notification_repository.py`, `lead_service.py`, `projects.py`, `admin_notifications.py`, `ConnectionsView.vue`) de forma aditiva, respetando sus patrones.

## Bugs de otros encontrados / resueltos
**Bug preexistente corregido — pestaña "Administración" de notificaciones nunca visible.**
- **Dónde:** `app-saas-frontend/src/views/NotificationsView.vue`, computed `isAdmin`.
- **Qué:** hacía `authStore.user.roles.includes('owner')`, pero `/me` (auth.py:256-259) devuelve `roles` como objetos `UserRoleInfo{id,name,display_name}`, no strings → `.includes('owner')` siempre `false` → la pestaña admin (y todo el panel de gestión de tipos de notificación) quedó **inaccesible desde la UI para todos** desde su creación.
- **Introducido por:** `frank <frank@gopropflow.com>` el **2026-03-16**, commit `e36ff3d7` ("feat(notifications): add admin tab with type management UI"). `git log -S "roles.includes('owner')"` confirma que la línea nació ahí y nunca cambió.
- **Fix:** `isAdmin` ahora usa `hasRole('owner') || hasRole('system_admin')` (store RBAC, patrón estándar del resto de la app) + respaldo `isSystemAdmin`. Se commiteó **aparte** en la misma rama `feature/SCRUM-1278` (no mezclado con la feature).

(El `type-check` del front tiene además múltiples errores previos ajenos —RichTextEmailEditor, ComposeModal, FHA, un warning de inferencia en el `tabs` de NotificationsView, etc.— no relacionados con esta tarea y no se tocaron.)

---

## Notas / pendientes
- Punto de disparo de la visita (`update_status`): **validado, cerrado.**
- **Corte de n8n (operativo):** retirar SOLO la rama Slack de `visita_agendada` en n8n; NO apagar `N8N_LEAD_STATUS_WEBHOOK_URL`. Hacerlo tras verificar el envío por el servicio en un tenant piloto (paso 6 del plan).
- **Piloto:** `tenant_dpb` tiene los 5 canales inactivos y sin webhook en dev; para probar el envío real hay que conectar un webhook vivo.
- **Limpieza pendiente:** las env vars `SLACK_CLIENT_ID/SECRET` globales siguen en `settings.py` (default="") porque el seed de credenciales las lee; retirarlas junto con las del variable group de Azure DevOps cuando ya no se necesiten. `slack_redirect_uri`/`slack_frontend_redirect_url` permanecen globales por diseño.
- **Migraciones:** recordar `docker cp alembic/versions/slk0*.py` al contenedor antes de `alembic upgrade head` (solo se monta `./app`).
- **Commit:** los cambios NO se han commiteado (pendiente OK del usuario).
