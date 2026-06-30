# PR — app-saas-service: notificación al asesor de nueva visita por canales

> ## ⚠️ Verificar antes de desplegar a prod (gate de migración)
> El código es seguro y aditivo. El único punto a confirmar es el **estado del historial de
> Alembic en el entorno destino**. En **dev** se observó una divergencia (la BD en la rama `a42…`
> y el árbol del repo en `ec01…`), pero eso **parece staleness de dev** (imagen Docker vieja + BD
> no migrada) y **no necesariamente aplica a prod**. La migración de este PR **no se validó vía
> `alembic upgrade head`** (en dev la columna se aplicó por SQL manual para poder probar), así que
> hay que confirmar el camino limpio antes de prod.
>
> **Chequeo (en prod o en un staging igual a prod):**
> ```
> alembic current   # dónde está parada la BD
> alembic heads     # cuántos "finales" hay y cuál es el último del código
> ```
> - ✅ **Si `heads` muestra UN solo head y `current` está dentro de esa cadena** → todo bien:
>   `alembic upgrade head` aplica `fa01ch02nl03` sin problema. **Proceder.**
> - ⛔ **Si hay múltiples heads, o `current` es una revisión que no existe en el código** → NO
>   desplegar aún: reconciliar el chain de Alembic (`a42…` vs `ec01…`) con quien maneja las
>   migraciones, y revalidar en staging. Correr la migración sobre un chain inconsistente puede
>   fallar o crear múltiples heads y bloquear el deploy/migraciones de todo el equipo.
>
> **Independiente del chequeo anterior — siempre:**
> - Respetar el **orden de despliegue**: migración/columna **antes** del código. Si el código sube
>   sin la columna, todo `select(Advisor)` falla con `42S22` y se rompe el módulo de asesores
>   (lista, asignación de leads, etc.).
> - La migración es **idempotente**: si la columna ya existiera en el entorno (p. ej. dev y prod
>   comparten la misma BD), no la vuelve a crear ni falla.

## Qué hace
Permite elegir por qué canal(es) se notifica a un asesor cuando se le agenda una visita
(Email / WhatsApp / SMS), con mínimo 1 obligatorio. Asesores existentes: externos conservan
WhatsApp + Email; internos quedan en Email.

## Cambios
- `Advisor.notification_channels` (JSON) + migración `fa01ch02nl03` (idempotente, backfill por tipo).
- Schema: validación de canales (`email`/`whatsapp`/`sms`, mínimo 1, sin duplicados) en create/update/response.
- `notify_advisor_new_visit` (rename de `notify_external_advisor_new_visit`): aplica a cualquier asesor
  activo, envía según canales; el correo incluye teléfono y correo del lead; SMS pendiente (fase 2).
- Aislamiento por canal + logging a prueba de llaves (un canal que falla no tumba los demás).
- Endpoint server-to-server `POST /api/v1/leads/notify-visit-advisor` (X-API-Key) + `PUBLIC_PATHS`.
- `TenantConfig`: se leen solo `company_name`/`agent_name` (evita acoplar a columnas con drift).

## ⚠️ Dependencias entre PRs (mismo feature)
Orden de despliegue: **este repo primero** (migración + código) → luego `calendar-service` y `app-saas-frontend`.
`calendar-service` llama al endpoint nuevo; el frontend usa el campo nuevo. Ambos dependen de este.

## Checklist pre-merge
- [ ] Code review aprobado.
- [ ] **Reconciliar el chain de Alembic** antes de mergear: la BD destino puede estar en una rama
      divergente (`a42…`) mientras el árbol está en `ec01…`. Confirmar que `fa01ch02nl03`
      (`down_revision = ec01_merge_lrc02_and_workflows`) encadena con el head real del entorno.
- [ ] Probar `alembic upgrade head` en **staging** (no estrenar la migración directo en prod).

## Checklist pre-deploy (prod)
- [ ] Aplicar la migración **antes o junto** con el código. Si el código sube sin la columna,
      todo `select(Advisor)` falla con `42S22` (lista de asesores, asignación de leads, etc.).
- [ ] Verificar que no haya otro drift de esquema pendiente en la BD destino
      (en dev faltaba `tenant_configs.appdispo_sync_enabled`, que rompe `get_tenant_config`).
- [ ] `QUOTATION_API_KEY` (server-to-server) configurada y conocida por `calendar-service`.

## Checklist post-deploy
- [ ] Smoke test: la lista de asesores (`GET /advisors`) carga 200 (confirma que la columna existe).
- [ ] Crear/editar un asesor guarda `notification_channels` (mínimo 1 validado).
- [ ] `POST /api/v1/leads/notify-visit-advisor` responde 200 con `X-API-Key` válido (401 sin/llave mala).
- [ ] Revisar logs `advisor_notify` al agendar una visita real (ruteo por canal correcto).

## Notas / cambios de comportamiento
- La notificación ahora aplica a **todos los asesores activos** (antes solo externos).
- Backfill: externos `["email","whatsapp"]`, internos `["email"]`.
- Rollback: la migración trae `downgrade()` que elimina la columna (idempotente).
