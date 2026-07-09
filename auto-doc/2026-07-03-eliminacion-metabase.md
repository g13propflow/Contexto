# Eliminación completa de la funcionalidad Metabase

## Fecha
2026-07-03

## Tarea solicitada (en concreto)
Eliminar por completo la integración con **Metabase** en frontend y backend.
En el módulo **Dashboard** eliminar las pestañas **Embudo** y **Dashboard**
(ambas eran iframes embebidos de Metabase) y dejar únicamente la pestaña
**Marketing** (dashboard nativo), asegurando que siga funcionando. Retirar todo
el código muerto asociado: rutas, servicios, clientes HTTP, estados, tipos,
configuraciones, variables de entorno y referencias.

## Rama
`main` (pendiente de commit por el usuario)

## Módulos afectados
- `app-saas-frontend` — módulo Dashboard
- `app-saas-service` — API de analytics + configuración + pipeline

---

## Arquitectura previa (contexto)
El módulo Dashboard (`/dashboard` → `DashboardView.vue`) tenía 3 pestañas:
- **Marketing** → `MarketingDashboardView.vue`, dashboard **nativo** que consume
  `/api/v1/marketing_dashboard/*`. **No dependía de Metabase.**
- **Embudo** (`funnels`) y **Dashboard** (`dashboard`) → `<iframe>` de Metabase.
  Flujo: `DashboardView` → `analytics.service.ts::getMetabaseEmbedUrl()` →
  `POST /api/v1/analytics/metabase/embed-url` → `analytics.py` firmaba un JWT con
  `metabase_secret_key` y devolvía la `embed_url`.

---

## Archivos ELIMINADOS
1. `app-saas-service/app/api/v1/analytics.py`
   — Único archivo 100% Metabase (endpoint `POST /analytics/metabase/embed-url`).
2. `app-saas-frontend/src/services/analytics.service.ts`
   — Cliente HTTP exclusivo de Metabase (`getMetabaseEmbedUrl`, tipos
   `Metabase*`). Solo lo consumía `DashboardView.vue`.

## Archivos MODIFICADOS (y por qué)
1. `app-saas-frontend/src/views/DashboardView.vue`
   — Se eliminaron las pestañas Embudo/Dashboard, el `<iframe>`, los estados de
   carga/error de Metabase y toda la lógica JWT/URL. Queda un contenedor simple:
   encabezado de bienvenida + `<MarketingDashboardView />`. Al quedar una sola
   pestaña, la barra de tabs perdía sentido y se retiró. Se preservó exactamente
   el comportamiento de Marketing (se renderiza dentro de `flex-1 min-h-0`).
2. `app-saas-frontend/src/locales/es.json` y `en.json`
   — Se eliminó el bloque `dashboard.analytics` completo (marketing, funnels,
   dashboard, funnelsComingSoon, funnelsDescription, errorLoading, retry,
   loading). Todas esas claves solo se usaban en `DashboardView.vue`.
3. `app-saas-service/app/api/v1/__init__.py`
   — Se quitó el import de `analytics` y `api_router.include_router(analytics.router)`.
4. `app-saas-service/config/settings.py`
   — Se quitaron los 4 campos `metabase_*` (`metabase_site_url`,
   `metabase_secret_key`, `metabase_dashboard_id`,
   `metabase_conversion_dashboard_id`) y su comentario.
5. `app-saas-service/pipeline/main.yml`
   — Se quitaron los 2 bloques `# METABASE` (variables `METABASE_*`) de las
   etapas del pipeline.
6. `app-saas-service/app/api/v1/marketing_dashboard.py`
   — Docstring: se quitó la mención "(reemplazo del Metabase embed)" para no
   dejar referencias a Metabase.

---

## Decisiones tomadas
- **`MarketingDashboardView.vue` NO se tocó**: es autónomo (KPIs, filtros, charts
  vía `/marketing_dashboard/*`) y es el que debe seguir funcionando.
- **`DashboardView.vue` se conserva** como contenedor delgado en lugar de apuntar
  el router directo a `MarketingDashboardView`, para preservar el encabezado de
  bienvenida existente sin cambiar la ruta `/dashboard`.
- **PyJWT (`import jwt`) NO se eliminó**: se usa también para la validación de
  tokens Auth0. No se removió ninguna dependencia de Python ni de npm.
- **Variables `METABASE_*` en Azure**: se removieron del `pipeline/main.yml`; el
  borrado en el portal/Library de Azure es una acción operativa del usuario.

---

## Validaciones ejecutadas
- JSON de `es.json` / `en.json`: parseo OK.
- Sintaxis Python de `__init__.py` y `settings.py`: OK.
- `npm run type-check`: sin errores nuevos. Los errores reportados son
  **preexistentes** en otros módulos (WorkflowEditor, advisor-chat,
  distribution-lists, FHAView, NotificationsView, etc.) y no tocan los archivos
  modificados.
- Grep final: sin referencias residuales a `metabase` / `analytics.service` /
  `dashboard.analytics` en `src/` (frontend) ni en `app/`, `config/`, `pipeline/`
  (backend).

## Posibles regresiones a vigilar
- Que algún consumidor externo llamara directamente a
  `POST /api/v1/analytics/metabase/embed-url` (no hay ninguno en estos repos).
- Que el portal de Azure siga inyectando variables `METABASE_*` huérfanas
  (inofensivo, pero conviene limpiarlas).

## Checklist de pruebas manuales
- [ ] Abrir `/dashboard`: se muestra el dashboard de **Marketing** directamente,
      sin barra de pestañas Embudo/Dashboard.
- [ ] KPIs, filtros, vistas guardadas y charts de Marketing cargan y funcionan.
- [ ] No aparece ninguna pestaña "Embudo" ni "Dashboard".
- [ ] No hay errores en consola del navegador (imports/i18n faltantes).
- [ ] El backend levanta sin error (router `analytics` ya no existe) y `/docs`
      no muestra el tag "Analytics".
- [ ] `GET /docs` / navegación: no hay endpoint `/analytics/metabase/embed-url`.
- [ ] Cambiar idioma ES/EN en el dashboard no arroja claves i18n faltantes.

---

# Segunda parte — Pruebas, levantar entorno y entrega

## Verificación exhaustiva de la eliminación (sin sorpresas)
- **Barrido de residuos** en ambos repos: cero `metabase`/`analytics.service`/
  `dashboard.analytics`. Los `activeTab`/`funnels` que aparecieron son de otros
  módulos (HubSpot, FHA, CampaignsView, etc.), no de Metabase.
- **Pydantic `extra="ignore"`**: las vars `METABASE_*` huérfanas no crashean el
  backend; aun así se limpió el `.env` local (gitignored, no va al commit).
- **OpenAPI en vivo** (`/openapi.json`): 0 rutas `analytics`/`metabase`, 0 tag
  `Analytics`; las **28 rutas `/api/v1/marketing/dashboard/*` intactas**.
- **Build de producción del frontend** (`vite build`): compila limpio con los
  cambios (`DashboardView` genera su chunk). El `type-check` (vue-tsc) tiene
  errores **pre-existentes** en otros módulos y además hizo OOM local — ajeno a
  esta HU. `xlsx-js-style` faltaba solo en node_modules local (está en
  package.json; CI la instala).

## Incidentes de ENTORNO encontrados (todos pre-existentes, ajenos a Metabase)
1. **Mount stale de OneDrive**: el contenedor servía un `config/settings.py` del
   24-jun (sin `google_roads_api_enabled`) → el API crasheaba al boot. Un
   `docker compose restart` NO bastó; se resolvió con
   `docker compose up -d --force-recreate api`, que forzó re-leer los archivos
   frescos. **Lección: editar `config/` requiere `--force-recreate`, no restart.**
2. **500 en el dashboard de marketing** (`kpis`, `ad-cost-performance`,
   `tenant-config`) con `pyodbc 42S22: Invalid column name 'level'` sobre
   `facebook_ad_insights`. Causa: la migración `p910level01` (PROPFLOW-910) nunca
   se aplicó a la BD. Además la BD apunta a la revisión `slk04_seed_slack_intgr`
   (rama Slack SCRUM-1278) ausente de `main` → drift de migraciones.
   - **Fix elegido por el usuario ("solo agrega columna")**: vía el engine async
     de la app, idempotente, se aplicó
     `ALTER TABLE facebook_ad_insights ADD level VARCHAR(20) NOT NULL DEFAULT 'campaign'`
     + índice `ix_facebook_ad_insights_tenant_level_date`. Verificado:
     `SUM(spend)` por `level` devuelve datos. Registrado como landmine en memoria
     ([[fb-ad-insights-level-manual-ddl]]): al reconciliar el drift y correr
     `alembic upgrade head` habrá que `stamp p910level01` o volverla idempotente.

## Estado del entorno local al cierre
- Backend (8000) ✅ arriba y sano · Frontend (5173) ✅ · calendar-service (3002) ✅
- quotation-service (3007) y collection-service (3010): abajo (el usuario decidió
  no levantarlos; no son necesarios para esta HU).

## Entrega — commits (a petición del usuario, en rama nueva)
Rama **`feature/SCRUM-1287`** creada desde `main` en ambos repos (`main` intacta):
- **app-saas-frontend** `ef1aa6bb` — feat(SCRUM-1287): eliminar integración
  Metabase del dashboard (4 archivos, −226).
- **app-saas-service** `b8ac7403` — feat(SCRUM-1287): eliminar endpoint y
  configuración de Metabase (5 archivos, −169).
- Sin atribución a IA en los mensajes. **No se hizo push** (queda para el usuario).

## Entrega — cuerpos de PR
Generados en la raíz del workspace:
- `PR-SCRUM-1287-frontend.md`
- `PR-SCRUM-1287-backend.md`
Incluyen orden de despliegue (frontend primero o simultáneo), verificación,
checklists y, en el backend, la sección "Fuera de alcance" con el drift de
migraciones y el aviso de `stamp p910level01`.

## Veredicto final
La HU (eliminación de Metabase) quedó **completa, limpia y prod-safe**: es solo
eliminación, sin migraciones. Los únicos temas pendientes son **operativos y
pre-existentes** (limpiar vars `METABASE_*` en Azure DevOps; reconciliar el drift
de Alembic + aplicar `p910level01` en prod), documentados en los PRs y en memoria.
