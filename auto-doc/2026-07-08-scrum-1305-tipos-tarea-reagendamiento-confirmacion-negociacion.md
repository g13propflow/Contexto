# Bug: no se podían crear tareas de tipo reagendamiento/confirmación/negociación (SCRUM-1305)

## Fecha
2026-07-08

## Tarea solicitada (en concreto)
Investigar y corregir por qué el formulario de tareas **no permite crear** tareas con los
tipos `reagendamiento`, `confirmacion` y `negociacion` (mostraba "Error al crear la tarea").
Además, blindar con tests para que no vuelva a pasar.

## Diagnóstico (causa raíz)
El bug estaba en la **base de datos** (SQL Server), no en la aplicación. La columna
`dbo.tasks.type` es `VARCHAR` con un `CHECK constraint`. Tenía **dos defectos acumulados**:

1. **CHECK desactualizado** (`ck_tasks_type`): solo admitía los tipos antiguos + `documento`.
   Los tres tipos nuevos violaban el CHECK → error 547.
2. **Columna demasiado corta**: `VARCHAR(11)` (dimensionada al nombre de enum más largo de
   origen, `SEGUIMIENTO`). El ORM persiste el **nombre en MAYÚSCULAS** del enum, así que
   `REAGENDAMIENTO` (14) y `CONFIRMACION` (12) **truncaban** (error 8152); `NEGOCIACION` (11)
   entraba justo.

El endpoint `POST /tasks/` no captura el error de BD → sube como 500 → el front muestra el
genérico "Error al crear la tarea".

**Por qué solo esos 3:** los demás tipos (`seguimiento`, `reunion`, `documento`, `otro`) sí
estaban en el CHECK y caben en 11 chars. Las auto-tareas de confirmación/negociación funcionan
porque guardan `type=SEGUIMIENTO` y el ciclo va en la columna `auto_kind` (otra columna, con su
propio enum bien dimensionado).

**Origen del bug:** el commit `5cd57b5c` ("Agregando primeros cambios", 2026-06-19) agregó los
3 tipos al enum `TaskType`, al schema Pydantic y al front, y su migración
`c91f38a72b05_task_types_cancellation_reason.py` asumió textualmente que "los nuevos TaskType
se almacenan como VARCHAR en SQL Server — no requieren ALTER TYPE". La suposición era falsa:
una migración previa (`f1a2b3c4d5e6`, DOCUMENTO) ya había creado un CHECK explícito y la
columna era `VARCHAR(11)`.

## Rama y commits
Rama **`fixbug/SCRUM-1305`** en `app-saas-service` (creada desde `main`).
Commit `2b8d608d` (sin push; lo hace el usuario).

## Cambios (2 archivos, solo `app-saas-service`)
No hubo cambio de código de aplicación: el enum, el schema Pydantic y el front **ya** soportaban
los 3 tipos. El fix es puramente de esquema de BD + test.

- `alembic/versions/d5f8a2c1b9e4_add_reagendamiento_confirmacion_negociacion_to_tasktype.py`
  (nuevo) — dropea `ck_tasks_type` e índices dependientes, hace
  `ALTER COLUMN [type] VARCHAR(50)`, recrea `ck_tasks_type` incluyendo los 3 tipos en
  ambos casings, y recrea los índices `idx_tasks_status_type` e `ix_tasks_type`.
  `down_revision = 054dcb9dce83`.
- `tests/integration/test_enum_db_contract.py` (nuevo) — contrato BD↔enums contra SQL Server
  real (opt-in `INTEGRATION_DB=1`):
  - `test_every_task_type_is_insertable`: INSERT real + rollback de cada `TaskType`.
  - `test_enum_column_wide_enough`: toda columna `SQLEnum` debe caber su valor más largo.

## Verificación realizada
- Migración aplicada en **dev** `PropFlow_Gerardo` (Azure): `054dcb9dce83 -> d5f8a2c1b9e4`.
  Columna `type` ahora `VARCHAR(50)`; CHECK con los 20 valores.
- Prueba funcional replicando el path del endpoint (`Task(type=...)` + flush + rollback):
  los 3 tipos ahora **aceptados**, sin dejar datos.
- Test de integración: **18/18 en verde** con el fix.
- **Prueba de regresión del test:** con el fix revertido (`alembic downgrade -1`), el test
  **falla exactamente** en los 3 tipos con error 547 del CHECK → confirma que blinda de verdad.
  Reaplicado el fix; BD en `head`.

## Notas para el deploy a prod (pendiente del usuario)
- El cambio es **aditivo y retrocompatible** (CHECK superconjunto; VARCHAR se amplía, no trunca;
  NOT NULL preservado). No requiere deploy coordinado de código (el código ya tenía los tipos).
- Riesgos operativos, no lógicos:
  1. **Drift de migraciones en prod**: verificar `alembic current` == `054dcb9dce83` y qué
     correría `upgrade head` antes de aplicar.
  2. Índices extra desconocidos sobre `tasks.type` (drift) podrían abortar el `ALTER COLUMN`
     (falla segura por rollback).
  3. Lock de esquema breve en `tasks` al recrear índices → ventana de bajo tráfico.
- Landmine conocido: el docker-compose solo monta `./app`; hay que `docker cp` de `versions/`
  al contenedor antes de `alembic upgrade head`.
- Recomendado: enganchar `test_enum_db_contract.py` en CI con un SQL Server (hoy es opt-in y
  los unit tests corren en SQLite, que es ciego a esta clase de bug).

## Pendientes
- Push de `fixbug/SCRUM-1305` + PR (usuario).
- Aplicar migración en prod siguiendo el checklist.
- Revisión en curso de otros bugs del commit `27128b3d`/`5cd57b5c` (frontend del módulo tareas).
