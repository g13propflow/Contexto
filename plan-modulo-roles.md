# Plan — Consolidación de Roles y Permisos (RBAC)

> 🚨 **ACCIÓN INMEDIATA (independiente del proyecto)** — usuarios sin rol moderno (`user_roles`)
>
> Verificado en `PropFlow_Gerardo` (2026-06-25): **10 usuarios sin fila en `user_roles`**. Como NO hay fallback a `users.role` (§1.9), un usuario **activo** sin rol recibe 403 en casi todo el backend. **Pero `is_active` cambia el cuadro** — la mayoría de los "internos" están inactivos:
> - **Inactivos (NO tocar — están deshabilitados):** `carlos@`, `manuel@`, `angela@`, `johanna@gopropflow.com` (tenant_dpb).
> - **Activos externos reales → ✅ HECHO (2026-06-25):** `javierantoneo@gmail.com` (role_id 31) y `propflowuser@paloblanco.com` (role_id 81) → `owner` asignado en `PropFlow_Gerardo`.
> - **Activo interno → PENDIENTE confirmación:** **`javier@gopropflow.com`** (tenant_8542…, legacy owner) → asignar rol `owner` (existe, role_id 41). *(Falta OK explícito.)*
> - **Prueba (no asignar / desactivar):** `seyave6933@cexch.com`, `xahese9331@cexch.com`, `ssocm2@miumg.edu.gt`.
> - **Inactivos (NO tocar):** `carlos@`, `manuel@`, `angela@`, `johanna@gopropflow.com`.
>
> Lección: el supuesto previo ("4 internos en 403") era incorrecto — 3 de esos 4 están inactivos. **No asignar roles a cuentas inactivas ni de prueba.**
>
> ⚠️ **Hallazgo latente (ticket aparte):** `users.is_active` **NO se enforce** en el backend (solo se lee en `dependencies.py:88`, nunca bloquea). Un desactivado con token + rol podría seguir llamando la API. Recomendado: `if not ctx.is_active → 403` en `_load_user_context`. Reactivar sin asignar rol = 403 (sin permisos), así que reactivar **debe** ir acompañado de asignación de rol en la pantalla de Usuarios.

---

> **Objetivo del negocio:** reducir y consolidar a **5 roles** (Owner, Asesor, Asesor Externo, Supervisor, Aprobación Meta). Los datos de producción (§1.8, 2026-06-24) confirman que es la meta correcta: **todos los roles a eliminar tienen 0 usuarios** y `gestion_creditos` —aunque existe en los 19 tenants— **tampoco se usa**, por lo que la "segregación de funciones" no es un control activo. `gestion_creditos` se mantiene como **6º rol OPCIONAL**, solo si el negocio decide *operar a futuro* la validación de crédito separada. ⚠️ Pendiente real: **10 usuarios sin rol moderno** que hay que triar antes de borrar nada (§1.8).
>
> **Estado:** plan aprobado por el equipo interno (Gerardo), **a la espera de respuestas del stakeholder** (ver §7) antes de iniciar desarrollo.
>
> Este documento es **autocontenido**: incluye lo investigado del sistema actual para no tener que re-explorar. Última actualización: 2026-06-24.

---

## 0. Decisiones ya tomadas (internas)

| Tema | Decisión | Nota |
|---|---|---|
| **Owner cross-tenant** | ✅ **CONFIRMADO (2026-06-25):** Owner = todos los permisos pero **aislado a su propio tenant** (NO cross-tenant). | Evidencia prod: **13 owners en 19 tenants** → es un owner **por cliente**, no interno; darle cross-tenant expondría datos entre clientes. El literal "de todos los tenants" del ask **no se entrega** a propósito (riesgo de aislamiento). Si más adelante lo quieren, se cambia después (flip `is_system_admin` o membresía multi-tenant). Cross-tenant sigue exclusivo de `system_admin`. |
| **Supervisor** | Reusar el slug `supervisor` y **ampliarlo** (absorbe `manager` + postventa). | Recortado solo en `manage_roles` (exclusivo de owner). **`workflows.manage` SÍ** (pedido del stakeholder). Ver §3. |
| **Aprobación Meta** | Rol **custom en BD**, NO sembrado. **No se toca.** | No es `is_system`. La migración de borrado NO debe tocarlo. |
| **Roles sobrantes** | **Migrar usuarios y luego eliminar**, en **dos despliegues** (ver §5 Fase 4). | |
| **`gestion_creditos`** | **6º rol OPCIONAL.** Existe en prod pero con **0 usuarios** → por defecto se **borra**. Solo se conserva si el negocio va a operar validación de crédito separada. | Si se omite, `postventa.validate` lo absorbe Supervisor. |
| **`system_admin`** | **Conservar** (rol de plataforma cross-tenant del equipo dev). | Aunque no sea un rol "de negocio". 1 usuario en prod. |

---

## 1. Investigación del sistema actual (snapshot)

### 1.1 Arquitectura RBAC
- Sistema **basado en permisos, no en nombres de rol**. El código pregunta "¿tiene `leads.view`?", no "¿es asesor?". Única excepción hardcodeada: `asesor_externo` en el frontend.
- **Permisos**: catálogo **global** (no por tenant), formato `modulo.accion`.
- **Roles**: **por tenant** — cada tenant tiene su copia de los roles de sistema. Constraint único `(tenant_id, name)`. `is_system=True` marca los sembrados (protegidos).
- **Multitenancy**: todo aislado por `tenant_id`. Único acceso cross-tenant = flag `users.is_system_admin`.
- **`User.advisor_id`** conecta usuario ↔ ficha de asesor → base del scoping "solo sus leads/tareas".
- `User.role` (string) y `UserRole.role_name` son **legacy/deprecados**; la fuente de verdad es `user_roles → role_id → role_permissions`.

### 1.2 Modelo de datos — `app-saas-service/app/db/models_auth.py`
| Modelo | Líneas aprox. | Campos clave |
|---|---|---|
| `SystemModule` | 15-39 | `name`, `display_name`, orden (catálogo global) |
| `Permission` | 42-71 | `name` (`modulo.accion`), `module_id` |
| `Role` | 77-107 | `tenant_id`, `name`, `display_name`, `is_system` |
| `RolePermission` | 109-135 | `role_id`, `permission_id` (único por par) |
| `User` | 175-223 | `tenant_id`, `is_system_admin`, `advisor_id`, `role` (legacy) |
| `UserRole` | 225-253 | `role_id` (FK nuevo), `role_name` (legacy) — un usuario puede tener varios roles |

`UserRoleName` (enum, líneas ~137-156): `admin, owner, system_admin, asesor, asesor_externo, viewer, user, supervisor, gerencia, gestion_creditos, administrativo`.

### 1.3 Roles actuales (11) y su mapeo de permisos
Definidos en `app/services/rbac_seed_service.py` (`_build_permission_sets`, líneas ~39-111; `ROLE_DISPLAY_NAMES`; `seed_tenant_roles` ~129-175).

| Slug | Display | Categoría | Permisos (resumen) |
|---|---|---|---|
| `owner` | Owner | Admin | **Todos** (aislado a su tenant) |
| `admin` | Administrador | Admin | **Todos** |
| `system_admin` | System Admin | Plataforma | Cross-tenant vía `is_system_admin` |
| `manager` | Manager | Operación | Comercial completo + postventa operativo + `supervisor_validate` + `collections.*`; SIN `leads.reassign_advisor` ni `advisor_whatsapp.manage` |
| `asesor` | Asesor | Comercial | `leads.view/create/edit`, `contacts.view/create/edit`, `advisors.view`, `cotizaciones.view/create/edit`, `calendario.view`, `tasks.view/create/edit`, `advisor_whatsapp.view`, postventa operativo (sin `view_all_advisors`) |
| `asesor_externo` | Asesor Externo | Comercial ext. | `leads.view` (+`leads.create` por migración); solo sus leads |
| `viewer` | Viewer | Solo lectura | Todos los `*.view` + `*_all_advisors` de leads/tasks/whatsapp |
| `user` | User | Genérico | Fallback legacy |
| `supervisor` | Supervisor | **Solo postventa** | `postventa.view/bitacora.view/edit/upload/ocr/advance_phase/supervisor_validate/view_all_advisors/release_location` |
| `gerencia` | Gerencia | Postventa | `postventa.view/bitacora.view/view_all_advisors/release_location` |
| `gestion_creditos` | Gestión de Créditos | Postventa | `postventa.view/bitacora.view/validate` — **único con `postventa.validate`** |
| `administrativo` | Administrativo | Postventa | `postventa.view/bitacora.view/edit/upload/ocr/admin` |

> ⚠️ `supervisor` HOY es exclusivo de postventa, NO un rol comercial amplio.
> ⚠️ `seed_tenant_roles` **NO sobreescribe** permisos de roles ya existentes (solo crea los que faltan). **Cambiar el mapeo de un rol existente requiere una migración explícita.**

### 1.4 Catálogo de permisos actual (~72)
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
| `workflows` | `view`, `manage` |
| `advisor_performance` | `view` |

Convención: sufijo `.view_all_advisors` = "ver todo el equipo"; sin él, el service filtra por `assigned_advisor_id`.

### 1.5 Enforcement backend
- **Dependency principal:** `require_permission(*permissions)` — `app/api/dependencies.py:393-416`. OR-logic; bypass si `is_system_admin`. Lanza 403.
- **UserContext** (`dependencies.py:22-130`): cache en cascada request → Redis (TTL 300s) → BD (`rbac_repository.get_user_with_roles_and_permissions()`, `app/db/repositories/rbac_repository.py:197-243`, un JOIN).
- **Legacy (deprecado):** `require_role(s)` (por nombre), `require_system_admin`.
- **Scoping "solo mis X":** `app/core/leads_access.py` → `resolve_lead_advisor_filter()`, `can_view_all_leads()`, `assert_lead_visible()`. Repositorios filtran por `assigned_advisor_id`. Implementado en `lead_repository`, `conversation_repository`, `email_repository`. **Falta verificar `calls`.**

### 1.6 Enforcement frontend (`app-saas-frontend`)
- Permisos vienen de `/auth/me` → `src/stores/auth.ts` + `src/stores/rbac.ts` (`initFromPermissions`).
- Helpers: `usePermission()` → `can()`, `canAny()`, `canAll()`, `hasRole()` (`src/composables/usePermission.ts`).
- 3 capas de gating:
  1. **Rutas** — `meta.requiresPermission` en `src/router/index.ts`.
  2. **Sidebar** — `src/layouts/DashboardLayout.vue` filtra cada ítem por su `permission`.
  3. **Botones** — directiva `v-permission` (`src/directives/permission.ts`), soporta array OR y `.all`.
- **Caso hardcodeado `asesor_externo`** (`router/index.ts:509-518`): solo accede a `/dashboard/leads` y `/dashboard/conversations`; cualquier otra ruta → redirige a leads.
- Admin de roles: `src/views/RolesView.vue` (`/dashboard/roles`, requiere `users.manage_roles`); usuarios: `src/views/UsersView.vue`.

### 1.7 Brechas detectadas (clave para este proyecto)
- **Proyectos/Properties**: rutas SIN gate de permiso; **no existe módulo `projects` ni distinción vista/edición**.
- **Llamadas, correos, marketing, conversaciones**: rutas/menú sin permiso propio (correos/conversaciones se cubren con `leads.view` en algunos puntos).
- **Chat asesores** (`/dashboard/advisor-chat`) comparte `advisors.view` con la **gestión de asesores** → no se pueden separar hoy.
- **"Aprobación Meta"** NO es un rol sembrado (en código, "aprobación Meta" = aprobación de plantillas WhatsApp). El rol del negocio es **custom en BD**.
- **Owner NO es cross-tenant** hoy.

### 1.8 Roles EN USO — datos de producción (consulta + verificación 2026-06-24)

Conteo real de asignaciones en `user_roles` (fuente de verdad) sobre **19 tenants**:

| Rol | usuarios | tenants | Lectura |
|---|---:|---:|---|
| `owner` | 13 | 19 | **Muy en uso** — el rol operativo real |
| `asesor` | 2 | 19 | En uso |
| `asesor_externo` | 2 | 19 | En uso |
| `admin` | 1 | 19 | En uso (1 persona, vía `user_roles`) → migrar a `owner` |
| `aprobacion_meta` | 1 | **1** | En uso; 1 solo tenant (`tenant_dpb`) → **CUSTOM confirmado**. Slug: `aprobacion_meta`. Permisos: `leads.view` + `leads.view_all_advisors` (ve TODOS los leads del tenant, solo lectura) |
| `supervisor` | 0 | 19 | Existe, **0 usuarios** → se redefine libremente |
| `manager` | 0 | 19 | **Existe** (verificado: 19 filas), **0 usuarios** → borrar |
| `gestion_creditos` | 0 | 19 | **Existe** (verificado: 19 filas), **0 usuarios** → borrar (salvo Q1) |
| `viewer` | 0 | 19 | Existe, **0 usuarios** → borrar |
| `gerencia` | 0 | 19 | Existe, **0 usuarios** → borrar |
| `administrativo` | 0 | 19 | Existe, **0 usuarios** → borrar |

> ⚠️ **Corrección:** una transcripción previa estaba recortada y di por hecho que `manager`/`gestion_creditos` no existían. La verificación (consulta #1) confirma que **sí existen en los 19 tenants, con 0 usuarios**. No cambia la recomendación (siguen sin usarse), pero **sí deben incluirse en el borrado**.

**Hallazgo nuevo y relevante — 10 usuarios SIN rol moderno (consultas #2/#3):**
Hay **10 usuarios** sin ninguna fila en `user_roles` (no tienen rol RBAC asignado). Tienen rol solo en la columna legacy `users.role`. Incluye **cuentas internas reales**:
- `tenant_dpb`: `carlos@gopropflow.com`, `manuel@gopropflow.com`, `angela@gopropflow.com` (legacy `admin`)
- Varios `owner` legacy: `javier@gopropflow.com`, `javierantoneo@gmail.com`, y cuentas de prueba (`*@cexch.com`, `*@mium.edu.qt`)

→ **Esto NO es trivial.** Estos usuarios hoy obtienen acceso (si lo obtienen) por algún fallback a `users.role`, no por RBAC. Al consolidar hay que **decidir explícitamente** qué rol moderno se les asigna, o quedan sin permisos. **Acción**: verificar en código si existe fallback `users.role` → permisos (revisar `rbac_repository` / flujo `/auth/me`); triar internos (→ `owner`/`asesor`) vs. cuentas de prueba (ignorar/desactivar).

**Quién tiene `postventa.validate` hoy (consulta #4):** en cada tenant, los roles `admin`, `owner` y `gestion_creditos`. Como `gestion_creditos` tiene 0 usuarios, en la práctica **solo owner/admin validan crédito** → confirma que la separación de funciones NO está operativa. Reafirma **ir con 5 roles**.

**Otros hallazgos:**
- `user_roles` con `role_id` NULL (legacy por nombre): **0 registros** → las asignaciones modernas que existen están limpias.
- Columna deprecada `users.role`: admin=10, owner=8, system_admin=1, user=10 → **desincronizada** con `user_roles`; pero es la única fuente de rol para los 10 usuarios huérfanos de arriba. No ignorar del todo hasta resolver esos 10.
- `users.is_system_admin = 1`: **1 usuario** (super-admin de plataforma).

**Implicaciones para el plan:**
1. **Migración de roles asignados: mínima** — solo **1 usuario** (`admin` vía `user_roles`) → `owner`.
2. **Migración de huérfanos: requiere triage** — 10 usuarios sin rol moderno; mapear los internos antes de borrar nada.
3. **Roles a borrar (todos con 0 usuarios, todos existen):** `admin`, `manager`, `gestion_creditos`*, `viewer`, `gerencia`, `administrativo`. (*`gestion_creditos` solo se conserva si Q1 lo confirma.)
4. **`hasRole('manager')` en `TabFinanciamiento.vue:158`** es código inerte (el rol existe pero nadie lo tiene) → limpiar al migrar.
5. **`aprobacion_meta`** = ver todos los leads (read-only) en `tenant_dpb`. Conservar intacto; al gatear el módulo de leads, asegurarse de no romper este combo `leads.view` + `leads.view_all_advisors`.

### 1.9 ¿Existe fallback `users.role` → permisos? (investigación de código 2026-06-24)

**Respuesta: NO hay fallback general.** `_load_user_context` (`app/api/dependencies.py:59-94`) construye el contexto desde `get_user_with_roles_and_permissions` (`app/db/repositories/rbac_repository.py:197-243`), que arma `permissions`/`role_names` **solo iterando `user.user_roles`**. Sin filas en `user_roles` → `permissions = set()` y `role_names = []`. **Nunca** consulta `users.role` como respaldo.

Comportamiento de un usuario huérfano (solo `users.role`, sin `user_roles`) por mecanismo:

| Mecanismo | Lee de | Huérfano | ¿En uso? |
|---|---|---|---|
| `require_permission(*perms)` (`dependencies.py:393`) | `ctx.permissions` ← user_roles | **403** (salvo `is_system_admin`) | Sí — mayoría del backend moderno |
| `require_roles(*roles)` plural (`dependencies.py:356`) | `ctx.role_names` ← user_roles | **403** (sin bypass `owner`) | Sí — endpoints legacy |
| `require_role(*roles)` singular (`dependencies.py:301`) | `user.role` (columna legacy) | (funcionaría) | **NO — código muerto**, 0 endpoints lo usan |
| Checks ad-hoc `current_user.role in (...)` | `user.role` legacy | Funciona | Solo 2 sitios: `lead_comments.py:322`, `files.py:141/185` |

**Conclusiones:**
1. **Los 10 usuarios huérfanos ya están rotos hoy:** quedan en 403 en casi todo el backend moderno (`require_permission`/`require_roles`). No es un riesgo que el proyecto introduzca; es un **bug de datos preexistente**.
2. **No hay fallback que "quitar"** — quitar `users.role` no rompe nada nuevo (salvo los 2 checks ad-hoc).
3. **Acción del proyecto (pre-requisito de la migración):** **backfill de `user_roles`** para los usuarios internos huérfanos (asignar rol moderno: admin→`owner`, etc.). Las cuentas de prueba se desactivan.
4. **Limpieza de legacy (Fase 3):** migrar los 2 checks ad-hoc (`lead_comments.py:322` is_admin, `files.py`) a `require_permission`/`ctx`; eliminar el `require_role` singular (muerto). Tras esto, `users.role` queda solo informativa (`auth.py:276`).
5. **Ojo de orden:** primero el backfill (#3), luego la limpieza de legacy (#4). Si se invierte, los huérfanos pierden hasta el acceso residual.

---

## 2. Roles objetivo (5 de negocio + 1 opcional + 1 de plataforma)

| Rol | Acción | Naturaleza |
|---|---|---|
| `owner` | Sin cambios | Todos los permisos, su tenant |
| `asesor` | **Redefinir permisos** | Operativo, "solo lo suyo" |
| `asesor_externo` | Sin cambios | Mínimo, solo sus leads |
| `supervisor` | **Ampliar (recortado)** — redefinir libre (0 usuarios) | Techo **operativo/comercial**, NO administrativo |
| `aprobacion_meta` (custom) | Sin cambios | Custom del tenant (1 usuario, 1 tenant) |
| `system_admin` | **Conservar** (no es de negocio) | Plataforma / equipo dev (1 usuario) |
| `gestion_creditos` | **OPCIONAL** — por defecto NO se crea | Solo si el negocio va a operar validación de crédito separada (§7-A Q1) |

**Eliminar (todos existen, todos con 0 usuarios):** `admin` (migrar su 1 usuario → `owner`), `manager`, `gestion_creditos`*, `viewer`, `gerencia`, `administrativo`.
\* `gestion_creditos` solo se conserva si Q1 lo confirma.
> **Default = 5 roles.** Con los datos de prod no hay segregación de funciones activa que preservar. ⚠️ Antes de borrar: resolver los **10 usuarios sin rol moderno** (§1.8) — varios son cuentas internas reales.

---

## 3. Sets de permisos objetivo (CON recomendaciones aplicadas)

### `asesor` — todo "solo lo suyo", sin ningún `view_all_advisors`
```
projects.view
leads.view
contacts.view / contacts.create / contacts.edit
cotizaciones.view  (+ create/edit → PENDIENTE stakeholder Q4)
calendario.view
tasks.view / tasks.create / tasks.edit
calls.view
emails.view
advisor_chat.view
postventa.view / postventa.bitacora.view / postventa.edit / postventa.upload / postventa.ocr / postventa.advance_phase
```
Conversaciones = vía `leads.view` (sub-recurso). **NO** recibe: `advisors.view`, marketing, users/roles, workflows, `projects.edit`, `postventa.admin`, ni ningún `*_all_advisors`.

### `supervisor` — amplio pero **recortado de poderes administrativos** (recomendación clave)
```
projects.view / projects.edit
leads.view / leads.create / leads.edit / leads.view_all_advisors / leads.reassign_advisor
contacts.view / create / edit
advisors.view / create / edit / manage_schedules
advisor_performance.view
cotizaciones.view / create / edit
calendario.view / create / edit
tasks.view / create / edit / tasks.view_all_advisors
calls.view / calls.view_all_advisors
emails.view / emails.view_all_advisors
advisor_chat.view
advisor_whatsapp.view / advisor_whatsapp.view_all_advisors / advisor_whatsapp.manage
marketing.view
postventa.*  COMPLETO por defecto (view, bitacora.view, edit, upload, ocr, advance_phase,
              validate, supervisor_validate, release_location, view_all_advisors, admin)
              ↳ si se crea gestion_creditos (Q1): QUITAR `validate` de Supervisor
collections.view / collections.manage
users.view / users.invite          ← SIN users.manage_roles
workflows.view / workflows.manage   ← workflows.manage SÍ (pedido del stakeholder)
settings.view / settings.edit
```
> **Recomendaciones aplicadas (vs. lo pedido originalmente):**
> - ❌ **Sin `users.manage_roles`**: el Supervisor puede invitar gente pero **no** cambiar roles/permisos. Esto evita que se auto-escale o le quite acceso al Owner. La gestión de roles queda como competencia exclusiva del Owner.
> - ✅ **Con `workflows.manage`** (crear/editar workflows): agregado por **pedido del stakeholder** (revierte la recomendación inicial; aplicado en migración `r5supervisorwf01`). `users.manage_roles` sí sigue exclusivo de owner.
> - 📌 **`postventa.*` completo (incl. `validate`) por defecto**: como en prod nadie usa `gestion_creditos`, el Supervisor absorbe toda la operación de postventa, incluido *validar crédito*. **Solo** si el stakeholder decide operar la separación (Q1), se crea `gestion_creditos` y se **quita `validate`** del Supervisor.

### `owner`
Todos los permisos (incluye los nuevos de §Fase 1). **Verificar** que al crear permisos nuevos también se asignen a owner en el seed.

### `gestion_creditos` (OPCIONAL — solo si Q1 lo confirma)
Por defecto **NO se crea** (no existe en prod, 0 usuarios → no hay control que preservar). Si el negocio decide operarlo: set `postventa.view`, `postventa.bitacora.view`, `postventa.validate`; sería el **único** con `postventa.validate` y entonces hay que **quitar `validate` del Supervisor** para que la separación validar-crédito / aprobar-expediente sea real.

### `asesor_externo` / `Aprobación Meta`
Sin cambios.

---

## 4. Permisos/módulos NUEVOS a crear

| Módulo nuevo | Permisos | Enforcement backend real? |
|---|---|---|
| `projects` | `projects.view`, `projects.edit` | **Sí** — gatear rutas de properties + escritura. Vista vs edición. |
| `calls` | `calls.view`, `calls.view_all_advisors` | **Sí — CRÍTICO** — filtrar por `assigned_advisor_id`. Verificar que el endpoint hoy no filtra. |
| `emails` | `emails.view`, `emails.view_all_advisors` | **Sí** — verificar filtro existente en `email_repository`. |
| ~~`advisor_chat`~~ | — | ❌ **NO crear.** El backend ya gatea chat asesores con `advisor_whatsapp.view` (`advisor_chat.py`, 11 endpoints) y el `asesor` ya lo tiene. Solo cambiar el gate de la **ruta frontend** (hoy `advisors.view`) → `advisor_whatsapp.view`. Ver §9-B. |
| `marketing` | `marketing.view` | **Opcional** — ver §7-Q5: ¿prohibido (backend) o solo oculto en menú? |

> **Principio de diseño (recomendación):** invertir en enforcement de **backend** solo donde hay **datos de leads ajenos** (`calls`, `emails`, conversaciones) o **edición** (`projects.edit`). Para "marketing no aparece en el menú del asesor", evaluar si basta con ocultarlo en el sidebar (cosmética) sin permiso de backend. El frontend NO es seguridad.
> **Ajuste tras §9:** `advisor_chat` se elimina de los permisos nuevos (se reutiliza `advisor_whatsapp.view`) → un módulo nuevo menos.

---

## 5. Fases de implementación

### Fase 1 — Catálogo RBAC: permisos nuevos (migración Alembic) — ✅ HECHA (2026-06-25)
Migración `alembic/versions/r1projcallemail01_add_projects_calls_emails_marketing_rbac.py` (down_revision `c5d6e7f8a9b1`). Crea módulos `projects/calls/emails/marketing` + permisos y los asigna: owner+supervisor = todos; asesor = `projects.view`/`calls.view`/`emails.view`. `advisor_chat` NO se creó (reusa `advisor_whatsapp.view`, §9-B).
- ✅ Aplicada y verificada en `PropFlow_Gerardo` (19 tenants) vía script idempotente (alembic no está en PATH; el archivo es el artefacto de prod).
- ⚠️ **Alembic tiene 18 heads sin mergear** → el deploy a prod debe usar la convención del equipo (`upgrade heads` o merge previo). `alembic upgrade head` singular fallaría.
- ⏳ Pendiente prod: correr la migración en la BD productiva.

### Fase 2 — Redefinir sets de `asesor` y `supervisor` — ✅ HECHA (2026-06-25)
- `rbac_seed_service.py` `_build_permission_sets()`: `asesor` y `supervisor` redefinidos (tenants nuevos).
- Migración `alembic/versions/r2redefasessup01_redefine_asesor_supervisor_perms.py` (down_revision `r1projcallemail01`): **reemplazo atómico** (delete+insert) de `role_permissions` para `asesor`/`supervisor` existentes, con `downgrade` que restaura los sets previos.
- ✅ Aplicada y verificada en `PropFlow_Gerardo` (uniforme, 19 tenants): asesor=23 perms (sin advisors.view / view_all / projects.edit / marketing), supervisor=51 perms (con view_all/edit/marketing/postventa completo; **sin** manage_roles). **+ `workflows.manage`** agregado luego por pedido del stakeholder (migración `r5supervisorwf01`).
- ⚠️ **A verificar en Fase 6:** el `asesor` ya **no** tiene `advisors.view` (antes sí). Si algún componente del front del asesor depende de listar asesores (dropdowns), habrá que darle un permiso de lookup más fino o reintroducir read-only.
- ⏳ Pendiente prod: correr la migración.

### Fase 3 — Enforcement backend — ✅ HECHA (2026-06-25, rama `feature/SCRUM-1206-2`)
Toda en `app-saas-service`. Compila (`py_compile`). 5 bloques:
- **B1 Llamadas** (`calls.py`): gate `require_permission("calls.view")`; scoping por `calls.view_all_advisors`. Generalicé `resolve_advisor_id_list_filter`/`can_view_all` en `core/leads_access.py` con parámetro `view_all_perm` (retrocompatible).
- **B2 Correos** (`emails.py`, 10 endpoints): `require_roles("admin","asesor")` → `require_permission("emails.view")`; "ve todo" derivado de `emails.view_all_advisors` vía **puente** (sin tocar `email_service.py`). → supervisor ya entra.
- **B3 Proyectos/Properties** (`projects.py`, `properties.py`): factory nueva `require_method_permission(read, write)` en `dependencies.py` → gate **a nivel de router** (GET=`projects.view`, POST/PUT/DELETE=`projects.edit`). Cubre ~32 endpoints sin tocar firmas.
- **B4 Marketing** (`campaigns.py`, `distribution_lists.py`, `email_campaigns.py` — 4 routers): gate `marketing.view` a nivel de router. → asesor fuera de marketing.
- **B5 Invitaciones/admin**: `invitations.py` + `auth.py /invite` → `require_permission("users.invite")` (supervisor invita); `admin_notifications.py`/`audit_log.py`/`email_config.py` → `require_roles("owner")` (owner-only).
- ⏳ **Pendiente**: tests de seguridad ("asesor que pega `GET /calls` no ve ajenas"), correr en local con usuarios por rol (Fase 6).
- 🔸 **Diferido (cleanup aparte):** `lead_comments.py:322` y `files.py` leen `current_user.role` (columna legacy) para "moderar/override" — necesitan permisos propios fuera del alcance de la consolidación; NO tocados.

### Fase 4 — Borrar roles + reasignar — ✅ HECHA en dev (2026-06-25, rama `feature/SCRUM-1206-3`, commit `c3439242`)
- Migración `alembic/versions/r4cleanuproles01_remove_consolidated_roles.py` (down_revision `r2redefasessup01`): reasigna (admin→owner, manager/gerencia/administrativo/gestion_creditos→supervisor, viewer/user→asesor) y borra por allowlist.
- `rbac_seed_service.py`: el seed solo crea owner/asesor/asesor_externo/supervisor.
- ✅ Aplicada en `PropFlow_Gerardo`. Estado final verificado: **owner(17), asesor(2), asesor_externo(2), supervisor(0) + aprobacion_meta(1, custom)**. Eliminados admin/manager/gerencia/gestion_creditos/administrativo/viewer.
- ⏳ **Prod: aplicar al FINAL** (es destructiva; ver dos-despliegues abajo), después de Fases 1-2-3.

Según datos de prod (§1.8): los roles a eliminar tienen **0 usuarios** salvo `admin` (1). El trabajo real está en los **10 usuarios sin rol moderno**.

**4a. Reasignación de usuarios CON rol moderno** (`user_roles.role_id`):
| Rol viejo | usuarios | → Destino |
|---|---:|---|
| `admin` | 1 | `owner` |
| `manager`, `gestion_creditos`*, `viewer`, `gerencia`, `administrativo` | 0 | (sin usuarios → solo borrar el rol) |

**4b. Triage de los 10 usuarios SIN rol moderno** (solo en `users.role`):
- **Internos** (`carlos`/`manuel`/`angela@gopropflow.com` = admin legacy; `javier@gopropflow.com` = owner legacy): asignar rol moderno explícito (admin→`owner`, etc.) creando su fila en `user_roles`.
- **Cuentas de prueba** (`*@cexch.com`, `*@mium.edu.qt`): confirmar con el equipo si se desactivan/borran.
- **Pre-requisito (confirmado en §1.9):** NO hay fallback `users.role` → permisos; estos usuarios ya están en 403 en el backend moderno. El backfill de `user_roles` debe hacerse **antes** de limpiar los checks legacy ad-hoc (`lead_comments.py`, `files.py`).

- **Despliegue 1:** crear permisos, redefinir `asesor`/`supervisor`, ejecutar 4a + 4b. Roles a eliminar quedan **vivos pero ocultos en UI** y no asignables. Observar 1–2 semanas.
- **Despliegue 2:** confirmado que nadie quedó huérfano → **borrar** por **allowlist** (`admin`, `manager`, `gestion_creditos`*, `viewer`, `gerencia`, `administrativo`): `role_permissions` → `user_roles` huérfanos → `roles`.
- ⚠️ **NO tocar** `asesor_externo`, `aprobacion_meta` (custom), `system_admin`, ni `gestion_creditos` si Q1 decide conservarlo.

### Fase 5 — Frontend — ✅ HECHA (2026-06-25, repo `app-saas-frontend`, rama `feature/SCRUM-1206-4`, commits `a5b8633` + `1cbbdf9`)
- `router/index.ts`: `requiresPermission` en properties(`projects.view`)/calls(`calls.view`)/emails(`emails.view`)/campaigns(`marketing.view`); **advisor-chat `advisors.view` → `advisor_whatsapp.view`** (fix regresión asesor — el backend ya gateaba chat con advisor_whatsapp.view); guard: sub-rutas `/dashboard/projects/*` exigen `projects.view`.
- `DashboardLayout.vue`: `permission` en Llamadas/Correos/Chat asesores/Marketing (nav agrupado).
- `ProjectsView.vue`: `v-permission="'projects.edit'"` en botones crear/editar/eliminar.
- `EmailsView`/`ComposeModal`: `isAdmin` `roles.includes('admin')` → `can('emails.view_all_advisors')` (fix regresión por borrado del rol admin).
- El caso `asesor_externo` se mantiene igual.
- 🔸 **Pendiente menor (polish; backend ya protege):** botones editar/eliminar dentro del componente `ProjectsTable` (vista tabla); checks `'admin'`/`'manager'` muertos-pero-inofensivos en `ConversationsView`/`TasksListView`/`TaskForm`/`LeadTimelineModal`/`LeadContextSidebar`/`TabFinanciamiento` (owner sigue pasando).

### Fase 6 — Verificación — 🟡 PARCIAL (2026-06-25)
**Hecho (automatizado):**
- ✅ **Matriz de permisos por rol: 56/56 aserciones OK** en `PropFlow_Gerardo` (script `verify_phase6_matrix.js`). Cada rol = exactamente el acceso del requerimiento, 19 tenants.
- ✅ `py_compile` de todos los archivos backend de Fase 3/4.
- ✅ `type-check` frontend sin errores en archivos tocados (los 2 de ComposeModal son preexistentes).

**Pendiente (requiere entorno local del dev — Docker/Auth0/browser):**
- Boot backend + `docker-compose exec api pytest` (uv/deps en Docker; no hay venv local).
- `npm test` frontend (en esta sesión `vitest` no resolvió el binario).
- **Login por rol** (owner/asesor/supervisor/asesor_externo/aprobacion_meta): menú + rutas + scoping. Caso clave de seguridad: un **asesor que pega `GET /calls`/`GET /emails` directo NO debe ver datos de leads ajenos** (el filtrado backend es lo único sensible).

---

## 6. Archivos clave (para retomar sin re-explorar)

### Backend (`app-saas-service`)
| Archivo | Rol |
|---|---|
| `app/db/models_auth.py` | Modelos RBAC |
| `app/services/rbac_seed_service.py` | Mapeo rol→permisos + siembra por tenant (`_build_permission_sets`, `seed_tenant_roles`, `ROLE_DISPLAY_NAMES`) |
| `app/api/dependencies.py` | `require_permission` (393-416), carga `UserContext` (22-130) |
| `app/db/repositories/rbac_repository.py` | `get_user_with_roles_and_permissions` (197-243) |
| `app/core/leads_access.py` | `resolve_lead_advisor_filter`, `can_view_all_leads`, `assert_lead_visible` |
| `app/core/user_context.py` | `UserContext`, `has_permission` |
| `app/api/v1/roles.py` | CRUD de roles |
| `alembic/versions/c1f5a8b3d7e2_add_asesor_externo_role.py` | **Plantilla** de migración de rol idempotente |
| `alembic/versions/4dbc336a39ca_backfill_rbac_roles.py` | Backfill de roles |
| `alembic/versions/2ad15c07bd16_add_rbac_tables.py` | Tablas RBAC + catálogo inicial |

### Frontend (`app-saas-frontend`)
| Archivo | Rol |
|---|---|
| `src/router/index.ts` | Gating de rutas + caso `asesor_externo` (509-518) |
| `src/layouts/DashboardLayout.vue` | Sidebar filtrado (≈247-437) |
| `src/stores/auth.ts`, `src/stores/rbac.ts` | Carga/estado de roles+permisos |
| `src/composables/usePermission.ts` | `can/canAny/canAll/hasRole` |
| `src/directives/permission.ts` | Directiva `v-permission` |
| `src/types/rbac.ts` | Interfaces `Role`, `Permission`, `RbacModule` |
| `src/views/RolesView.vue`, `src/views/UsersView.vue` | Admin de roles/usuarios |

---

## 7. Preguntas para el stakeholder (BLOQUEAN el desarrollo)

> Cada pregunta trae una **Decisión propuesta** (default técnico basado en buenas prácticas). Si el stakeholder no responde, el desarrollo procede con la decisión propuesta; estas son **provisionales** hasta confirmación.
>
> Hay dos versiones del mismo contenido:
> - **§7-A — Versión técnica** (para stakeholder técnico / equipo dev): con detalle de permisos y trade-offs.
> - **§7-B — Versión de negocio** (para stakeholder NO técnico): mismas decisiones en lenguaje simple, sin jerga.

---

### 7-A. Versión para stakeholder TÉCNICO

> Ordenadas por impacto. Las que cambian estructura van primero.

**Q1 — Validación de crédito separada (revisada con datos de prod).**
El diseño contempla un rol `gestion_creditos` como único que *valida crédito* (`postventa.validate`), distinto de quien *aprueba el expediente* (`postventa.supervisor_validate`). **PERO los datos de producción (§1.8) muestran que ese rol no existe ni se usa** — hoy esa acción la cubre el `owner`. Por tanto NO hay un control activo que romper.
→ ¿El negocio **va a operar a futuro** una separación real entre *quien valida el crédito* y *quien aprueba el expediente*? ¿O el flujo seguirá centralizado en owner/supervisor?
> **✅ Decisión propuesta (revisada):** **Ir con 5 roles** — NO crear `gestion_creditos`; el Supervisor absorbe `postventa.validate`. Crear el 6º rol **solo** si responden que sí van a operar la separación; en ese caso se le quita `validate` al Supervisor. Cambió respecto a la versión anterior porque los datos de prod descartan que sea un control en uso.

**Q2 — Poderes administrativos del Supervisor.**
Recomendamos que el Supervisor **NO** pueda gestionar roles (`users.manage_roles`) ni editar workflows (`workflows.manage`) — solo invitar usuarios y ver workflows. Eso evita que un Supervisor se auto-escale o le quite acceso al Owner.
→ ¿De acuerdo en que la gestión de roles y la edición de automatizaciones queden **exclusivas del Owner**? ¿O el Supervisor sí debe poder cambiar roles/permisos de otros usuarios?
> **✅ Decisión propuesta:** Supervisor con `users.invite` + `workflows.view`, **sin** `users.manage_roles` ni `workflows.manage`. Regla de oro: quien administra accesos no debe poder auto-escalarse.
> **🔵 RESOLUCIÓN del stakeholder (2026-06-25):** aceptan todo EXCEPTO que sí quieren que el Supervisor **cree/edite workflows** → se agregó `workflows.manage` (migración `r5supervisorwf01`). `users.manage_roles` se mantiene exclusivo de owner.

**Q3 — Migración de roles `viewer` y `user`.**
Datos de prod (§1.8): `viewer` tiene **0 usuarios** y `user` **no existe** como rol → en la práctica **no hay a quién migrar**. La pregunta queda como salvaguarda por si la verificación encuentra usuarios.
> **✅ Decisión propuesta:** si apareciera algún usuario, **→ `asesor`** (menor privilegio). Mandar `viewer` a `supervisor` sería una escalada silenciosa. En la práctica, probablemente solo haya que borrar el rol vacío.

**Q4 — Cotizaciones del Asesor.**
Hoy el Asesor puede ver, crear y editar cotizaciones. La tarea solo dice "cotizaciones".
→ ¿El Asesor debe poder **crear/editar** cotizaciones, o **solo verlas**?
> **✅ Decisión propuesta:** **mantener `view/create/edit`**. Cotizar es parte de vender y la cotización es de *su* lead; quitárselo genera fricción sin ganancia de seguridad. Recortar solo si hay control de precios explícito.

**Q5 — Alcance del bloqueo de módulos para el Asesor.**
Para módulos como Marketing: ¿el Asesor tiene **prohibido** el acceso (enforcement en backend, más costoso) o simplemente **no le aparece en el menú** (ocultar en frontend, suficiente si no hay dato sensible)?
→ Aplica también a: ¿el Asesor puede ver el **dashboard** completo del tenant o una versión acotada a sus métricas?
> **✅ Decisión propuesta:** **enforcement de backend** solo donde hay datos de leads ajenos o edición (llamadas, correos, conversaciones, edición de proyectos); **ocultar-en-menú** para lo no sensible (Marketing). **Dashboard acotado** a las métricas del propio asesor.

**Q6 — "Aprobación Meta".**
Confirmar que es un rol **custom ya existente en la BD de producción** que debemos **conservar intacto**. ¿Cuál es su `name`/slug exacto y qué permisos tiene hoy? (para no romperlo en la migración de borrado).
> **✅ Decisión propuesta:** la migración de borrado opera por **allowlist explícita de slugs a eliminar** (`admin`, `manager`, `viewer`, `user`, `gerencia`, `administrativo`), **nunca por exclusión**. Así cualquier rol custom desconocido (incl. Aprobación Meta) sobrevive intacto aunque no llegue confirmación. Aun así, pedir slug + permisos para validar.

**Q7 — Owner multi-tenant (futuro).**
La tarea original pedía que Owner viera "todos los tenants". Lo dejamos aislado a su tenant (decisión de seguridad).
→ ¿Existe un caso real de un cliente que opere **varios tenants** y necesite verlos todos? Si sí, se diseña aparte como "membresía multi-tenant" (un usuario con roles en varios tenants), NO como super-admin global.
> **✅ Decisión propuesta:** **fuera de alcance** de este proyecto. Owner aislado a su tenant. Si aparece el caso real, se diseña como membresía multi-tenant, no como super-admin global. No bloquea.

**Q8 — Módulo "Legal".**
La tarea agrupa "Fintech y legal". Asumimos que "legal" = expedientes (módulo `postventa`) + plantillas de formularios.
→ ¿"Legal" es el mismo módulo de expedientes/postventa, o es un área separada con su propio control de acceso?
> **✅ Decisión propuesta:** "legal" **cubierto por `postventa.*`** (no se crea módulo nuevo). Crear `legal.*` solo si el dominio realmente lo separa.

---

### 7-B. Versión para stakeholder NO técnico (lenguaje de negocio)

> Mismas decisiones que arriba, sin jerga. Para quien aprueba desde el lado del negocio.

**1. ¿Quieren separar "quien aprueba el crédito" de "quien aprueba el expediente"?**
En teoría existe un rol para que *una persona valide el crédito* y *otra distinta apruebe el expediente* — como en un banco. Pero al revisar el sistema real, **ese rol no existe ni lo usa nadie hoy**: en la práctica el dueño (Owner) hace todo. O sea, esa separación hoy **no está funcionando**, no es algo que estemos "rompiendo".
> **Lo que proponemos:** quedarnos con **5 roles** y que el Supervisor pueda aprobar todo el proceso (como hace hoy el dueño). Crear el rol separado de "Gestión de Créditos" (serían 6) **solo si ustedes planean de verdad usar esa separación a futuro**. *Decidan: ¿van a operar esa separación de aquí en adelante, o el flujo sigue centralizado?*

**2. ¿El Supervisor puede crear usuarios y cambiar quién tiene qué permisos?**
> **Lo que proponemos:** el Supervisor puede **invitar gente** al sistema, pero **no** puede cambiar roles ni permisos de otros, ni modificar las automatizaciones. Eso queda solo para el Owner (el dueño). Razón: si el Supervisor pudiera cambiar permisos, podría darse a sí mismo acceso total o dejar fuera al dueño. *Decidan: ¿de acuerdo con que solo el Owner administre permisos?*

**3. Hay roles viejos que se van a eliminar — ¿qué pasa con esas personas?**
Buenas noticias: al revisar el sistema real, esos roles viejos (Viewer, Gerencia, Administrativo) **no los tiene nadie asignado**, y solo **una persona** tiene el rol "Administrador" que vamos a consolidar.
> **Lo que proponemos:** mover a esa única persona a **Owner** (dueño) y borrar los roles vacíos. Es un cambio mínimo, casi nadie se ve afectado.

**4. ¿El Asesor puede crear cotizaciones o solo verlas?**
> **Lo que proponemos:** que **pueda crearlas y editarlas**, como hasta ahora. Cotizar es parte de vender, y la cotización es de su propio cliente. Si quisieran controlar precios desde arriba, lo cambiamos. *Decidan: ¿el Asesor cotiza por sí mismo o necesita que alguien más lo haga?*

**5. ¿Qué tan estricto bloqueamos lo que el Asesor NO debe ver?**
Hay dos niveles: (a) **bloqueo real** (ni siquiera por vías técnicas puede ver la información) y (b) **simplemente no aparece en su menú** (para no estorbar, pero no es información delicada).
> **Lo que proponemos:** bloqueo real para lo sensible — los **datos de clientes de otros asesores** (llamadas, correos, conversaciones ajenas). Para cosas como **Marketing**, basta con que no le aparezca en el menú. Y su **panel principal (dashboard) mostraría solo sus propios números**, no los de todo el equipo. *Decidan si están de acuerdo con dónde ponemos la línea.*

**6. Existe un rol llamado "Aprobación Meta" — ¿lo dejamos tal cual?**
> **Lo que proponemos:** **no tocarlo**. Vamos a borrar roles solo de una lista exacta, así que cualquier rol especial que ustedes hayan creado a mano queda intacto, incluido "Aprobación Meta". Solo necesitamos que nos confirmen su nombre exacto y qué permisos tiene hoy, para verificar.

**7. ¿El dueño (Owner) necesita ver varias empresas/cuentas a la vez?**
La tarea decía "todos los tenants" (cuentas). Por seguridad lo dejamos viendo **solo su propia cuenta**.
> **Lo que proponemos:** dejarlo así por ahora. Si un cliente realmente maneja varias cuentas y necesita verlas todas, lo resolvemos en un proyecto aparte, de forma segura. *Decidan: ¿hay algún cliente con varias cuentas hoy?*

**8. "Legal" — ¿es lo mismo que los expedientes?**
> **Lo que proponemos:** tratar "Legal" como parte del módulo de **expedientes** (postventa), que es donde viven hoy esos documentos. Si para ustedes "Legal" es un área totalmente separada con su propia gente y permisos, lo separamos. *Decidan si Legal y Expedientes son lo mismo o no.*

---

## 8. Riesgos y notas
- **El verdadero riesgo del proyecto NO es definir 5 roles, sino el enforcement de backend "solo sus datos"** (sobre todo **llamadas**, donde aún no se confirmó filtro). El menú es cosmética; un endpoint sin filtro = fuga de datos.
- `seed_tenant_roles` no sobreescribe roles existentes → todo cambio de permisos a roles vivos es **vía migración**, no vía seed.
- El `downgrade` de un DELETE de roles+permisos es prácticamente irreversible → de ahí el despliegue en dos fases.
- No tocar roles `is_system=False` que no estén en la lista (ej. `Aprobación Meta` y otros customs que el tenant haya creado a mano).
- `system_admin` se conserva: es el único acceso cross-tenant del equipo dev.

---

## 9. Análisis de impacto (qué se ve afectado) — código verificado 2026-06-24

> Premisa clave: `require_roles(...)` valida contra `ctx.role_names` y **solo `owner`/`system_admin` tienen bypass universal**. Como `supervisor` NO está en esas listas, **quedaría 403** en esos endpoints aunque el plan le dé acceso. Todo lo que ya usa `require_permission(...)` se reconfigura solo cambiando el mapeo del rol.

### 9-A. Backend gateado por NOMBRE de rol (`require_roles`) — REVISAR endpoint por endpoint
| Archivo | Endpoints (líneas) | Gate actual | Impacto al consolidar | Acción |
|---|---|---|---|---|
| `emails.py` | 69, 122, 148, 217, 252, 286, 306, 325, 341, 410 (~10) | `require_roles("admin","asesor")` | **Supervisor 403** en todo correos; `admin` muerto | Migrar a `require_permission("emails.view")` |
| `invitations.py` | 28 | `require_roles("owner","admin")` | Supervisor no puede invitar (plan le da `users.invite`) | Migrar a `require_permission("users.invite")` |
| `admin_notifications.py` | 34, 59, 76 | `require_roles("admin")` | Owner ok; Supervisor 403 | Decidir owner-only o migrar a permiso |
| `audit_log.py` | 143 | `require_roles("admin")` | Supervisor 403 (¿debe ver bitácora?) | Decidir según Q (config) |
| `email_config.py` | 25, 47, 109, 154, 191 | `require_roles("admin")` | Supervisor 403 en conexiones/config | Decidir según Q (config) |
| `auth.py` | 399 | `require_roles("owner","admin")` | Owner ok; `admin` literal muerto | Limpiar literal |

> El resto del backend (leads, contacts, advisors, conversations, postventa, loss_reason, modules, advisor_chat, advisor_whatsapp…) ya usa `require_permission(...)` → **se reconfigura solo**.

### 9-B. Rutas/endpoints HOY SIN gate que el plan va a gatear — riesgo de transición
Al añadir el permiso, **todo usuario sin ese permiso pierde acceso**. Sembrar el permiso en los roles **ANTES** de gatear la ruta.
- **Proyectos/Properties**: ~20 rutas (router `index.ts` 154-256) sin `requiresPermission` → añadir `projects.view`/`projects.edit`.
- **Marketing/campaigns**, **calls**, **emails (menú)**: sin permiso propio.
- 🔎 **Chat asesores — hallazgo que simplifica:** el backend ya lo gatea con **`advisor_whatsapp.view`** (`advisor_chat.py`, 11 endpoints), no con `advisors.view`. El `asesor` ya tiene `advisor_whatsapp.view`. → **No crear `advisor_chat.view`**; solo cambiar el gate de la **ruta frontend** de `advisors.view` a `advisor_whatsapp.view` (un módulo nuevo menos, ver §4).

### 9-C. Checks hardcodeados en FRONTEND que se rompen al borrar `admin`/`manager`
Leen el rol por nombre; al desaparecer `admin`, **dejan de funcionar para el owner** (que no tiene rol `admin`).
| Archivo | Línea | Check | Efecto / Acción |
|---|---|---|---|
| `EmailsView.vue` | 26 | `roles.includes('admin')` | Función admin de correos se oculta para todos → cambiar a `'owner'`/permiso |
| `Emails/ComposeModal.vue` | 399 | `roles.includes('admin')` | Igual |
| `ConversationsView.vue` | 2806 | `!hasRole('owner') && !hasRole('admin')` | `admin` muerto (owner ok) |
| `TasksListView.vue` / `TaskForm.vue` | 31 / 69 | `['admin','owner','system_admin']` | owner ok; `admin` muerto |
| `LeadTimelineModal.vue` / `LeadContextSidebar.vue` | 397 / 2335 | `['admin','owner'].includes(user?.role)` | ⚠️ leen la **columna legacy `user.role`** — frágil; migrar a `hasRole`/permiso |
| `TabFinanciamiento.vue` | 157 / 158 | `hasRole('gestion_creditos')` / `hasRole('manager')` | Quedan muertos pero con fallback `can(...)` → NO rompe |
| `ExpedienteDetailView.vue` / `SupervisorValidationModal.vue` | 390 / — | `hasRole('supervisor')` | `supervisor` se conserva → OK |

### 9-D. Filtrado de datos "solo sus X"
Añadir scoping por `assigned_advisor_id` a **llamadas** y **correos** cambia *qué registros devuelve* el endpoint. **Verificar** que `emails.py` no devuelva hoy todo el tenant (posible fuga si solo se ocultaba en UI). Leads/conversaciones ya filtran (`leads_access.py`).

### 9-E. Infra / efectos colaterales
- **`rbac_seed_service.py`** (`_build_permission_sets`, `ROLE_DISPLAY_NAMES`): quitar del seed los roles que se borran y los permisos nuevos del set correcto, o los tenants nuevos los re-crean mal.
- **Caché Redis del `UserContext` (TTL 300s)**: tras cambiar permisos, los usuarios ven permisos viejos hasta **5 min** → la migración debe **invalidar la caché** (`set_cached_context`/clave por `auth0_id`).
- **`require_role` singular** (`dependencies.py:301`): código muerto → eliminar es seguro.
- **`UsersView`/`RolesView`**: reflejarán menos roles; reasignar el único usuario `admin`.

### 9-F. Veredicto de esfuerzo
1. **No duele** (auto-reconfigura): todo `require_permission` (mayoría del backend) + sidebar/rutas que ya usan `can()`.
2. **Tocar 1×1:** ~20 endpoints con `require_roles` (sobre todo `emails.py`) + ~7 checks hardcodeados de frontend con `'admin'`/`user.role`.
3. **Secuenciar:** sembrar permisos nuevos → gatear rutas ungated → invalidar caché Redis → (despliegue 2) borrar roles.
