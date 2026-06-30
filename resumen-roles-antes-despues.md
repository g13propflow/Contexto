# Roles PropFlow — Antes vs. Ahora

> Resumen de la consolidación de roles (SCRUM-1206). De **11 roles** a **5 de negocio** (+ `system_admin` de plataforma). Última actualización: 2026-06-25.

---

## Inventario: 11 roles → 5 (+ 1 de plataforma)

| Rol (antes) | Usuarios en prod | Ahora | Qué pasó |
|---|---|---|---|
| **owner** | 13 | ✅ se queda | Sin cambios (todos los permisos, su tenant) |
| **asesor** | 2 | ✅ se queda (redefinido) | Ajustado a "solo lo suyo" + módulos nuevos |
| **asesor_externo** | 2 | ✅ se queda | Sin cambios |
| **supervisor** | 0 | ✅ se queda (redefinido) | De *solo-postventa* a *comercial amplio* |
| **aprobacion_meta** (custom) | 1 | ✅ se queda | Sin cambios (intacto) |
| **admin** | 1 | ❌ eliminado | El usuario → **owner** |
| **manager** | 0 | ❌ eliminado | Absorbido por **supervisor** |
| **gerencia** | 0 | ❌ eliminado | Absorbido por **supervisor** |
| **gestion_creditos** | 0 | ❌ eliminado | Absorbido por **supervisor** (incl. validar crédito) |
| **administrativo** | 0 | ❌ eliminado | Absorbido por **supervisor** |
| **viewer** | 0 | ❌ eliminado | (vacío) → asesor si hubiera |
| **system_admin** | 1 | ⚙️ se conserva | Rol de **plataforma** (cross-tenant, equipo dev), no de negocio |

---

## Detalle de los 5 roles que quedan

### Owner — *sin cambios*
Todos los permisos, **aislado a su tenant** (NO cross-tenant — eso sigue siendo exclusivo de `system_admin`).

### Asesor — *redefinido (todo "solo lo suyo")*
| Acceso | Antes | Ahora |
|---|---|---|
| Dashboard, leads/contactos/cotizaciones/calendario/tareas (solo suyo) | ✅ | ✅ |
| Conversaciones (solo sus leads) | ✅ | ✅ |
| **Proyectos** | sin gate | ✅ **solo vista** (no edita) |
| **Llamadas / Correos** (solo sus leads) | sin gate | ✅ **nuevo, con filtrado backend** |
| **Chat asesores** | vía `advisors.view` | ✅ vía `advisor_whatsapp.view` |
| Fintech/legal (solo sus expedientes) | ✅ | ✅ |
| Gestión de **Asesores** | la veía (`advisors.view`) | ❌ ya no |
| Marketing / Usuarios / Workflows | — | ❌ no |

### Supervisor — *cambio mayor: de solo-postventa a comercial amplio*
| Acceso | Antes | Ahora |
|---|---|---|
| Alcance | Solo postventa | **Todo el tenant** (ve todos los asesores) |
| Proyectos | — | ✅ **edición** |
| Gestión comercial (leads/contactos/asesores/cotizaciones/calendario/tareas/supervisión) | — | ✅ |
| Omnicanalidad (conversaciones/llamadas/correos/chat asesores) | — | ✅ (de todos) |
| Marketing | — | ✅ |
| Fintech/legal completo (incl. **validar crédito**) | parcial | ✅ completo |
| Config: conf expedientes, usuarios (ver/invitar), motivos de descarte | — | ✅ |
| **Workflows: ver + crear/editar** (`workflows.manage`) | — | ✅ **SÍ** (pedido del stakeholder) |
| Gestionar **roles** (`users.manage_roles`) | — | ❌ **NO** (exclusivo de owner — anti auto-escalada) |

### Asesor Externo — *sin cambios*
Solo `leads.view` (y crear), restringido a sus propios leads. Acceso limitado a Leads/Conversaciones.

### Aprobación Meta — *sin cambios (custom, 1 tenant)*
`leads.view` + `leads.view_all_advisors` → ve **todos** los leads del tenant en **solo lectura**.

---

## Cambios estructurales clave
- **Owner ≠ cross-tenant** (confirmado por seguridad; cross-tenant queda en `system_admin`).
- **Supervisor recortado**: amplio pero **sin** administrar roles ni editar workflows.
- **Postventa**: los 3 roles especializados (gerencia, gestión de créditos, administrativo) se fusionaron en **supervisor**.
- **Enforcement real** en backend para llamadas/correos/proyectos (no solo ocultar en el menú).

### Nota: ¿por qué "Chat asesores" cambió de `advisors.view` → `advisor_whatsapp.view`?
`advisors.view` controlaba **dos cosas**: la gestión de Asesores **y** el Chat asesores. Al quitarle al asesor el módulo de gestión de Asesores (ya no tiene `advisors.view`), el chat —que colgaba del mismo permiso— se habría roto. El **backend del chat ya usaba `advisor_whatsapp.view`** (que el asesor sí tiene), así que se alineó el frontend con el backend y se **desacopló** el chat de la gestión de asesores. Fix de regresión + corrección de una inconsistencia previa.

---

## Permisos nuevos creados (para gatear módulos antes abiertos)
`projects.view`, `projects.edit`, `calls.view`, `calls.view_all_advisors`, `emails.view`, `emails.view_all_advisors`, `marketing.view`.
(Chat asesores NO necesitó permiso nuevo: reutiliza `advisor_whatsapp.view`.)
