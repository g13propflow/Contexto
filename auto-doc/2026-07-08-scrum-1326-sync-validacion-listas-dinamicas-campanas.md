# Sincronización y validación de listas dinámicas al crear campañas (SCRUM-1326)

## Fecha
2026-07-08

## Tarea solicitada (en concreto)
HU: al seleccionar una **lista dinámica** durante la creación de una campaña, el sistema debe
sincronizarla en tiempo real (recalcular su membresía según sus criterios) **antes** de dejar
avanzar, mostrar una pantalla de validación con la audiencia resultante (nombre, tipo, cantidad
de leads y listado), y **bloquear** la continuación si la lista queda vacía con el mensaje en
rojo *"Lista sin leads, por favor selecciona otra lista."*. La validación de "no vacío" se
implementa en interfaz **y** backend. Las listas estáticas mantienen su comportamiento actual.

Aplica a **ambos** canales (WhatsApp y correo). Pantalla de validación = **panel inline** en el
paso de audiencia. Bloqueo por vacío **solo para listas dinámicas** (decisiones confirmadas).

Plan: `PLAN-sincronizacion-validacion-listas-dinamicas-campanas.md`.

## Rama y estado
Rama **`fix/SCRUM-1326`** en ambos repos, **commiteada y aislada sobre `main`**.

Se creó por error a partir de `feature/SCRUM-1329` (rama pausada/bloqueada, no aprobada) y luego
se **rebasó** con `git rebase --onto main feature/SCRUM-1329 fix/SCRUM-1326` (limpio, sin
conflictos) para que el PR solo lleve los commits de 1326 y no arrastre 1329 a prod. Verificado:
`merge-base == HEAD de main`, y el diff no contiene rastros de 1329 (ubicación/geocoding/visita).
Sin push (lo hace el usuario). *(Aprendizaje: crear ramas SIEMPRE desde `main`.)*

Commits (sobre `main`):
- **Backend** `feat(SCRUM-1326)`: guarda sync + no-vacío + test.
- **Frontend** `feat(SCRUM-1326)`: validación en ambos wizards + i18n + conteo consistente.
- **Frontend** `chore(SCRUM-1326)`: elimina `CreateCampaignModal.vue` (código muerto).
- **Frontend** `fix(SCRUM-1326)`: `showError` maneja `detail` objeto (evita `[object Object]`).

Archivos del PR: backend = 4, frontend = 5 (incluye borrado del modal).

## Hallazgo clave
La maquinaria de listas dinámicas ya existía y estaba probada (resolver de criterios,
materialización, endpoint `POST /distribution-lists/{id}/recalculate`, detalle con leads
paginados, preview-count). La HU se resolvió reutilizándola: **orquestación en el frontend** +
**una guarda de no-vacío en el backend**. Sin migraciones.

## Módulos afectados

### Backend `app-saas-service`
- `app/services/dynamic_list_recalc_service.py` — nuevo `DynamicListEmptyError` + helper
  `sync_and_require_non_empty(db, tenant_id, list_id)`: materializa la lista dinámica en la
  sesión dada (misma resolución que preview/envío), no-op para estáticas/None, lanza
  `DynamicListEmptyError` si queda en 0 y propaga `SegmentResolverError` si el criterio falla.
- `app/api/v1/distribution_lists.py` — `create_campaign` (WhatsApp): guarda que resincroniza y
  bloquea con **HTTP 422** (`{code, message}`): `DYNAMIC_LIST_EMPTY` (vacía) /
  `DYNAMIC_LIST_SYNC_ERROR` (error de sync).
- `app/api/v1/email_campaigns.py` — `_create_campaign` (correo): misma guarda (cubre los dos
  puntos de entrada de creación de campaña de correo).
- `tests/unit/listas_dinamicas/test_sync_guard_campaign.py` — 6 tests de la guarda
  (vacía → error, con leads → conteo, estática/None → no-op, criterio inválido → propaga).
  **Verificado**: `6 passed` corriendo en el contenedor Docker `api`.

### Frontend `app-saas-frontend`
- `src/views/distribution-lists/components/CreateCampaignWizard.vue` (WhatsApp) — al seleccionar
  una lista dinámica: `recalculate` + `getListById`, panel de validación inline (nombre +
  `ListTypeBadge` + conteo + listado de leads), estados sincronizando/error/vacía, gating de
  `canAdvance`, reset al cambiar de lista, sync de lista preseleccionada, y manejo de 422 al
  lanzar (regresa al paso de audiencia).
- `src/views/email-campaigns/components/CreateEmailCampaignWizard.vue` (correo) — mismo flujo de
  sync + panel + gating para listas dinámicas; reset del estado al abrir el modal. Además
  `showError` ahora maneja `detail` como objeto (`{code,message}`) para no mostrar
  `[object Object]` (debilidad preexistente en main, latente hasta introducir el primer 422 con
  forma de objeto).
- **Eliminado** `src/views/distribution-lists/components/CreateCampaignModal.vue` — código muerto
  (0 referencias en el repo) que creaba campañas sin sincronizar y tragaba errores en
  `console.error`. La creación de campañas va por `CreateCampaignWizard`.
- `src/locales/es.json` y `src/locales/en.json` — claves nuevas en `distributionLists.wizard` y
  `emailCampaigns.wizard`: `syncingDynamicList`, `syncError`, `retrySync`, `audienceLeadCount`,
  `emptyDynamicList` (+ `moreNotShown` en email).

### Fix de consistencia de conteo (detectado en prueba visual)
Tras sincronizar, el conteo se refleja en **todos** los lugares del wizard: fila del selector,
encabezado del panel, RESUMEN y paso Revisar (antes la fila mostraba la foto anterior). En las
vistas de gestión de listas el número sale correcto porque el backend persiste `member_count`
al recalcular.

## Decisiones tomadas (confirmadas con el usuario)
- Canales: **ambos** (WhatsApp + correo).
- Pantalla de validación: **panel inline** en el paso de audiencia (sin paso nuevo).
- Bloqueo por lista vacía: **solo listas dinámicas**; estáticas sin cambios.
- Ticket/rama: `fix/SCRUM-1326`.

## Diseño / notas técnicas
- **Reutilización**: un único `LeadSegmentResolver` alimenta preview, materialización y envío
  (invariante `preview == snapshot == send`); la guarda reusa `materialize_dynamic_list`.
- **Doble materialización** (al seleccionar en UI y al crear en backend): asumida a propósito
  para que la campaña use la sincronización más reciente y cerrar el hueco TOCTOU.
- **Volúmenes grandes**: el listado de la audiencia se sirve paginado vía
  `getListById(id, {page, page_size})` (page_size 100).
- **Errores de sync**: se distinguen del "vacío" (código 422 distinto) para que la UI muestre
  "reintentar" en lugar del mensaje de lista vacía.

## Verificación
- Backend: suite `tests/unit/listas_dinamicas/` **46 passed** (resolver + schema + 6 de la guarda)
  en el contenedor Docker `api`.
- Frontend: `npm run type-check` — sin errores en los archivos tocados. El type-check reporta
  errores **preexistentes** en archivos no relacionados (no de esta HU).
- **Verificación visual COMPLETA (usuario, 2026-07-08)**: los 5 escenarios pasaron en **ambos
  canales** — con leads / lista vacía (mensaje rojo + bloqueo) / error de sync (panel + reintentar
  recupera) / continuar-lanzar / regresión de lista estática (sin cambios).

## Estado final
Feature **lista para producción**. Aislada sobre `main` (sin dependencia de 1329), verificada
por código y visualmente. Sin migraciones, sin variables de entorno, sin cambios de workers.

## Pendientes (usuario)
- `git push -u origin fix/SCRUM-1326` en ambos repos.
- Abrir 2 PRs a `main` (textos entregados). Merge **backend primero**, luego frontend.
- Deploy: backend `docker compose up -d --build api`; frontend `npm ci && npm run build`.
- La rama `feature/SCRUM-1329` queda intacta para su propio PR cuando la aprueben.
