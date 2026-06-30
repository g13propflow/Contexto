# Textos de PRs — Consolidación de Roles (SCRUM-1206)

> 4 PRs. Solicitar en orden: **PR-A → (merge) → PR-B + PR-F → (observar) → PR-C**. Todos con base `main`.

---

## PR-A — Permisos nuevos + redefinición de sets (asesor / supervisor)

**Rama:** `feature/SCRUM-1206` → **base:** `main` (app-saas-service)
**Título:** `[SCRUM-1206] Roles: permisos nuevos + redefinición de sets asesor/supervisor (inerte)`

**Descripción:**
Primera fase de la consolidación de roles. **No cambia comportamiento todavía** (no hay enforcement): solo crea los permisos nuevos en el catálogo y redefine los sets de `asesor` y `supervisor` en el seed. Es seguro de mergear y desplegar por sí solo.

**Qué incluye:**
- Permisos nuevos en el catálogo global: `projects.view`, `projects.edit`, `calls.view`, `calls.view_all_advisors`, `emails.view`, `emails.view_all_advisors`, `marketing.view`.
- `rbac_seed_service._build_permission_sets()` redefinido: `asesor` ("solo lo suyo" + módulos nuevos) y `supervisor` (comercial amplio sobre todo el tenant).
- Migraciones: `r1projcallemail01` (permisos) y `r2redefasessup01` (sets, delete+insert atómico).

**Migración a correr en prod:**
```
alembic upgrade r2redefasessup01      # NO usar "upgrade heads"
```

**Checklist para quien despliega:**
- [ ] Merge a `main`.
- [ ] `alembic upgrade r2redefasessup01` en prod.
- [ ] Desplegar backend.
- [ ] Verificar Swagger arriba (`/docs`) y que nadie reporta pérdida de acceso (debe ser inerte).

---

## PR-B — Enforcement en endpoints (backend)

**Rama:** `feature/SCRUM-1206-2` → **base:** `main` (app-saas-service)
> Solicitar **solo después** de que PR-A esté mergeado en `main`.
**Título:** `[SCRUM-1206] Roles: enforcement de permisos en endpoints`

**Descripción:**
Aplica los permisos creados en PR-A a nivel de endpoint. A partir de aquí el backend **sí bloquea** según el rol. Requiere que los permisos de PR-A ya existan en prod (por eso va en segunda ronda). No tiene migración.

**Qué incluye:**
- Nuevo factory `require_method_permission(read_perm, write_perm)` (GET→read, POST/PUT/PATCH/DELETE→write).
- `projects.py` / `properties.py`: gate a nivel de router (`projects.view` lectura, `projects.edit` escritura).
- `calls.py`: `require_permission("calls.view")` + filtrado por asesor (`calls.view_all_advisors`).
- `emails.py` (10 endpoints): de `require_roles("admin","asesor")` a `require_permission("emails.view")` + puente `view_all_advisors`.
- `campaigns.py`, `distribution_lists.py`, `email_campaigns.py`: gate `marketing.view`.
- `invitations.py` / `auth.py`: invitar → `users.invite`.
- `admin_notifications.py`, `audit_log.py`, `email_config.py`: `require_roles("admin")` → `require_roles("owner")`.
- `app/core/leads_access.py`: `can_view_all(user_ctx, perm)` + `resolve_advisor_id_list_filter(..., view_all_perm=...)` parametrizado.

**Migración:** ninguna.

**Checklist para quien despliega:**
- [ ] Confirmar que PR-A ya está en `main` y desplegado (permisos existen en prod).
- [ ] Merge a `main`.
- [ ] Desplegar backend **junto con el frontend (PR-F)**.
- [ ] Verificar caso crítico: un **asesor** que pega `GET /calls` / `GET /emails` directo NO ve datos de leads ajenos.

---

## PR-F — Gating de UI + fixes (frontend)

**Rama:** `feature/SCRUM-1206-4` → **base:** `main` (app-saas-frontend)
> Mergear/desplegar **en la misma ronda que PR-B** (ni antes ni después).
**Título:** `[SCRUM-1206] Roles: gating de UI por permisos + fixes`

**Descripción:**
Oculta/condiciona en la UI los módulos según permisos, alineado con el enforcement de PR-B. Debe desplegarse junto con PR-B: si sube antes que los permisos (PR-A) ocultaría menús de más; si sube después del enforcement, mostraría menús que dan 403.

**Qué incluye:**
- `router/index.ts`: chat asesores `advisors.view` → `advisor_whatsapp.view`; gating de properties (`projects.view`), calls, emails, campaigns; guard `/dashboard/projects/*` → `projects.view`.
- `DashboardLayout.vue`: permisos en items de nav (calls/emails/advisor-chat/campaigns/distribution-lists).
- `EmailsView.vue`, `ComposeModal.vue`: `isAdmin` → `can('emails.view_all_advisors')`.
- `ProjectsView.vue`, `ProjectsListView.vue`: `v-permission="'projects.edit'"` en crear/editar/borrar.
- **Fix de regresión:** `LeadTimelineModal.vue`, `LeadContextSidebar.vue`: `isAdminForComments` → `hasRole('owner')` (antes leía objetos de `user.roles`, siempre falso).
- `ConversationsView.vue`: `!hasRole('owner') && !hasRole('admin')` → `... && !hasRole('supervisor')`.

**Migración:** ninguna (frontend).

**Checklist para quien despliega:**
- [ ] Confirmar que PR-A ya está desplegado en backend (permisos existen).
- [ ] Merge a `main` (front).
- [ ] Desplegar frontend **junto con PR-B**.
- [ ] Revisar menú por rol: asesor (sin Asesores/Marketing/Usuarios), supervisor (comercial amplio), owner (todo).

---

## PR-C — Borrar roles obsoletos + supervisor workflows.manage (DESTRUCTIVO)

**Rama:** `feature/SCRUM-1206-3` → **base:** `main` (app-saas-service)
> Solicitar **solo después** de que PR-B esté mergeado y tras **observar 1-2 días** en prod.
**Título:** `[SCRUM-1206] Roles: eliminar roles obsoletos + supervisor workflows.manage`

**Descripción:**
Fase final, **destructiva e irreversible** (el downgrade es no-op). Reasigna a los usuarios de los roles obsoletos a su rol destino y luego elimina los roles vacíos; además otorga `workflows.manage` a `supervisor` (único cambio aceptado del stakeholder respecto a la propuesta). Va al final, después de observar que el enforcement no quitó accesos indebidos.

**Qué incluye:**
- Migración `r4cleanuproles01`: reasigna `admin→owner`, `manager/gerencia/administrativo/gestion_creditos→supervisor`, `viewer/user→asesor`; luego borra los roles obsoletos. Idempotente.
- Migración `r5supervisorwf01`: `supervisor` gana `workflows.manage`.
- `rbac_seed_service`: `supervisor` con `workflows.view` + `workflows.manage`; `ROLE_DISPLAY_NAMES` con 4 claves.
- Tests `test_rbac_postventa.py` actualizados al modelo de 5 roles (10/10 pasan).

**Migración a correr en prod:**
```
alembic upgrade r5supervisorwf01      # encadena r4 (borrado/reasignación) + r5 (wf.manage)
```

**Antes de mergear (verificación read-only opcional en prod):**
```sql
SELECT r.name, COUNT(DISTINCT ur.user_id) usuarios
FROM roles r LEFT JOIN user_roles ur ON ur.role_id=r.id
WHERE r.name IN ('admin','manager','gerencia','gestion_creditos','administrativo','viewer')
GROUP BY r.name;
```

**Checklist para quien despliega:**
- [ ] Confirmar que PR-B lleva 1-2 días en prod sin reportes de accesos perdidos.
- [ ] (Opcional) Correr query de verificación read-only.
- [ ] Merge a `main`.
- [ ] `alembic upgrade r5supervisorwf01` en prod (reasigna y borra solo; sin script manual).
- [ ] Desplegar backend.
- [ ] Verificar que `supervisor` puede crear/editar workflows y que los roles obsoletos ya no aparecen.
- [ ] Huérfanos (si los hubiera): arreglar por `/dashboard/users`, no por script.
