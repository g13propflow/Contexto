# PR — app-saas-service (SCRUM-1287): eliminar endpoint y configuración de Metabase

Rama: `feature/SCRUM-1287` · Commit: `b8ac7403`

## Qué hace
Elimina toda la implementación de **Metabase** en el backend. Retira el endpoint de generación
de URL firmada de embed, su registro en el router, la configuración de settings y la inyección
de variables en el pipeline. El **dashboard nativo de marketing** (`/api/v1/marketing/dashboard/*`)
es el reemplazo y **no se toca**.

## Cambios
- `app/api/v1/analytics.py`: **borrado**. Único archivo 100% Metabase (endpoint
  `POST /api/v1/analytics/metabase/embed-url`, firma JWT con `metabase_secret_key`).
- `app/api/v1/__init__.py`: se quita el import de `analytics` y su `api_router.include_router(...)`.
- `config/settings.py`: se quitan los campos `metabase_site_url`, `metabase_secret_key`,
  `metabase_dashboard_id`, `metabase_conversion_dashboard_id`.
- `pipeline/main.yml`: se quitan los 2 bloques `# METABASE` (vars `METABASE_*`) de las etapas.
- `app/api/v1/marketing_dashboard.py`: docstring, se elimina la mención "(reemplazo del Metabase
  embed)". Sin cambios funcionales.

## Seguridad del cambio
- **Es solo eliminación, aditivo-seguro: NO incluye migraciones de base de datos.** No hay gate
  de Alembic para este PR.
- `Settings` usa `extra="ignore"`, por lo que si el variable group de Azure aún define
  `METABASE_*`, el arranque **no falla** (quedan simplemente sin uso).
- Ningún otro servicio ni caller server-to-server depende de `/analytics/metabase/embed-url`
  (solo lo consumía el frontend, que deja de llamarlo en el PR par).

## Dependencias entre PRs (mismo feature)
- Par con `app-saas-frontend` (rama `feature/SCRUM-1287`, commit `ef1aa6bb`).
- **Orden sugerido: frontend primero (o simultáneo)** para que ningún cliente llame al endpoint
  eliminado. Desplegar este repo primero solo causaría, en el frontend viejo, el estado de error
  de las pestañas Metabase (transitorio y en vías de eliminación). Sin riesgo de datos.

## Verificación realizada
- Backend arranca limpio (`Application startup complete`, `/docs` 200) sin el módulo `analytics`.
- `GET /openapi.json`: **cero** rutas `analytics`/`metabase`, **cero** tag `Analytics`.
- Las **28 rutas `/api/v1/marketing/dashboard/*`** siguen registradas e intactas.
- Barrido: **cero** referencias a `metabase` en código/infra del repo.

## Checklist pre-merge
- [ ] Code review aprobado.

## Checklist pre-deploy (prod)
- [ ] Confirmar que la variable de entorno del deploy no requiere ya `METABASE_*` (se puede
      limpiar el variable group de Azure DevOps; opcional, inofensivo).

## Checklist post-deploy (prod)
- [ ] `GET /docs` no muestra el tag "Analytics" ni la ruta `/analytics/metabase/embed-url`.
- [ ] El dashboard de marketing (`/api/v1/marketing/dashboard/kpis`, etc.) responde normal.

## Fuera de alcance de este PR (temas de datos, pre-existentes)
> No forman parte de esta HU, pero se detectaron al probar en dev y conviene tenerlos presentes:
- **Drift de migraciones en la BD**: la BD dev apunta a la revisión `slk04_seed_slack_intgr`
  (rama Slack SCRUM-1278) ausente de `main`. `alembic current`/`upgrade head` fallan hasta
  reconciliar ese chain.
- **Columna `facebook_ad_insights.level`** (migración `p910level01`, PROPFLOW-910) no aplicada
  en la BD → los queries de `kpis`/`ad-cost-performance` daban `42S22`. En dev se agregó la
  columna + índice por SQL manual para desbloquear; **prod debe aplicar la migración** por la vía
  normal. Ojo: como en dev se hizo manual, al correr `upgrade head` habrá que `stamp p910level01`
  o volver la migración idempotente para que no falle por "already exists".
