# PR — app-saas-frontend (SCRUM-1287): eliminar integración Metabase del dashboard

Rama: `feature/SCRUM-1287` · Commit: `ef1aa6bb`

## Qué hace
Elimina por completo la funcionalidad de **Metabase** del módulo Dashboard. Se retiran las
pestañas **Embudo** y **Dashboard** (que eran iframes embebidos de Metabase) y se deja
únicamente la pestaña **Marketing** (dashboard nativo, ya existente), que pasa a renderizarse
directamente. No hay cambios de comportamiento en Marketing.

## Cambios
- `src/views/DashboardView.vue`: se quitan las pestañas Embudo/Dashboard, el `<iframe>`, los
  estados de carga/error y toda la lógica de embed JWT de Metabase. Queda un contenedor delgado:
  encabezado de bienvenida + `<MarketingDashboardView />`. Al quedar una sola pestaña, se retira
  la barra de tabs.
- `src/services/analytics.service.ts`: **borrado** (cliente HTTP exclusivo de Metabase,
  `getMetabaseEmbedUrl` + tipos `Metabase*`; solo lo consumía `DashboardView`).
- `src/locales/es.json` y `en.json`: se elimina el bloque `dashboard.analytics` (claves
  `marketing`/`funnels`/`dashboard`/`funnelsComingSoon`/`funnelsDescription`/`errorLoading`/
  `retry`/`loading`), todas sin uso tras el cambio. Se conservan `dashboard.welcome`/`subtitle`.

## Qué NO se toca
- `MarketingDashboardView.vue` y sus componentes (KPIs, filtros, charts) — es autónomo, consume
  `/api/v1/marketing/dashboard/*`. Sin cambios.
- La ruta `/dashboard` se conserva (sigue apuntando a `DashboardView.vue`).

## Dependencias entre PRs (mismo feature)
- Par con `app-saas-service` (rama `feature/SCRUM-1287`, commit `b8ac7403`), que elimina el
  endpoint `POST /analytics/metabase/embed-url`.
- **Orden de despliegue sugerido: este repo primero (o simultáneo).** Así ningún cliente sigue
  llamando al endpoint. Si el backend fuera primero, las pestañas Metabase del frontend viejo
  mostrarían su estado de error (transitorio, y esas pestañas desaparecen con este PR). Sin
  riesgo de datos.

## Verificación realizada
- `vite build` (bundle de producción): **✓ compila limpio** con estos cambios
  (`DashboardView` genera su chunk sin errores).
- Barrido: **cero** referencias residuales a `metabase`/`analytics.service`/`dashboard.analytics`
  en todo el repo.
- Type-check: sin errores nuevos en archivos tocados (los errores existentes de `vue-tsc` son
  **pre-existentes** en otros módulos, no introducidos por este PR).

## Checklist pre-merge
- [ ] Code review aprobado.
- [ ] `npm ci` en CI instala `xlsx-js-style` (declarada en `package.json`, faltaba solo en
      node_modules local — ajeno a este PR, pero necesario para que `vite build` complete).

## Checklist post-deploy (prod)
- [ ] Abrir `/dashboard`: muestra Marketing directamente, **sin** pestañas Embudo/Dashboard.
- [ ] KPIs, filtros, vistas guardadas y charts de Marketing cargan sin error.
- [ ] Consola del navegador sin errores de imports ni claves i18n faltantes.
- [ ] Cambio de idioma ES/EN sin claves crudas (`dashboard.analytics.*`).

## Notas
- No se removió ninguna dependencia de npm (Metabase no aportaba librerías; era iframe + fetch).
- No hay variables `VITE_` de Metabase en el frontend (el secreto vivía solo en backend).
