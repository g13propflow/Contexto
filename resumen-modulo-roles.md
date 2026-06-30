# Módulo de Roles y Permisos (RBAC) — Resumen técnico

## Qué es

Sistema de control de acceso basado en roles y permisos (RBAC) que gobierna qué puede
ver y hacer cada usuario dentro de la plataforma. Los permisos se asignan a roles, los
roles a usuarios, y tanto el backend (FastAPI) como el frontend (Vue) consultan el
conjunto de permisos del usuario para gatear endpoints, rutas, menús y botones.

Está diseñado para ser **basado en permisos, no en nombres de rol**: salvo casos puntuales
(p. ej. `asesor_externo`), el código pregunta "¿tiene el permiso `leads.view`?" en lugar de
"¿es asesor?". Esto permite reconfigurar roles sin tocar código.

---

## Arquitectura

```
┌──────────────────────────────────────────────┐
│            Frontend (Vue 3)                    │
│  router meta.requiresPermission                │
│  sidebar filtra por can(permission)            │
│  directiva v-permission en botones             │
│  store RBAC ← /auth/me (roles + permissions)   │
└──────────────────┬─────────────────────────────┘
                   │ Authorization: Bearer + X-Tenant-ID
                   ▼
┌────────────────────────────────────────────────┐
│   app-saas-service (FastAPI)                    │
│   Depends(require_permission("leads.view"))     │
│   UserContext (cache: request → Redis → DB)     │
└──────────────────┬───────────────────────────────┘
                   ▼
┌────────────────────────────────────────────────┐
│   Modelo RBAC (SQL Server)                      │
│   User ─< UserRole >─ Role ─< RolePermission >─ │
│                              Permission ─ Module │
└────────────────────────────────────────────────┘
```

**Base de datos:** SQL Server (Azure).
**Permisos:** catálogo **global** (no por tenant).
**Roles:** **por tenant** — cada tenant tiene su propia copia de los roles de sistema.
**Multitenancy:** todo se aísla por `tenant_id`; no hay acceso cross-tenant salvo el flag
`users.is_system_admin` (rol de plataforma).

---

## Modelo de datos (`app/db/models_auth.py`)

| Modelo | Rol | Campos clave |
|---|---|---|
| `SystemModule` | Catálogo global de módulos | `name`, `display_name`, orden |
| `Permission` | Permiso global, agrupado por módulo | `name` (formato `modulo.accion`), `module_id` |
| `Role` | Rol **por tenant** | `tenant_id`, `name` (slug), `display_name`, `description`, `is_system` |
| `RolePermission` | Pivote rol↔permiso | `role_id`, `permission_id` (único por par) |
| `User` | Usuario | `tenant_id`, `is_system_admin`, `advisor_id`, `role` (legacy, deprecado) |
| `UserRole` | Pivote usuario↔rol | `role_id` (FK nuevo), `role_name` (legacy) — un usuario puede tener varios roles |

- Restricción única en `Role`: `(tenant_id, name)`.
- `is_system=True` marca los roles sembrados automáticamente (protegidos).
- `User.advisor_id` es la pieza que conecta un usuario con su ficha de asesor → base del
  scoping "solo sus leads/tareas".
- El campo `User.role` (string) y `UserRole.role_name` son **legacy/deprecados**; la fuente
  de verdad es `user_roles → role_id → role_permissions`.

---

## Roles actuales (11)

| Slug | Display | Categoría | Notas |
|---|---|---|---|
| `owner` | Owner | Admin | TODOS los permisos (aislado a su tenant) |
| `admin` | Administrador | Admin | TODOS los permisos |
| `system_admin` | System Admin | Plataforma | Acceso cross-tenant vía `is_system_admin` |
| `manager` | Manager | Operación | Comercial + postventa operativo |
| `asesor` | Asesor | Comercial | Solo sus leads/tareas (sin `view_all_advisors`) |
| `asesor_externo` | Asesor Externo | Comercial externo | Módulo limitado: `leads.view`, `leads.create` |
| `viewer` | Viewer | Solo lectura | Todos los `*.view` |
| `user` | User | Genérico | Fallback legacy |
| `supervisor` | Supervisor | **Solo postventa** | Validación supervisor + ver todos en postventa |
| `gerencia` | Gerencia | Postventa | Lectura + liberación de ubicación |
| `gestion_creditos` | Gestión de Créditos | Postventa | **Único rol con `postventa.validate`** (C-11) |
| `administrativo` | Administrativo | Postventa | Edición/carga/OCR + `postventa.admin` |

> **Importante:** `supervisor` hoy es un rol **exclusivo de postventa**, NO un rol comercial
> amplio. `gestion_creditos` es el único que valida crédito (`postventa.validate`), distinto
> de `postventa.supervisor_validate`.

**Dónde se siembran:**
- Lógica del mapeo: `app/services/rbac_seed_service.py` (`_build_permission_sets`, `ROLE_DISPLAY_NAMES`, `seed_tenant_roles`).
- Llamado desde `POST /tenants/` y `POST /auth/owner`.
- Backfill para tenants existentes: `alembic/versions/4dbc336a39ca_backfill_rbac_roles.py` (idempotente).

---

## Catálogo de permisos (~72, por módulo)

| Módulo | Permisos |
|---|---|
| `leads` | `view`, `create`, `edit`, `delete`, `view_all_advisors`, `reassign_advisor` |
| `contacts` | `view`, `create`, `edit`, `delete` |
| `advisors` | `view`, `create`, `edit`, `delete`, `manage_schedules` |
| `cotizaciones` | `view`, `create`, `edit`, `delete` |
| `calendario` | `view`, `create`, `edit`, `delete` |
| `tasks` | `view`, `view_all_advisors`, `create`, `edit`, `delete` |
| `advisor_whatsapp` | `view`, `view_all_advisors`, `manage` |
| `postventa` | `view`, `bitacora.view`, `edit`, `upload`, `ocr`, `advance_phase`, `validate`, `supervisor_validate`, `release_location`, `view_all_advisors`, `admin` |
| `collections` | `view`, `manage` |
| `settings` | `view`, `edit` |
| `users` | `view`, `invite`, `manage_roles` |
| `workflows` | `view`, `manage` (sembrados en la migración del módulo de workflows) |

**Convención:** `modulo.accion`. El sufijo `.view_all_advisors` distingue "ver todo el equipo"
de "ver solo lo mío"; sin él, el service filtra por `assigned_advisor_id`.

**Dónde se define el catálogo:** distribuido en migraciones Alembic
(`2ad15c07bd16_add_rbac_tables.py`, `a3b4c5d6e7f8_add_advisors_rbac_permissions.py`,
`b1c2d3e4f5a6_...add_tasks.py`, `aw01b2c3d4e5_advisor_whatsapp_init.py`,
`f0a17e571a01_postventa_init.py`, `g3pvcollrbac1_collections_rbac.py`, y la de workflows).

---

## Mapeo rol → permisos (actual)

Definido en `app/services/rbac_seed_service.py:39-111`:

| Rol | Permisos |
|---|---|
| `owner` / `admin` | **Todos** |
| `manager` | `leads.*` (sin `reassign_advisor`), `contacts.*`, `advisors.*`, `cotizaciones.*`, `calendario.*`, `tasks.*`, `advisor_whatsapp.*` (sin `manage`), postventa operativo + `supervisor_validate`, `collections.*` |
| `asesor` | `leads.view/create/edit`, `contacts.view/create/edit`, `advisors.view`, `cotizaciones.view/create/edit`, `calendario.view`, `tasks.view/create/edit`, `advisor_whatsapp.view`, postventa operativo (sin `view_all_advisors`) |
| `asesor_externo` | `leads.view`, `leads.create` (autoasigna a su propio asesor) |
| `viewer` | Todos los `*.view` + `*_all_advisors` de leads/tasks/whatsapp |
| `supervisor` | `postventa.view/bitacora.view/edit/upload/ocr/advance_phase/supervisor_validate/view_all_advisors/release_location` |
| `gerencia` | `postventa.view/bitacora.view/view_all_advisors/release_location` |
| `gestion_creditos` | `postventa.view/bitacora.view/validate` |
| `administrativo` | `postventa.view/bitacora.view/edit/upload/ocr/admin` |

> `seed_tenant_roles` **no sobreescribe** permisos de roles ya existentes (solo crea los que
> faltan). Cambiar el mapeo de un rol existente requiere una migración explícita.

---

## Enforcement en el backend

**Dependency principal:** `require_permission(*permissions)` — `app/api/dependencies.py:393-416`.
Carga el `UserContext`; si el usuario no tiene al menos uno de los permisos pedidos y no es
`system_admin`, lanza `403`.

```python
@router.post("/advisors")
async def create_advisor(
    _: User = Depends(require_permission("advisors.create")),
    ...
):
```

**Carga del UserContext** (`dependencies.py:22-130`) con cache en cascada:
1. `request.state.user_context` (intra-request)
2. Redis (TTL 300s)
3. BD: `rbac_repository.get_user_with_roles_and_permissions()` (un JOIN: user → roles → permisos)

**Dependencies legacy (deprecadas):** `require_role`, `require_roles` (chequean nombre de rol);
`require_system_admin` (solo `is_system_admin`).

**Multitenancy:** `tenant_id` viene del claim JWT `https://propflow.com/tenant_id` (Auth0
Post-Login Action), con fallback a `users.tenant_id`. Todas las queries filtran por `tenant_id`.

**Scoping "solo mis X":** los repositorios filtran por `assigned_advisor_id` cuando el rol no
tiene `view_all_advisors`. Implementado en `lead_repository`, `conversation_repository`,
`email_repository`. El `advisor_id` se obtiene de `User.advisor_id`.

---

## Enforcement en el frontend

**Fuente de permisos:** `/auth/me` devuelve `roles` y `permissions`; el store los carga
(`src/stores/auth.ts`, `src/stores/rbac.ts` → `initFromPermissions`).

**Helpers:** `usePermission()` → `can()`, `canAny()`, `canAll()`, `hasRole()`
(`src/composables/usePermission.ts`).

**Tres capas de gating:**
1. **Rutas** — `meta.requiresPermission` en `src/router/index.ts`.
2. **Sidebar** — `DashboardLayout.vue` filtra cada ítem por su `permission` (oculta el grupo si queda vacío).
3. **Botones/acciones** — directiva `v-permission="'leads.create'"` (soporta array OR y `.all` AND).

**Permisos por ruta (resumen):**

| Ruta | Permiso |
|---|---|
| `/dashboard/contacts` | `contacts.view` |
| `/dashboard/leads` | `leads.view` |
| `/dashboard/advisors`, `/advisor-chat` | `advisors.view` |
| `/dashboard/conversations` | `leads.view` |
| `/dashboard/tasks` | `tasks.view` |
| `/dashboard/advisor-performance` | `advisor_performance.view` |
| `/dashboard/quotation` | `cotizaciones.view` |
| `/dashboard/users` | `users.view` |
| `/dashboard/roles` | `users.manage_roles` |
| `/dashboard/workflows` | `workflows.view` |
| `/dashboard/postventa` | `postventa.view` |
| `/dashboard/postventa/configuracion` | `postventa.admin` |

**Rutas SIN gate de permiso (visibles para cualquiera dentro del dashboard):**
Dashboard home, **Properties/Proyectos**, Campaigns/Marketing, **Calls (llamadas)**,
**Emails (correos)**, Calendar (solo gateado en sidebar), Distribution Lists, Connections,
Activity Log, FHA, Bank, Legal (form templates), Collections, Downloads, Notifications.

**Caso especial por nombre de rol — `asesor_externo`** (único rol hardcodeado en frontend):
- Sidebar: oculta navegación estática (`DashboardLayout.vue`).
- Router (`index.ts:509-518`): restringe el acceso a `/dashboard/leads` y `/dashboard/conversations`; cualquier otra ruta redirige a `/dashboard/leads`.

---

## Multitenancy y cross-tenant

- Cada tabla tiene `tenant_id`; todas las queries lo filtran.
- **No existe un concepto de Owner cross-tenant.** `owner` tiene todos los permisos pero
  sigue **aislado a su propio tenant**.
- El único acceso a múltiples tenants es el flag `users.is_system_admin` (rol de plataforma
  `system_admin`), validado por `require_system_admin()`.

---

## Archivos principales

### Backend (`app-saas-service`)
| Archivo | Rol |
|---|---|
| `app/db/models_auth.py` | Modelos `SystemModule`, `Permission`, `Role`, `RolePermission`, `User`, `UserRole` |
| `app/services/rbac_seed_service.py` | Mapeo rol→permisos + siembra de roles por tenant |
| `app/api/dependencies.py` | `require_permission`, `require_role(s)` (legacy), `require_system_admin`, carga de `UserContext` |
| `app/db/repositories/rbac_repository.py` | Query de usuario con roles y permisos |
| `alembic/versions/2ad15c07bd16_add_rbac_tables.py` | Tablas RBAC + catálogo inicial |
| `alembic/versions/4dbc336a39ca_backfill_rbac_roles.py` | Backfill de roles a tenants existentes |
| (varias migraciones por módulo) | Permisos de advisors, tasks, whatsapp, postventa, collections, workflows |

### Frontend (`app-saas-frontend`)
| Archivo | Rol |
|---|---|
| `src/router/index.ts` | Gating de rutas (`meta.requiresPermission`) + caso `asesor_externo` |
| `src/layouts/DashboardLayout.vue` | Sidebar filtrado por permiso |
| `src/stores/auth.ts`, `src/stores/rbac.ts` | Carga y estado de roles/permisos |
| `src/composables/usePermission.ts` | `can()`, `canAny()`, `canAll()`, `hasRole()` |
| `src/directives/permission.ts` | Directiva `v-permission` |

---

## Notas y observaciones

- El sistema es **permission-based**: para reconfigurar roles basta cambiar el mapeo y migrar
  datos; el código no suele necesitar cambios salvo donde falten permisos.
- **Brechas conocidas** (relevantes para futuros cambios de roles):
  - No existe módulo de permisos para **Proyectos** (la ruta de propiedades está sin gate; no
    hay distinción vista vs. edición).
  - **Conversaciones, llamadas, correos y marketing** no tienen permiso propio (siempre visibles).
  - No hay rol **"Aprobación Meta"** en RBAC; "aprobación Meta" en el código se refiere a la
    aprobación de plantillas de WhatsApp, no a un rol de usuario.
  - **Owner no es cross-tenant** hoy.
- Los roles de postventa (`gerencia`, `gestion_creditos`, `administrativo`) tienen permisos
  distintos y críticos; en particular `gestion_creditos` es el único con `postventa.validate`.
