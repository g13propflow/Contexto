# Análisis técnico — Integración de Slack administrable por tenant

> HU: que **toda** la configuración de Slack (OAuth, canales, tipos de notificación, on/off) sea administrable desde la app y viva en BD, con aislamiento por tenant; y migrar la notificación de "visita agendada" de n8n al servicio.
> Repos afectados: `app-saas-service` (backend) + `app-saas-frontend` (UI). `calendar-service` **no** contiene lógica de Slack ni de n8n.
> Patrón de referencia para credenciales por tenant: `integration_config` (HubSpot/Pipedrive/Facebook Ads) — coherente con [`PLAN-facebook-ads-app-credentials-por-tenant.md`].
> **Este documento es solo análisis y diseño. No se ha modificado código.**

---

## 0. TL;DR — qué ya existe y qué falta

La integración de Slack **ya está bastante avanzada**. Lo que la HU pide es sobre todo *terminar de mover a BD* lo que hoy está en constantes de código, *añadir la dimensión proyecto*, y *cortar la dependencia de n8n para visitas*.

| # | Requerimiento HU | Estado hoy | Gap real |
|---|---|---|---|
| 1 | Visita agendada sin n8n, enviada por el servicio | Hoy va por n8n (webhook genérico de cambio de estado) | Crear dispatch propio fire-and-forget + retirar el workflow n8n |
| 2 | Canal por proyecto inmobiliario | No existe `project_id` en Slack | Tabla `project_slack_config` + resolución con fallback |
| 3 | Tipos de notificación dinámicos (canal / habilitado / obligatorio) | Habilitado ya vive en BD (`notification_types.default_channels`); **canal y "obligatorio" están hardcodeados** | Migrar `TYPE_SLACK_CHANNEL_MAP` + `FORCED_SLACK_TYPES` a columnas en `notification_types` |
| 4 | Activar/desactivar toda la integración | Solo hay on/off por canal (`TenantSlackConfig.is_active`) | Switch maestro por tenant (fila `integration_config` platform="slack") |
| 5 | OAuth con credenciales por tenant | `client_id`/`client_secret` son **globales** (`settings`) | Mover a `integration_config` cifrado por tenant |
| 6 | Limpieza técnica | — | Retirar constantes migradas, env vars obsoletas, workflow n8n |

**Restricciones respetadas:** no se crean nuevos `type_key`; no se toca Email ni In-App; se reutiliza infraestructura existente.

---

## 1. Arquitectura actual

### 1.1 Componentes de la integración Slack

```
Frontend (Settings → tab "slack")
  SlackIntegration.vue ── slack.service.ts ──► /integrations/slack/{connect,callback,status,test,DELETE}
                                                        │
                                          app/api/v1/slack_config.py  (OAuth v2, scope "incoming-webhook")
                                                        │  guarda webhook por (tenant, purpose)
                                                        ▼
                                          tenant_slack_config  (models_notifications.py:30)

Sistema de notificaciones (envío)
  NotificationService (singleton, notification_service.py)
     _dispatch_from_context ──► in_app (SSE) · email (SendGrid) · slack (_dispatch_slack)
                                                              │
                          TYPE_SLACK_CHANNEL_MAP (HARDCODE)  ─┘ resuelve channel_purpose
                                                              ▼
                          busca tenant_slack_config por purpose → POST httpx al webhook
```

**Archivos núcleo (rutas verificadas):**
- OAuth + status/test/disconnect: `app/api/v1/slack_config.py`
- Modelo webhook por tenant: `app/db/models_notifications.py:30` (`TenantSlackConfig`)
- Envío: `app/services/notification_service.py` — `_dispatch_slack` (`:547`), `dispatch_slack_only` (`:284`)
- Schemas: `app/schemas/slack.py`
- Frontend: `src/components/settings/SlackIntegration.vue`, `src/stores/slack.ts`, `src/services/slack.service.ts`, `src/types/slack.ts`, tab en `src/views/SettingsView.vue:2526`
- Migraciones: `eb203c05a0b2_add_tenant_slack_config.py`, `2f0cf73c995d_add_channel_purpose_to_slack_config.py`

### 1.2 OAuth actual (todo en `slack_config.py`)

- `GET /integrations/slack/connect?channel_purpose=…` construye la URL de autorización de Slack. `state = "{tenant_id}:{channel_purpose}:{nonce}"`. Usa `settings.slack_client_id`, `settings.slack_redirect_uri`. Scope único: `incoming-webhook`.
- `GET /integrations/slack/callback` intercambia `code` en `https://slack.com/api/oauth.v2.access` con `settings.slack_client_id` + `settings.slack_client_secret`, extrae `incoming_webhook.url`, y hace **upsert** en `tenant_slack_config` por `(tenant_id, channel_purpose)`. El tenant sale del `state` (el callback no tiene auth header).
- `/status`, `/test`, `DELETE /` gestionan/prueban/borran los canales.

**Lo que persiste = un Incoming Webhook URL** (columna `webhook_url`, **en claro**). No hay bot token, ni signing secret, ni verificación de firma (no se reciben eventos entrantes de Slack, solo salida).

**Credenciales OAuth = globales del servicio** (`config/settings.py:97-101`):
```python
slack_client_id / slack_client_secret / slack_redirect_uri / slack_frontend_redirect_url
```
Si `slack_client_id` está vacío, `/connect` responde `503`.

### 1.3 Envío de notificaciones — dónde está el hardcode

`NotificationService` (canal central; **no Celery, todo asyncio + Temporal**). Canales: `in_app` (fila + SSE), `email` (SendGrid), `slack` (webhook httpx).

El **mapeo tipo→canal Slack está 100% en código** (`notification_service.py`):

| Constante | Línea | Qué decide | ¿A dónde migra? |
|---|---|---|---|
| `TYPE_SLACK_CHANNEL_MAP` | `:55` | `type_key` → `channel_purpose` | **`notification_types.slack_channel_purpose`** |
| `FORCED_SLACK_TYPES` | `:69` | tipos "obligatorios" (ignoran preferencia usuario) | **`notification_types.slack_forced`** |
| `POSTVENTA_SLACK_TYPES` | `:36` | subconjunto que va a `#postventa` | se disuelve dentro de `slack_channel_purpose` |
| `NO_CTA_TYPES` | `:75` | tipos sin botón | opcional: `notification_types.slack_no_cta` |
| `ACTION_LABEL_MAP` | `:81` | etiqueta del botón | opcional: `notification_types.slack_action_label` |
| `VALID_CHANNEL_PURPOSES` | `slack_config.py:25` | set válido de purposes | se vuelve dinámico (los purposes existentes son los que el tenant conectó) |
| `ENTITY_ROUTE_MAP` / `TYPE_ROUTE_MAP` | `:27` / `:46` | deep-link | **fuera de alcance** (presentación; no lo pide la HU) |

**Lo que YA es data-driven (no tocar su naturaleza):**
- `notification_types` (por tenant): `type_key`, `label`, `category`, **`default_channels` JSON `{in_app, email, slack}`**, `is_user_configurable`, `is_active`. → "qué tipos existen" y "cuáles están habilitados" **ya viven en BD**.
- `notification_preferences` (por usuario): override por `(user, type, channel)`.
- `resolve_channels` (`notification_repository.py:330`) combina default del admin + preferencia del usuario.

### 1.4 Flujo actual de "visita agendada" y n8n

- `calendar-service` crea el evento (`POST /api/events`) y dispara callbacks a `app-saas-service` con `X-API-Key`:
  - `send-visit-confirmation/{lead_id}` → `leads.py:5204` (WhatsApp al lead). **Sin Slack.**
  - `notify-visit-advisor` → `tour_scheduled.py:480` (email/WhatsApp al asesor). **Sin Slack.**
  - `tour-rescheduled` → `tour_scheduled.py:419`.
- El aviso a **Slack** de visita agendada **NO sale del código**: cuando el lead pasa a `visita_agendada`, `lead_service.update_status` (`lead_service.py:439`) dispara el **webhook genérico** `N8N_LEAD_STATUS_WEBHOOK_URL` (evento `lead_status_changed`, para **cualquier** cambio de estado), y **es el workflow de n8n quien postea a Slack**.

> ⚠️ **Trampa clave:** ese webhook n8n es **compartido** por todas las automatizaciones de cambio de estado (Pipedrive, Zapier, etc.). "Eliminar el workflow n8n" = eliminar **solo el nodo/rama de Slack para `visita_agendada`** dentro de n8n, **no** apagar `N8N_LEAD_STATUS_WEBHOOK_URL` ni el `notify_status_change`. Ver §7 y §10.

### 1.5 Mecanismos de persistencia por tenant disponibles

| Patrón | Cifrado | Ejemplos | Uso recomendado aquí |
|---|---|---|---|
| **A. `integration_config`** (fila por `tenant_id`+`platform_name`, JSON `credentials` cifrado con `ENCRYPTBYKEY` + view descifrada) | SQL Server symmetric key | HubSpot, Pipedrive, Facebook Ads | **Credenciales OAuth + switch maestro de Slack** |
| **B. Tabla dedicada + Fernet** (`encrypt_api_key`/`decrypt_api_key`, `app/core/encryption.py`) | Fernet (app) | Meta Messaging, SAP, WhatsApp | alternativa |
| **C. `TenantSlackConfig`** (ya existe, webhook en claro) | ninguno | Slack (actual) | **Webhooks por purpose (se mantiene)** |
| **D. Config por proyecto** (`project_zapier_config`, `project_webhook_config`) | — / view | Zapier, Webhooks | **plantilla para canal por proyecto** |

---

## 2. Arquitectura propuesta

Principio rector: **extender lo existente, no reemplazarlo.** Se mantiene el modelo "webhook por purpose" y el pipeline de `NotificationService`; se añaden 3 piezas y se vacían las constantes.

```
┌─ Credenciales + switch maestro (NUEVO uso) ────────────────────┐
│ integration_config  platform_name="slack"                      │
│   credentials(JSON cifrado) = {client_id, client_secret}       │
│   is_active = switch maestro on/off de TODA la integración     │
└────────────────────────────────────────────────────────────────┘
        │ /connect y /callback leen client_id/secret de aquí (por tenant)
        ▼
┌─ Canales por purpose (EXISTE, se mantiene) ────────────────────┐
│ tenant_slack_config  (tenant_id, channel_purpose, webhook_url) │
└────────────────────────────────────────────────────────────────┘
        │
┌─ Canal por proyecto (NUEVO) ───────────────────────────────────┐
│ project_slack_config (tenant_id, project_id, webhook_url…)     │
│   override SOLO para visita agendada                            │
└────────────────────────────────────────────────────────────────┘

┌─ Mapeo dinámico tipo→canal (columnas NUEVAS en tabla EXISTENTE)┐
│ notification_types + slack_channel_purpose, slack_forced,      │
│                      (opc.) slack_no_cta, slack_action_label   │
└────────────────────────────────────────────────────────────────┘

NotificationService._dispatch_slack:
  0) master switch (integration_config.is_active) → si off, return
  1) channel_purpose ← notification_types.slack_channel_purpose (BD, no constante)
  2) si es visita agendada y hay project_id → project_slack_config primero
  3) fallback: tenant_slack_config[purpose] → tenant_slack_config["general"] → no enviar
```

### 2.1 Decisiones de diseño (y por qué)

1. **Credenciales OAuth en `integration_config` (patrón A), no en columnas de `TenantSlackConfig`.**
   `client_id`/`client_secret` son **globales del tenant** (una Slack App por tenant), mientras que `TenantSlackConfig` tiene **N filas por tenant** (una por purpose) → ahí no encajan. `integration_config` da además el JSON cifrado y el `is_active` que sirve de **switch maestro** (req 4). Es exactamente el patrón que eligió el plan de Facebook Ads → consistencia.

2. **Switch maestro = `integration_config(platform="slack").is_active`.** Un solo lugar apaga todo. `_dispatch_slack` lo consulta primero. Se reutiliza `IntegrationConfigService.activate/deactivate` (`integration_config.py:172-198`). No se inventa tabla nueva de flags.

3. **Mapeo tipo→canal a columnas de `notification_types`, no tabla nueva.** `notification_types` ya es la fuente por-tenant de "qué tipos existen / habilitado", ya tiene API admin (`admin_notifications.py`, rol `owner`) y UI (`NotificationAdmin.vue`). Añadir `slack_channel_purpose` + `slack_forced` ahí = mínima superficie y máxima reutilización. Evita una tabla `type_channel_mapping` paralela que duplicaría la relación tenant↔type.

4. **Canal por proyecto = tabla dedicada `project_slack_config` (patrón D).** Igual que `project_zapier_config`. No se mete `project_id` en `tenant_slack_config` para no complicar su semántica `(tenant, purpose)` ni las 4 rutas que ya la consultan. Aplica **solo a visita agendada** (lo dice la HU).

5. **Reutilizar `type_key` existente para visita agendada — NO crear tipo nuevo.** La HU prohíbe nuevos tipos. Se reutiliza el `type_key` seed **`visit_created`** (ya existe), fijando su `slack_channel_purpose` al canal de visitas. La notificación de visita se envía **channel-only** (como `dispatch_slack_only`) para **no** crear in-app/email nuevos y no violar la restricción de no tocar esos canales. → **decisión a confirmar en §11 (Q1)** por el matiz semántico de `visit_created`.

6. **`redirect_uri` y `frontend_redirect_url` permanecen globales.** Dependen del dominio del servicio, no del tenant (idéntico al plan de Facebook Ads).

7. **Webhook en `tenant_slack_config` sigue en claro.** Es un incoming-webhook URL (capability-URL), no un secreto tipo password, y ya está así en producción. Cifrarlo sería un cambio de mayor alcance sin pedido explícito. Los **secretos reales nuevos** (`client_secret`) sí van cifrados (en `integration_config`). *(Endurecerlo = mejora opcional fuera de alcance, ver §11 Q4.)*

---

## 3. Componentes afectados

### Backend `app-saas-service`
| Archivo | Cambio |
|---|---|
| `app/db/models.py` | + `ProjectSlackConfig` (y, si se usa view, `ProjectSlackConfigDecrypted`) |
| `app/db/models_notifications.py` | + columnas en `NotificationType`: `slack_channel_purpose`, `slack_forced`, (opc.) `slack_no_cta`, `slack_action_label` |
| `app/services/notification_service.py` | Vaciar `TYPE_SLACK_CHANNEL_MAP`/`FORCED_SLACK_TYPES`/`POSTVENTA_SLACK_TYPES`/`NO_CTA_TYPES`/`ACTION_LABEL_MAP`; `_dispatch_slack` lee de BD; + resolución con master switch y project override; + método `dispatch_visit_scheduled` (channel-only, fire-and-forget) |
| `app/api/v1/slack_config.py` | `/connect` y `/callback` leen `client_id`/`client_secret` del tenant (integration_config); error 400 claro si faltan; quitar `VALID_CHANNEL_PURPOSES` hardcode; + endpoints `POST /credentials`, `GET /setup-info`, `PATCH /enabled` (switch maestro) |
| `app/api/v1/projects.py` | + endpoints `GET/PUT /projects/{id}/slack-config` (plantilla: `reservation-config`, `projects.py:1466`) |
| `app/api/v1/admin_notifications.py` | exponer/editar `slack_channel_purpose` + `slack_forced` en el CRUD de tipos |
| `app/services/lead_service.py` | disparar `dispatch_visit_scheduled` cuando el lead entra a `visita_agendada` (o en el callback de visita, ver §5) |
| `app/schemas/slack.py`, `app/schemas/project.py`, `app/schemas/notification_schemas.py` | nuevos request/response |
| `config/settings.py` | quitar `slack_client_id`/`slack_client_secret` globales; mantener `slack_redirect_uri`/`slack_frontend_redirect_url` |
| `alembic/versions/` | 2–3 migraciones (ver §6). ⚠️ recordar `docker cp versions/` al contenedor (memoria `alembic-container-not-mounted`) |

### Frontend `app-saas-frontend`
| Archivo | Cambio |
|---|---|
| `src/components/settings/SlackIntegration.vue` | formulario `client_id`/`client_secret`, bloque URLs de setup copiables, gating del botón "Conectar", switch maestro on/off |
| `src/services/slack.service.ts`, `src/stores/slack.ts`, `src/types/slack.ts` | nuevos métodos/tipos (`saveCredentials`, `getSetupInfo`, `setEnabled`) |
| Config de proyecto (vista de edición de Project) | selector/asignación de canal Slack del proyecto |
| `src/components/notifications/NotificationAdmin.vue` | columna canal Slack + toggle "obligatorio" por tipo |
| `src/locales/es|en/settings.ts` | i18n |

### n8n (externo)
- Retirar la rama/nodo que postea a Slack para `new_status == "visita_agendada"`. **No** apagar el webhook completo.

### `calendar-service`
- **Sin cambios** (no tiene Slack ni n8n). El origen de la visita ya llega vía callbacks existentes.

---

## 4. Modelo de datos propuesto

### 4.1 `notification_types` (ALTER — columnas aditivas, nullable/con default)
```python
# app/db/models_notifications.py :: NotificationType
slack_channel_purpose: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
slack_forced:          Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="0")
# opcionales (para vaciar NO_CTA_TYPES / ACTION_LABEL_MAP):
slack_no_cta:          Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="0")
slack_action_label:    Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
```
- `slack_channel_purpose = NULL` ⇒ comportamiento actual de fallback `"general"`.
- Aditivo ⇒ el resto del sistema (in-app/email) no cambia.

### 4.2 `project_slack_config` (NUEVA — patrón `project_zapier_config`)
```python
class ProjectSlackConfig(Base):
    __tablename__ = "project_slack_config"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    tenant_id: Mapped[str] = mapped_column(String(100), nullable=False, index=True)
    project_id: Mapped[int] = mapped_column(ForeignKey("projects.id", ondelete="CASCADE"), nullable=False)
    webhook_url: Mapped[str] = mapped_column(String(500), nullable=False)
    channel_name: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    channel_id:   Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default="1")
    created_at / updated_at ...
    __table_args__ = (Index("uq_project_slack_config_tenant_project", "tenant_id", "project_id", unique=True),)
```
> El `webhook_url` del proyecto se obtiene reutilizando el mismo flujo OAuth (nuevo purpose de "state" que incluye `project_id`) o seleccionando un canal ya conectado. Decisión de UX en §11 Q2.

### 4.3 `integration_config` platform="slack" (SIN cambios de esquema; nuevo uso)
```
credentials (JSON cifrado ENCRYPTBYKEY) = {"client_id": "...", "client_secret": "..."}
is_active = switch maestro on/off de la integración Slack del tenant
```
Reutiliza `IntegrationConfigService` y el repo con `ENCRYPTBYKEY`/view (`integration_config_repository.py`). ⚠️ **misma trampa que FB Ads:** `update()` reemplaza el blob completo → leer JSON, merge, reescribir.

---

## 5. Flujo completo de notificaciones (propuesto)

### 5.1 Visita agendada (el cambio grande)
```
calendar-service crea evento
   └─► callback a app-saas-service (send-visit-confirmation / notify-visit-advisor)
         │   [punto de disparo — ver Q3 §11]
         ▼
   notification_service.dispatch_visit_scheduled(tenant_id, project_id, lead, event…)  ← fire-and-forget
         0) integration_config[slack].is_active? no → return          (switch maestro)
         1) resolver canal:
              a) project_slack_config(tenant, project_id).webhook_url   (si existe y activo)
              b) tenant_slack_config[purpose de "visit_created"]         (canal general del tenant)
              c) → no enviar
         2) POST httpx al webhook (nunca lanza)   — sin crear in-app/email
```
- `asyncio.create_task(...)` para no bloquear el flujo principal (patrón ya usado en `hitl_service`/`notify_followers_bg`).
- Reutiliza `type_key = "visit_created"` (sin tipo nuevo).
- n8n deja de postear Slack para visitas.

### 5.2 Resto de notificaciones Slack (mismo pipeline, ahora data-driven)
```
NotificationService.dispatch*/notify_followers/dispatch_slack_only
   └─► _dispatch_from_context → resolve_channels (default_channels + preferencia usuario)
         └─ channels["slack"] o slack_forced(BD) ►
              _dispatch_slack:
                0) master switch → si off, return
                1) purpose = notification_types.slack_channel_purpose (BD)  [antes: TYPE_SLACK_CHANNEL_MAP]
                2) tenant_slack_config[purpose] → fallback "general" → none
                3) botón/label desde slack_no_cta/slack_action_label (BD)  [antes: NO_CTA_TYPES/ACTION_LABEL_MAP]
```

---

## 6. Migraciones (Alembic)

1. **ALTER `notification_types`** + columnas Slack (aditivas, con `server_default`).
2. **Data migration (backfill de compatibilidad) — crítica:** para **cada tenant** y cada fila existente de `notification_types`, poblar:
   - `slack_channel_purpose` según el actual `TYPE_SLACK_CHANNEL_MAP` (incluye los `POSTVENTA_SLACK_TYPES → "postventa"`).
   - `slack_forced = True` para `advisor_daily_summary`, `advisor_performance_alert` (actual `FORCED_SLACK_TYPES`).
   - (si se migran) `slack_no_cta` y `slack_action_label` según los dicts actuales.
   → **Garantiza comportamiento idéntico** post-deploy.
3. **CREATE `project_slack_config`** (+ índice único `(tenant_id, project_id)`).
4. **Credenciales OAuth por tenant:** *no* requiere DDL (usa `integration_config` existente). Sí requiere **backfill opcional**: sembrar `{client_id, client_secret}` globales actuales en `integration_config[slack]` de cada tenant que hoy usa Slack, **antes** de borrar las env vars globales (ver §8 y §11 Q5).

> Recordatorio operativo: el `docker-compose` de `app-saas-service` monta solo `./app`; para correr migraciones nuevas hay que `docker cp` de `alembic/versions/` al contenedor (memoria del proyecto).

---

## 7. Riesgos

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Apagar el webhook n8n completo por error rompe Pipedrive/Zapier/otras automatizaciones (comparten `N8N_LEAD_STATUS_WEBHOOK_URL`) | **Alta** | Retirar **solo** la rama Slack de `visita_agendada` en n8n; no tocar `notify_status_change` |
| Doble notificación durante la transición (n8n aún activo + servicio ya enviando) | Media | Coordinar corte: desplegar servicio → verificar → luego retirar rama n8n. O feature-flag de corte |
| `visit_created` tiene semántica de "tarea de visita", reutilizarlo para el Slack de visita agendada puede confundir | Media | Confirmar en Q1; alternativa: mapear a otro `type_key` existente que encaje |
| Trampa de merge en `integration_config.update()` (reemplaza blob) pierde `client_id`/`secret` | Media | Leer→merge→reescribir (patrón ya existente en FB Ads) |
| Callback OAuth sin auth: `tenant_id` viene del `state` no validado (CSRF) | Baja/Media | Al mover credenciales por tenant, validar que el tenant del state tenga integración activa; opcional: firmar/expirar el nonce |
| Backfill de credenciales incompleto → `/connect` 400 para tenants ya conectados | Media | Backfill antes de borrar globales; `/status` expone `has_credentials` para diagnóstico |
| Purpose dinámico sin `VALID_CHANNEL_PURPOSES` permite valores basura | Baja | Validar contra el set de purposes que el tenant realmente conectó (o catálogo mínimo) |

---

## 8. Compatibilidad con tenants existentes

- **Tipos de notificación:** el backfill (§6.2) copia los mapas de código a BD → **comportamiento byte-idéntico**. `slack_channel_purpose = NULL` mantiene el fallback a `"general"`.
- **Webhooks ya conectados:** `tenant_slack_config` no cambia de esquema ni de datos.
- **Switch maestro:** al crear la fila `integration_config[slack]` para tenants con Slack ya conectado, sembrar `is_active = True` para no apagarlos.
- **OAuth:** backfill de `{client_id, client_secret}` globales → tenants siguen conectando sin fricción. Sin backfill, un tenant ya conectado sigue **recibiendo** (usa su webhook), pero **no podría re-conectar** hasta registrar credenciales.
- **Email / In-App:** intactos (cambios solo aditivos y en la rama Slack).

---

## 9. Estrategia de migración (orden de corte)

1. **BD + backfill de tipos** (migraciones §6.1–6.2). Sin cambio de comportamiento observable.
2. **Credenciales por tenant** en `integration_config` + endpoints; **backfill** de globales; UI de credenciales. `/connect`/`/callback` leen de BD.
3. **Switch maestro** (endpoint + UI) leyendo `integration_config.is_active`.
4. **Canal por proyecto** (`project_slack_config` + endpoints + UI).
5. **Dispatch de visita agendada** en el servicio (`dispatch_visit_scheduled`), **con la rama n8n aún activa** para comparar.
6. **Verificar** que el servicio envía correctamente (canal proyecto → general → none) en staging/1 tenant piloto.
7. **Retirar la rama Slack de visita** en n8n.
8. **Limpieza** (§ siguiente): vaciar constantes, borrar env vars globales, retirar código muerto.

---

## 10. Estrategia para evitar regresiones

- **Backfill = paridad exacta:** tras la migración, un test comparativo (script en scratchpad, no en repo) que para cada tenant verifique `notification_types.slack_channel_purpose == TYPE_SLACK_CHANNEL_MAP[type_key]` y `slack_forced == (type_key in FORCED_SLACK_TYPES)` antes de borrar las constantes.
- **Corte de n8n en dos fases** (5→7 arriba): el servicio empieza a enviar **antes** de retirar n8n, se verifica en un tenant, y solo entonces se corta la rama n8n → ventana de doble envío controlada y observable, en vez de un gap.
- **`_dispatch_slack` nunca lanza** (se mantiene el try/except): un fallo de Slack jamás rompe el flujo principal (crear visita, cambiar estado, etc.).
- **No tocar `resolve_channels` ni `default_channels`:** la lógica de habilitado/preferencias no cambia; solo se le añade la fuente de `purpose`/`forced` desde BD.
- **Master switch fail-safe:** si `integration_config[slack]` no existe, tratar como "no enviar" (no como "enviar a general"), para que desactivar sea determinista.
- **Regla de negocio verificable** (memoria `regression-test-on-bugfix`): la resolución de canal (proyecto→general→none) como **función pura** testeable + una única fuente de verdad, evitando divergencia entre el dispatch de visita y el dispatch genérico.

---

## 11. Decisiones que necesito confirmar antes de implementar

1. **`type_key` de visita agendada:** ¿reutilizamos `visit_created` (recomendado, cero tipos nuevos) aunque hoy tenga tinte de "tarea", o hay otro `type_key` existente que prefieras mapear al canal de visitas?
2. **Cómo se conecta el canal por proyecto:** ¿(a) el OAuth de Slack se reejecuta por proyecto (state con `project_id`) y guarda su propio webhook, o (b) el tenant elige, de entre los canales/webhooks ya conectados a nivel tenant, cuál usa cada proyecto? (b) evita N conexiones OAuth.
3. **Punto de disparo del Slack de visita:** ¿lo enganchamos en el callback de creación de visita (`send-visit-confirmation`/`notify-visit-advisor`, que ya traen tenant+lead y de donde sacar `project_id`) o en `lead_service.update_status` cuando entra a `visita_agendada` (mismo punto que n8n hoy)? Impacta qué `project_id` está disponible.
4. **Webhook en claro:** ¿lo dejamos como está (recomendado, es un capability-URL y ya está así), o aprovechamos para cifrarlo también? (amplía alcance).
5. **Backfill de credenciales OAuth:** ¿sembramos las `SLACK_CLIENT_ID/SECRET` globales actuales en cada tenant con Slack activo (recomendado, no interrumpe), o forzamos que cada tenant registre su propia Slack App (más limpio, pero interrumpe reconexiones)?
6. **Número de ticket SCRUM** para el prefijo del commit.
7. **Ubicación del pipeline CI/CD** donde viven las env vars `SLACK_*` (para retirarlas en la limpieza).

---

## 12. Entregables al implementar (checklist previsto)
- Arquitectura elegida y justificación (este doc, §2).
- Lista de archivos modificados (§3).
- Migraciones (§6) + evidencia de backfill.
- Estrategia de compatibilidad (§8) y de corte n8n (§9–10).
- Checklist de pruebas manuales (se detallará al implementar): conectar Slack con credenciales de tenant; error 400 sin credenciales; switch maestro off ⇒ nada se envía; canal por proyecto vs general vs none; tipo con `slack_forced`; aislamiento tenant A/B; visita agendada llega al canal correcto sin pasar por n8n; Email/In-App sin cambios.

---

## Anexo — mapa rápido de rutas verificadas
- OAuth/config: `app/api/v1/slack_config.py` (`:22` router, `:28` connect, `:54` callback, `:25` VALID_CHANNEL_PURPOSES)
- Envío: `app/services/notification_service.py` (`:55` map, `:69` forced, `:284` slack_only, `:547` _dispatch_slack)
- Modelos: `app/db/models_notifications.py:30` (TenantSlackConfig), `:57` (NotificationType) · `app/db/models.py:2294` (ProjectZapierConfig ref), `:2875` (IntegrationConfig)
- n8n: `config/settings.py:248` (URL), `app/services/n8n_webhook_service.py`, `app/services/lead_service.py:439` (disparo)
- Visita: `app/api/v1/leads.py:5204`, `app/api/v1/tour_scheduled.py:419/480`; origen `calendar-service/src/modules/events/controllers/calendar_events.controller.js:39`
- Settings globales Slack: `config/settings.py:97-101`
- Cifrado por tenant: `integration_config_repository.py` (ENCRYPTBYKEY+view) · `app/core/encryption.py` (Fernet)
- Frontend: `src/components/settings/SlackIntegration.vue`, `src/services/slack.service.ts`, `src/views/SettingsView.vue:2526`
