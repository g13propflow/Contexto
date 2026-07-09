# RUNBOOK — Deploy a producción · SCRUM-1279

**Feature:** Credenciales de Facebook App por tenant (Meta Ads multitenant).
**Repos:** `app-saas-service` (backend) + `app-saas-frontend`.
**Ramas:** `feature/SCRUM-1279` en ambos (commits `225ae222` backend, `3ad4ebf6` frontend — **sin push ni merge aún**).
**Fecha runbook:** 2026-07-03.

> Los pasos marcados con 🔴 son **destructivos / difíciles de revertir** (migraciones, borrado de env vars). Los marcados con `⟪...⟫` son **placeholders** que debes completar con los datos reales de tu infraestructura (nombres de recursos Azure, trigger del pipeline, etc.).

---

## 0. Resumen y blast radius

- **Qué cambia:** el OAuth de Facebook Ads deja de usar `FACEBOOK_APP_ID`/`FACEBOOK_APP_SECRET` globales y pasa a credenciales **por tenant** (guardadas cifradas en `integration_config`, platform `facebook_ads`).
- **Alcance:** afecta a **todos los tenants** con Facebook Ads. Los ya conectados siguen funcionando gracias al **backfill** (Fase 4); para usar su propia app deben reconectar (Fase 8, a su ritmo).
- **Dependencias de datos:** el módulo Conexiones (no solo Facebook) requiere el permiso `connections.view` (migración `cx01`) y la columna `integration_config.deleted_at` (migración `cx03`). **Sin ellas, Conexiones da 500 / el menú desaparece.**
- **Servicios tocados:** API (`app-saas-service`), frontend, worker de Temporal (refresh de token). Sin cambios en Meta Messaging, insights ni Airflow.

---

## 1. Prerrequisitos

- [ ] Acceso de escritura a ambos repos y permiso para mergear a `main`.
- [ ] Acceso al pipeline de deploy ⟪Azure DevOps `pipeline/main.yml`⟫ y a las variables de entorno de prod ⟪Azure App Service / contenedor⟫.
- [ ] Acceso de lectura/escritura a la BD SQL Server de **producción** (para verificar y, si aplica, aplicar migraciones).
- [ ] Valores actuales de `FACEBOOK_APP_ID` y `FACEBOOK_APP_SECRET` de prod a la mano (se necesitan para el backfill **antes** de borrarlos).
- [ ] Confirmado que `FACEBOOK_REDIRECT_URI` y `FACEBOOK_FRONTEND_REDIRECT_URL` de prod son correctos (se conservan y alimentan el modal de setup).
- [ ] Ventana de deploy acordada + canal de comunicación a tenants para la Fase 8.

---

## 2. Pre-flight checks (estado actual de PROD) — solo lectura

Ejecutar **antes** de tocar nada, para decidir el camino en la Fase 1.

**2.1 Revisión de Alembic en prod**
```bash
# En el contenedor/entorno de prod del API:
alembic current
alembic heads
```
- [ ] Anotar la revisión actual: ⟪__________⟫
- ⚠️ Si `alembic current` o `upgrade head` fallan con *"Can't locate revision ... slk04_seed_slack_intgr"*, hay **drift de Alembic** (revisión de Slack fuera de `main`). Ver Fase 1.B.

**2.2 ¿Existe el permiso y la columna que el código exige?**
```sql
-- ¿Existe el permiso connections.view?
SELECT COUNT(*) AS tiene_permiso FROM permissions WHERE name = 'connections.view';
-- ¿Existe la columna deleted_at en integration_config?
SELECT COUNT(*) AS tiene_deleted_at FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_NAME = 'integration_config' AND COLUMN_NAME = 'deleted_at';
```
- [ ] `tiene_permiso` = ⟪0/1⟫  ·  `tiene_deleted_at` = ⟪0/1⟫
- Si **ambos = 1** → el epic Conexiones ya está en prod; **saltar a Fase 1.C** (nada que migrar).
- Si **alguno = 0** → hay que aplicar `cx01`/`cx03` (Fase 1).

**2.3 Estado de Facebook Ads por tenant (para dimensionar el backfill)**
```sql
SELECT COUNT(*) AS tenants_fb_activos
FROM integration_config
WHERE platform_name = 'facebook_ads' AND is_active = 1
  AND (deleted_at IS NULL OR 1=1);  -- si deleted_at no existe aún, quitar esa condición
```
- [ ] Nº de tenants con Facebook Ads activo: ⟪____⟫ (los que el backfill preservará).

---

## 3. Fase 0 — Preparar el código (rebase + resolución de conflictos)

> ⚠️ **`origin/main` avanzó** desde que se creó la rama: entró una feature paralela de **Meta Ads (PR #565 / #494, `propflow-1275`)** y la eliminación de Metabase (SCRUM-1287) que tocan los mismos archivos. Un merge de prueba confirmó conflictos. Hay que rebasar y resolver **antes** de abrir el PR.

Conflictos previstos:
- Backend: `app/api/v1/facebook_oauth.py`, `app/schemas/facebook_oauth.py` (y auto-merge en `config/settings.py`).
- Frontend: `src/services/connections.service.ts`, `src/views/ConnectionsView.vue`, `src/locales/es.json`, `src/locales/en.json`.

**Criterio de resolución:** conservar **ambos** conjuntos de campos de `FacebookStatus` — los de esta rama (`has_app_credentials`, `app_id`) **y** los de main (`has_ads_management`, `needs_reconnection`). Son features complementarias.

```bash
# Por cada repo:
git checkout feature/SCRUM-1279
git fetch origin
git rebase origin/main        # resolver conflictos conservando ambos features
# (correr tests/type-check tras resolver)
git push --force-with-lease    # 🔴 reescribe la rama remota del feature
```
- [ ] Backend rebasado, conflictos resueltos, `pytest` verde localmente.
- [ ] Frontend rebasado, conflictos resueltos, `npm run type-check` limpio.
- [ ] **Confirmar con quien hizo `propflow-1275`** que SCRUM-1279 no quedó absorbido/duplicado por ese trabajo.
- [ ] PR abierto en cada repo, CI en verde, revisión aprobada.
- [ ] Merge a `main` (el backend debe ir **antes o junto** al frontend; el frontend solo consume, degrada si el endpoint no existe).

---

## 4. Fase 1 — Migraciones de BD 🔴

> Solo si la Fase 2.2 mostró que falta `connections.view` y/o `deleted_at`. Si ya estaban, saltar a Fase 2.

**1.A — Backup**
- [ ] 🔴 Snapshot/point-in-time restore point de la BD de prod ⟪Azure SQL backup⟫ tomado y verificado.

**1.B — Si hay drift de Alembic (slk04)**
El `alembic upgrade head` falla porque prod apunta a `slk04_seed_slack_intgr`, revisión que no está en `main`. Opciones (elegir con el dueño de la BD):
- **Preferida:** reconciliar el drift trayendo/mergeando el branch de Slack o corrigiendo `alembic_version`, y luego `alembic upgrade head` (aplica `cx01`, `cx03` y el resto de forma trazable).
- **Fallback (solo si la reconciliación no es viable en la ventana):** aplicar el SQL **idempotente** de `cx01` y `cx03` a mano (ver los `upgrade()` de esas migraciones; usan `NOT EXISTS`/checks de columna). Quedan fuera de `alembic_version` → **anotar como deuda** para reconciliar después (un `upgrade` futuro las re-ejecuta como no-op).

**1.C — Aplicar migraciones**
```bash
alembic upgrade head     # camino normal
```
**1.D — Verificar (repetir las queries de 2.2)** — ambas deben dar 1:
```sql
SELECT COUNT(*) FROM permissions WHERE name = 'connections.view';                    -- esperado ≥ 1
SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_NAME='integration_config' AND COLUMN_NAME='deleted_at';                  -- esperado 1
SELECT COUNT(*) FROM sys.indexes WHERE name='uq_integration_config_tenant_platform_active'; -- esperado 1
```
- [ ] Migraciones aplicadas y verificadas.

---

## 5. Fase 2 — Deploy del backend

- [ ] Desplegar `app-saas-service` desde `main` ⟪trigger del pipeline / release⟫.
- [ ] Reiniciar también el **worker de Temporal** (usa el nuevo `refresh_long_lived_token`).
- [ ] Verificar arranque sano:
```bash
curl -sf https://⟪api.dominio⟫/api/v1/health  ||  echo "API DOWN"
```
- [ ] Confirmar que las nuevas rutas existen (deberían responder **401 sin token**, no 404):
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://⟪api.dominio⟫/api/v1/integrations/facebook/setup-info
# esperado: 401
```

> En este punto las env vars globales **todavía están presentes** — el backfill (Fase 3) las necesita.

---

## 6. Fase 3 — Backfill de tenants ya conectados 🔴

Inyecta las credenciales globales actuales en cada tenant `facebook_ads` que no tenga las suyas, para que su **refresh no se rompa** al vencer el token (un token solo lo renueva la app que lo emitió).

```bash
# En el entorno de prod, con FACEBOOK_APP_ID / FACEBOOK_APP_SECRET AÚN presentes:
python scripts/backfill_facebook_app_credentials.py --dry-run   # revisar qué haría
python scripts/backfill_facebook_app_credentials.py             # aplicar
```
- [ ] `--dry-run` revisado: nº de tenants a actualizar coincide con el conteo de la Fase 2.3.
- [ ] Backfill ejecutado; salida "updated / skipped" registrada.
- [ ] Verificación en BD (los tenants activos ahora tienen `app_id`/`app_secret` en su JSON):
```sql
-- No expone secretos; solo confirma presencia de las llaves en las filas activas.
SELECT tenant_id,
       CASE WHEN credentials LIKE '%app_id%' AND credentials LIKE '%app_secret%'
            THEN 'con app creds' ELSE 'SIN app creds' END AS estado
FROM integration_config
WHERE platform_name='facebook_ads' AND is_active=1 AND deleted_at IS NULL;
```
- [ ] Todos los activos = "con app creds" (los que queden "SIN" son casos a revisar manualmente).

---

## 7. Fase 4 — Deploy del frontend

- [ ] Desplegar `app-saas-frontend` desde `main` ⟪build + release⟫.
- [ ] Verificar en el navegador (con un usuario owner/supervisor real):
  - [ ] Menú **Conexiones** visible (permiso `connections.view` presente).
  - [ ] Tarjeta Facebook Ads: los tenants con backfill se ven **conectados**; un tenant sin app creds se ve en **ámbar** con "Conectar" deshabilitado.
  - [ ] Modal **"Configurar App"** muestra las 2 URLs (con valor real de prod) y el botón copiar.

---

## 8. Fase 5 — Retirar las variables globales 🔴

> Solo **después** de confirmar que el backfill dejó a todos los tenants activos con sus app creds (Fase 3).

- [ ] 🔴 Eliminar `FACEBOOK_APP_ID` y `FACEBOOK_APP_SECRET` de ⟪variables de entorno de prod / Azure⟫.
- [ ] **Conservar** `FACEBOOK_REDIRECT_URI` y `FACEBOOK_FRONTEND_REDIRECT_URL`.
- [ ] Confirmar que no quedan en el pipeline `pipeline/main.yml` (ya verificado: no estaban en el repo).
- [ ] Reiniciar API + worker para tomar el entorno sin esas vars.
- [ ] Sanity: el arranque no falla (settings usa `extra="ignore"`, así que aunque quedaran no rompería; el objetivo es dejar el entorno limpio).

---

## 9. Fase 6 — Verificación funcional en prod (smoke)

Con un tenant de prueba (idealmente uno interno):
- [ ] `GET /integrations/facebook/status` con token → responde 200 con `has_app_credentials`/`is_connected` coherentes.
- [ ] `GET /integrations/facebook/setup-info` → devuelve las 2 URLs reales.
- [ ] Guardar credenciales de una **Facebook App real de prueba** → toast OK; `status.has_app_credentials=true`.
- [ ] **Conectar (OAuth real)** con esa app → vuelve a Conexiones, selector de cuenta, queda conectado.
- [ ] Regresión: **Meta Messaging** sigue funcionando (enviar/recibir un DM de prueba) — no debió tocarse.
- [ ] Regresión: dashboard **Marketing / Campañas** sigue mostrando insights de un tenant con backfill.
- [ ] (Diferido ~1 ciclo) El **refresh de token** de Temporal corre sin `refresh_failed` para tenants con app creds (revisar logs del schedule `facebook-token-refresh-schedule`).

---

## 10. Rollback

| Fase | Cómo revertir |
|---|---|
| 0 (código) | Revertir el merge del PR en `main` (revert commit) y redeploy. |
| 1 (migraciones) | `cx01`/`cx03` son aditivas; el `downgrade` existe pero **no es necesario** (columnas/filas nuevas no rompen el código viejo). Preferir NO hacer downgrade; si algo grave, restaurar del backup 1.A. |
| 2 (backend) | Redeploy de la imagen anterior. |
| 3 (backfill) | No requiere rollback (solo agregó llaves al JSON; idempotente). |
| 5 (env vars) | **Re-agregar** `FACEBOOK_APP_ID`/`SECRET` a prod y reiniciar — restaura el comportamiento previo si algo del OAuth por-tenant fallara masivamente. Este es el rollback más rápido para incidentes de conexión. |

> Rollback más probable en un incidente de OAuth: **re-poner las env vars globales** (Fase 5 inversa). Como el backfill dejó a los tenants con esas mismas credenciales, el sistema vuelve al estado "todos con la app global" sin pérdida de datos.

---

## 11. Post-deploy — Migración de cada tenant (comms)

- [ ] Comunicar a los tenants que ahora pueden registrar **su propia Facebook App** (guía: `GUIA-configuracion-facebook-ads-por-tenant.html`).
- [ ] Cada tenant que quiera dejar de depender de la app global: **Configurar App** (sus credenciales) → **Reconectar** (re-OAuth, porque el token viejo pertenece a la app global).
- [ ] (Opcional, más adelante) Auditar qué tenants siguen con las credenciales globales inyectadas por el backfill.

---

## 12. Deuda técnica a registrar

- [ ] Reconciliar el **drift de Alembic** (revisión `slk04` de Slack) para que `cx01`/`cx03` (y cualquier fix manual de la Fase 1.B) queden en `alembic_version`.
- [ ] Confirmar la coexistencia definitiva de `FacebookStatus` (`has_app_credentials`/`app_id` de 1279 + `has_ads_management`/`needs_reconnection` de propflow-1275).

---

## Checklist de sign-off

- [ ] Pre-flight (Fase 2) documentado.
- [ ] Código mergeado a `main` en ambos repos, CI verde.
- [ ] Migraciones aplicadas y verificadas.
- [ ] Backend desplegado + rutas nuevas respondiendo.
- [ ] Backfill ejecutado y verificado.
- [ ] Frontend desplegado y verificado en navegador.
- [ ] Env vars globales retiradas.
- [ ] Smoke tests funcionales OK (incl. regresión Meta Messaging e insights).
- [ ] Rollback plan a la mano.
- [ ] Comms de migración a tenants enviadas.

**Responsable del deploy:** ⟪____⟫ · **Fecha/hora:** ⟪____⟫ · **Resultado:** ⟪OK / rollback⟫
