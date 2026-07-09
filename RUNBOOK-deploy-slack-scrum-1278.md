# Runbook de despliegue — SCRUM-1278 · Slack administrable por tenant

> **Objetivo:** llevar a producción la integración de Slack administrable por tenant (credenciales por tenant, switch maestro, canal por tipo, canal por proyecto y aviso de visita agendada por el servicio en vez de n8n).
>
> **Regla de oro:** desplegar **primero en QA**, verificar, y recién entonces prod. Las migraciones corren sobre la **BD compartida de Azure** → cuidado.

---

## 0. Estado y alcance

- **Rama:** `feature/SCRUM-1278` (ambos repos).
- **Commits:**
  - `app-saas-service`: `3f6a13df` (feat + 4 migraciones) · `ece1611c` (pipeline escribe SLACK_REDIRECT_URI/FRONTEND al .env)
  - `app-saas-frontend`: `53371ddf` (UI) · `2880c17e` (fix pestaña admin notificaciones)
- **Cambios de BD:** 1 tabla nueva (`project_slack_config`), 1 alterada (`notification_types` +4 columnas), 2 reutilizadas sin cambio (`integration_config`, `tenant_slack_config`).
- **Migraciones (SCRUM-1278):** `slk01` (columnas) → `slk02` (backfill) → `slk03` (tabla) → `slk04` (seed `integration_config[slack]`) → **`slk05_merge_hs01_slk04`** (merge de heads tras fusionar `origin/main`). **Head resultante: `slk05_merge_hs01_slk04`.**
- **Nota merge:** la rama ya contiene `origin/main`, así que trae también las migraciones de main (`nc0x`/`cx0x`/`hs01`/`p910`). Si el entorno destino ya tiene main desplegado, esas ya estarán aplicadas y `upgrade head` solo sumará `slk01`→`slk05`.

---

## 1. ⚠️ Pre-flight (OBLIGATORIO antes de migrar) — QA y luego PROD

En el contenedor del backend del entorno destino:

```bash
alembic current    # ¿en qué revisión está la BD?
alembic heads       # ¿UN solo head? ¿cuál?
```

Checklist:
- [ ] `alembic heads` → tras aplicar todo debe quedar **un solo head: `slk05_merge_hs01_slk04`**. Si aparecen múltiples heads inesperados, resolver antes de forzar el upgrade.
- [ ] Como la rama incluye main, en un entorno **al día con main** el `upgrade head` solo suma `slk01`→`slk05`; en uno **atrasado** aplicará también las migraciones de main (nc0x/cx0x/hs01/p910). Verificar `alembic current` para saber en cuál caso estás.
- [ ] FB `ad_insights.level`: el drift manual **lo resuelve `p910level01`** (viene de main en la rama). Confirmar que la columna no exista ya agregada a mano y duplicada antes de migrar.
- [ ] Idealmente, **hacer un dry-run/validación en QA** y confirmar que las 4 migraciones aplican limpio antes de tocar prod.

> Mis 4 migraciones son **idempotentes** (guards sobre `sys.columns`/`sys.objects`), así que re-correrlas es seguro; el riesgo real es el estado/encadenamiento de Alembic previo, no mis migraciones.

---

## 2. Despliegue (repetir en QA → PROD)

### 2.1 Merge
- [ ] Merge de `feature/SCRUM-1278` a la rama que despliega el entorno (PR) en **ambos repos**.

### 2.2 Variables en Azure DevOps
En el **variable group** del entorno (`variables-ai-agents-*`):
- [ ] `SLACK_REDIRECT_URI = https://<dominio-api-del-entorno>/api/v1/integrations/slack/callback`
- [ ] `SLACK_FRONTEND_REDIRECT_URL = https://<dominio-front-del-entorno>/dashboard/settings`

> El pipeline (`pipeline/main.yml`) ya escribe ambas al `.env` (stages DeployDev y DeployQA). Verifica que exista el stage/variable group correcto para PROD; si prod usa **otro** pipeline, agrega ahí las mismas 2 líneas al bloque `cat > .env`.

### 2.3 Deploy backend
- [ ] Disparar el pipeline del backend (genera el `.env` con las nuevas vars).

### 2.4 Migraciones (el compose solo monta `./app` → hace falta `docker cp`)
```bash
docker cp alembic/versions/slk01_ntype_slack_cols.py <api>:/app/alembic/versions/
docker cp alembic/versions/slk02_backfill_slack.py    <api>:/app/alembic/versions/
docker cp alembic/versions/slk03_project_slack_cfg.py <api>:/app/alembic/versions/
docker cp alembic/versions/slk04_seed_slack_intgr.py  <api>:/app/alembic/versions/
docker cp alembic/versions/slk05_merge_hs01_slk04.py  <api>:/app/alembic/versions/
docker exec <api> alembic upgrade head
```
Aplica: columnas Slack + backfill (paridad byte-idéntica) + tabla `project_slack_config` + seed de `integration_config[slack]` para tenants ya conectados.

### 2.5 Deploy frontend
- [ ] Disparar el deploy del frontend.

---

## 3. Verificación post-deploy

- [ ] `GET /api/v1/integrations/slack/status` de un tenant → responde 200.
- [ ] Backfill correcto: p. ej. `advisor_daily_summary` → canal `daily_activity`, `slack_forced=1` (mismos valores que tenía el código).
- [ ] Un tenant con Slack previo **sigue recibiendo** (webhooks intactos + seed dejó `is_active=1`).
- [ ] **Owner:** Ajustes → Slack → registra `client_id`/`client_secret` → **Conectar** un canal (ahora con https real) → llega mensaje de **Probar**.
- [ ] **Ruteo por tipo:** Notificaciones → Administración → cambiar canal/obligatorio de un tipo → persiste.
- [ ] **Canal por proyecto:** Conexiones → asignar un canal conectado a un proyecto.
- [ ] **Visita:** mover un lead a `visita_agendada` (desde nuevo/contactado/calificado) → llega el aviso al canal del proyecto (o al general).
- [ ] **Switch maestro OFF** → no llega nada; ON → vuelve a llegar.
- [ ] Email / In-App **sin cambios**.

---

## 4. Corte de n8n y limpieza (SOLO después de verificar en prod)

- [ ] Verificar en un **tenant piloto** que el servicio ya envía la visita.
- [ ] En **n8n**: retirar **SOLO la rama/nodo de Slack para `visita_agendada`**.
  - 🚫 **NO** apagar `N8N_LEAD_STATUS_WEBHOOK_URL` (lo comparten Pipedrive/Zapier/otras automatizaciones).
- [ ] Cleanup post-backfill (cuando el seed ya corrió en todos los entornos):
  - [ ] Quitar `slack_client_id` / `slack_client_secret` de `config/settings.py`.
  - [ ] Quitar esas vars globales del pipeline / variable group (si existían).

---

## 5. Rollback

- **Migraciones:** para revertir **solo** lo de SCRUM-1278, `docker exec <api> alembic downgrade hs01_hubspot_notes_toggle` (baja `slk05`→`slk01`; las 5 tienen `downgrade`). ⚠️ NO bajes más allá de `hs01` o revertirías migraciones de main.
- **Corte rápido sin revertir código:** apagar el switch maestro por tenant → `UPDATE integration_config SET is_active=0 WHERE platform_name='slack' AND tenant_id='<t>'` (o `PATCH /integrations/slack/enabled {enabled:false}`). Detiene envíos al instante.
- **n8n:** si se cortó la rama de Slack y algo falla, se puede reactivar temporalmente mientras se corrige.

---

## 6. Notas de compatibilidad (importante)

- **Tenants con Slack previo:** no se rompen. El seed (`slk04`) les deja `is_active=1` y sus webhooks siguen.
- **Credenciales:** si el entorno tiene `SLACK_CLIENT_ID/SECRET` globales configuradas, el seed las copia por tenant (podrán reconectar). Si no, siguen **recibiendo** pero para **reconectar** cada owner debe cargar sus credenciales en la UI.
- **OAuth:** `SLACK_REDIRECT_URI` es global (misma para todos los tenants); cada Slack App de tenant debe registrar **esa misma** redirect URL. Slack exige **https**.
- **Comportamiento preservado:** el aviso de visita se dispara en el **mismo punto que n8n** (lead → `visita_agendada`). Email/In-App intactos.

---

## 7. Referencias

- Guía de configuración (owner): `Projects/GUIA-configuracion-slack-por-tenant.html`
- Bitácora técnica: `Projects/auto-doc/2026-07-02-scrum-1278-slack-administrable-por-tenant.md`
