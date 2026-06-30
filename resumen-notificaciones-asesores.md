# Resumen — Notificación de visita al asesor por canal (Email / WhatsApp / SMS)

Feature: en `/dashboard/advisors`, al crear/editar un asesor se elige por qué canal(es)
se le notifica cuando se le agenda una visita (Email, WhatsApp, SMS). Mínimo 1 canal.
Asesores existentes quedan en **Email** por defecto. El mensaje es el mismo en todos los canales.

**Decisiones tomadas:** SMS visible en UI pero **inerte (fase 2)**; la notificación aplica a
**todos los asesores activos** (no solo externos); WhatsApp usa la **plantilla aprobada actual**.

---

## 1. Cambios por repositorio

### `app-saas-service` (backend principal)

| Archivo | Cambio |
|---|---|
| `app/db/models.py` | Columna `notification_channels` (JSON) en `Advisor`, default `["email"]`. |
| `alembic/versions/fa01ch02nl03_add_notification_channels_to_advisors.py` | **Migración nueva**, idempotente (guard `IF NOT EXISTS`): agrega columna + backfill por tipo de asesor — **externos → `["email","whatsapp"]`** (conservan el WhatsApp que ya recibían), **internos → `["email"]`**. Solo toca filas NULL. `down_revision = ec01_merge_lrc02_and_workflows`. |
| `app/schemas/advisor.py` | Helper `_normalize_notification_channels` (minúsculas, sin duplicados, solo `email/whatsapp/sms`, **mínimo 1**, `None→["email"]`). Campo en `AdvisorBase` / `AdvisorUpdate` (opcional) / expuesto en `AdvisorResponse`. |
| `app/api/v1/advisors.py` | `create_advisor` guarda el campo (update ya lo cubría vía `model_dump`). |
| `app/services/advisor_notification_service.py` | (varios — ver detalle abajo) |
| `app/api/v1/tour_scheduled.py` | Caller actualizado al nuevo nombre + **endpoint nuevo** `POST /api/v1/leads/notify-visit-advisor`. |
| `app/agents/tools/qualification_tools.py` | Caller actualizado al nuevo nombre. |
| `app/schemas/lead.py` | Schemas `NotifyVisitAdvisorRequest` / `NotifyVisitAdvisorResponse`. |
| `app/middleware/authentication.py` | Endpoint nuevo agregado a `PUBLIC_PATHS` (auth por `X-API-Key`, no Auth0). |

Detalle de `advisor_notification_service.py`:
- Renombrada `notify_external_advisor_new_visit` → **`notify_advisor_new_visit`**.
- **Quitado el gate `is_external`** → aplica a cualquier asesor activo.
- **Ruteo por canal**: envía Email y/o WhatsApp según `notification_channels`; SMS solo loguea (fase 2).
- El **correo** incluye el mensaje completo con **teléfono y correo del lead**.
- `TenantConfig`: se seleccionan **solo `company_name` y `agent_name`** (no la entidad completa) para evitar el `42S22` por drift de esquema.
- **Logging a prueba de llaves** en los `except` (detalle como argumento de loguru, no interpolado) → evita el `KeyError` cuando el error trae JSON.
- **Aislamiento por canal**: cada canal en su propio `try` → el fallo de uno no impide los demás.

### `calendar-service`

| Archivo | Cambio |
|---|---|
| `src/infrastructure/adapters/saas-service/send.advisor.visit.notification.js` | **Adapter nuevo**: callback HTTP al endpoint del saas. |
| `src/modules/events/controllers/calendar_events.controller.js` | Al crear una visita **manual** (`event_origin=control_manual`, tipo `visit/appointment`, con `lead_id`) dispara el callback **fire-and-forget** (sin `await`, con `.catch`): no añade latencia ni puede romper el `201`. Gated para no duplicar con marketplace/agente. |

### `app-saas-frontend`

| Archivo | Cambio |
|---|---|
| `src/types/advisors.ts` | Campo `notification_channels: string[]` en `Advisor`. |
| `src/views/advisors/components/AdvisorForm.vue` | Sección "Canales de notificación" (Email / WhatsApp / SMS-deshabilitado), default Email, **validación mínimo 1**. |
| `src/views/advisors/index.vue` | Carga el campo al editar y lo envía al actualizar. |
| `src/locales/es.json`, `src/locales/en.json` | Textos i18n. |

---

## 2. Bugs encontrados y corregidos (en code review / pruebas)

1. **`PUBLIC_PATHS` faltante** — el endpoint nuevo daba 401 por el middleware Auth0. Agregado.
2. **Migración no idempotente** — al aplicarse fuera de banda podía chocar; ahora con guard `IF NOT EXISTS`.
3. **`42S22` en `notify`** — `select(TenantConfig)` completo reventaba por una columna que falta en la BD (`appdispo_sync_enabled`); ahora selecciona solo las 2 columnas necesarias.
4. **Crash de logging + canal que tumbaba a otro** — loguru + `exc_info=True` + JSON del error 401 de Meta → `KeyError` que abortaba el email. Corregido (logging brace-safe + aislamiento por canal).

---

## 3. Pruebas realizadas

- Validación de schema (default, normalize, dedupe, mínimo-1, inválido, update, response None→email): **8/8 OK**.
- Ruteo por canal (email/wa/ambos, sms→nada, interno sí notifica, inactivo no, sin email/phone, None→email): **9/9 OK**.
- Endpoint auth/routing (200 / 401 / 422): **OK**.
- Round-trip ORM (JSON → lista Python): **OK**.
- E2E cableado calendar→saas: **200**.
- **E2E real**: visita manual → callback → notificación → **correo recibido (status 202)** con el mensaje y datos del lead. ✅
- WhatsApp: flujo correcto (plantilla y parámetros bien armados); bloqueado solo por token de Meta vencido (401).

---

## 4. Cambios de configuración local (dev) que apliqué

> Estos son ajustes de entorno, no de la feature. `.env` está gitignored.

- `app-saas-frontend/.env`: `VITE_API_BASE_URL` → `http://127.0.0.1:8000`
- `calendar-service/.env`:
  - `QUOTATION_API_KEY` alineada a la del saas (también arregla los callbacks existentes de confirmación/reagendado).
  - `SAAS_SERVICE_URL` → `http://127.0.0.1:8000`
  - `REDIS_URL` → `redis://127.0.0.1:6379`
- **BD**: columna `notification_channels` agregada manualmente a `dbo.advisors` + backfill de 7 asesores a `["email"]` (sin stampear Alembic, por la divergencia de migraciones).

Requieren **reiniciar** tras tocar `.env`: el `npm run dev` del frontend y el de calendar-service. El contenedor `api` tiene `--reload`.

---

## 4-bis. Revisión final pre-commit (riesgos de prod y cambios de comportamiento)

**Veredicto:** los diffs son aditivos (no se eliminó lógica existente), todo compila y los
locales son JSON válido. No hay errores que rompan en import/arranque. Hallazgos:

- **⛔ CRÍTICO — orden de despliegue.** El modelo `Advisor` ahora incluye `notification_channels`.
  Si se despliega el código **sin** haber aplicado la migración/columna en esa BD, **todo
  `select(Advisor)` falla con `42S22`** (lista de asesores, asignación de leads, la propia
  notificación, etc.). La migración **debe** aplicarse en el mismo despliegue, antes/junto al código.
- **✅ Resuelto — asesores externos conservan WhatsApp.** Antes los externos recibían **WhatsApp +
  Email**. El backfill ahora deja a los **externos en `["email","whatsapp"]`** (no pierden WhatsApp) y
  a los **internos en `["email"]`**. Aplicado también a la data ya existente en la BD de dev
  (externos 53 y 54 → email+whatsapp; el resto sin cambios; sin pisar elecciones manuales).
- **ℹ️ Cambio de comportamiento — asesores internos ahora sí reciben aviso.** Antes solo externos;
  ahora cualquier asesor activo (por defecto solo Email). Es la intención de la feature.
- **Mínimo 1 canal obligatorio** aplica por igual a internos y externos: se pueden quitar/agregar
  canales libremente pero **no se puede dejar ninguno** (validado en el schema backend y en el
  formulario).
- **✅ Corregido en esta revisión:** el callback de calendar-service pasó de `await` a fire-and-forget
  (evita hasta 10s de latencia en el alta de visita si el SaaS está lento/caído).
- **Cosmético (no bug):** los logs de éxito en `_send_whatsapp`/`_send_email` aún dicen "external
  advisor"; ahora aplica a cualquier asesor. Solo texto de log; opcional limpiar.

## 5. Pendientes de entorno (NO bloquean la feature, son del equipo)

1. **Reconciliar migraciones Alembic.** La BD está en la revisión `a42w09r35s98` (rama vieja) mientras el árbol local tiene head `ec01_merge_lrc02_and_workflows` (rama nueva): divergen. Además la BD **le faltan columnas** que el modelo ya espera (p.ej. `tenant_configs.appdispo_sync_enabled`), lo que ya rompe `get_tenant_config` y otros. Hay que reconciliar y correr `alembic upgrade head`. Mi migración quedó idempotente para no chocar.
2. **Token de WhatsApp (Meta) vencido/inválido** para `tenant_dpb` → da `401 OAuthException`. Se necesita un access token válido de WhatsApp Cloud API para que WhatsApp realmente entregue.
3. **`QUOTATION_API_KEY`**: alineada en dev; verificar que coincida calendar-service ↔ saas en los demás entornos.
4. **IPv6 / `localhost` en Windows + Docker.** `localhost`→`::1` y Docker publica solo en IPv4 → cuelgues. Mitigado usando `127.0.0.1` en los `.env`. Solución de fondo: reiniciar Docker Desktop completo (recrea el proxy) o mantener `127.0.0.1`.
5. **SMS (Twilio)**: no implementado (fase 2). La UI muestra el canal deshabilitado.
6. **Plantilla WhatsApp**: usa la aprobada actual → el mensaje por WhatsApp no incluye teléfono/correo del lead (sí el correo). Si se quiere paridad, re-aprobar plantilla con Meta.
7. **Bug latente fuera de mi feature**: `notify_external_advisor_hitl` (`advisor_notification_service.py` ~línea 343) tiene el mismo patrón de logging (`exc_info=True` + `{e}`) que puede crashear con errores que traigan llaves. Conviene aplicarle el mismo fix.

---

## 6. Cómo probar manualmente (resumen)

1. **UI/validación**: `/dashboard/advisors` → editar/crear asesor → sección "Canales de notificación"; intentar guardar sin canales → bloquea (mínimo 1).
2. **Notificación**: el asesor debe tener **horario de trabajo** que cubra el día/hora (si no, calendar-service rechaza la visita con "Advisor does not work on …"). Agendar la visita → ver logs:
   ```
   docker compose logs -f api | grep advisor_notify
   ```
   Con canal Email llega el correo "Nueva visita agendada con {lead}". WhatsApp requiere token Meta válido.
