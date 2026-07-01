# SCRUM-1206 — Modelo de roles / RBAC (5 roles, permisos por endpoint)

> Bitácora reconstruida desde git + memoria de proyecto. Multi-fase, varias ramas.

## Fecha
2026-06-25

## Tarea solicitada (en concreto)
Rediseñar el modelo de roles (RBAC): resolver un bug de accesos, consolidar a **5 roles**,
redefinir los sets de permisos de asesor y supervisor, aplicar **enforcement de permisos
por endpoint**, y ajustar permisos de workflows para supervisor.

## Rama
`feature/SCRUM-1206`, `feature/SCRUM-1206-2`, `feature/SCRUM-1206-3`
(commits `42eea345`, `de0afe3c`, `eb1c3316`, `c3439242`, `5c18744a`, `f8a312d8`)

## Módulo(s) afectado(s)
`app-saas-service` — auth / RBAC
- `app/services/rbac_seed_service.py` — catálogo y sets de permisos.
- `app/api/dependencies.py` — `require_permission`.
- Múltiples `app/api/v1/*.py` (calls, campaigns, distribution_lists, email_campaigns,
  emails, invitations, projects, properties, audit_log, auth, admin_notifications).
- `app/core/leads_access.py`.
- Migraciones: `r...defasessup01`, `r4cleanuproles01`, `r5supervisorwf01`.
- `tests/unit/postventa/test_rbac_postventa.py`.

## Resumen de lo que se hizo
Trabajo multi-fase de RBAC:
- **Fase 1**: permisos nuevos (projects/calls/emails/marketing) al catálogo + asignados.
- **Fase 2**: sets completos de asesor (23) y supervisor (51) redefinidos y verificados.
- **Fase 3**: enforcement de permisos por endpoint (`require_permission` en muchos routers).
- **Fase 4**: eliminación de roles consolidados, dejando 5 roles.
- Extra: supervisor puede crear/editar workflows (pedido del stakeholder); tests RBAC de
  postventa actualizados al modelo de 5 roles.

## Decisiones tomadas
- **5 roles** como modelo final; **Owner por-tenant**; **Supervisor recortado**.
- Enforcement declarativo por endpoint vía `require_permission` en vez de checks ad-hoc.

## Preguntas y respuestas
Decisiones cerradas con el stakeholder (registradas en memoria de proyecto): 5 roles,
Owner por-tenant, Supervisor recortado, supervisor con permiso de gestionar workflows.

## ¿Se tocó trabajo de otros desarrolladores?
**Sí, ampliamente.** La fase 3 agregó `require_permission` a numerosos endpoints escritos
por otros desarrolladores (calls, campaigns, emails, projects, properties, invitations,
etc.). Cambios de decorador/autorización, sin alterar la lógica de negocio de terceros.

## Bugs de otros encontrados / resueltos
- **Bug de accesos**: usuarios `javier`, `javierantoneo`/2 clientes y `propflowuser`
  quedaban con acceso incorrecto → corregidos a `owner`, dejando intactos los
  inactivos/de prueba. Resuelto y verificado en dev + migración para prod.

## Notas / pendientes
- Ver memoria `roles-deploy-scrum-1206`: pendiente revisar el merge de PR-C
  (`feature/SCRUM-1206-3`) cuando se suba.
