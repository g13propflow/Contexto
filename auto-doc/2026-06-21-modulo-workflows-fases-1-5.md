# Módulo de Workflows (reglas) — Fases 1 a 5

> Bitácora reconstruida desde git. Campos de decisiones/preguntas inferidos del commit.

## Fecha
2026-06-21

## Tarea solicitada (en concreto)
Construir desde cero el nuevo **módulo de workflows / reglas** (motor de reglas
disparadas por eventos del lead), entregado en 5 fases.

## Rama
(base del módulo de workflows) — commits `88b4661f`, `8c869352`, `ae6fbc0b`, `f81ce1e1`, `0483d94e`

## Módulo(s) afectado(s)
`app-saas-service` — workflows (nuevo módulo)
- `app/db/models_workflow_rules.py` (**nuevo**)
- `app/db/repositories/workflow_rule_repository.py` (**nuevo**)
- `app/api/v1/workflow_rules.py` (**nuevo**)
- `app/schemas/workflow_rule.py` (**nuevo**)
- `app/services/workflow_rule_service.py`
- Migraciones `aa01bb02cc03_add_workflow_rules_tables.py` + merges
- `app/services/rbac_seed_service.py`, `alembic/env.py`, `app/db/__init__.py`

## Resumen de lo que se hizo
Se creó el módulo de reglas de workflow completo: modelos, repositorio, schemas, API y
servicio, con sus tablas (migración). Entregado incrementalmente en 5 fases el mismo día,
sentando la base sobre la que luego se montaron las acciones diferidas (SCRUM-1242), la
acción "enviar correo" (SCRUM-1238) y la resolución de listas dinámicas (SCRUM-1226).

## Decisiones tomadas
Arquitectura de módulo nuevo con su propio `models_workflow_rules.py` y repositorio
dedicado, siguiendo el patrón del resto de `app-saas-service`.

## Preguntas y respuestas
Sin registro (reconstruido desde git).

## ¿Se tocó trabajo de otros desarrolladores?
Mayormente código nuevo. Se tocó `rbac_seed_service.py` y `alembic/env.py`
(infraestructura compartida) para registrar el módulo.

## Bugs de otros encontrados / resueltos
Ninguno (módulo nuevo).

## Notas / pendientes
- Se dejó `check_tables.py` en el commit `88b4661f` (script de diagnóstico); revisar si
  debe salir del repo (regla: scripts throwaway van al scratchpad).
- Resumen del módulo en `resumen-modulo-workflows.md`.
