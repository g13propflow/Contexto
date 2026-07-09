# Bitácora — Herencia de Mts² (construcción y lote) en propiedades

**Fecha:** 2026-07-03
**Autor:** Gerardo (con asistencia IA)
**Área:** app-saas-service (backend) + app-saas-frontend (importación)

---

## Problema reportado

Propiedades del proyecto **Persea de Arrazola** aparecían con **Área (m²) = 0** y
**Área de lote (m²) = 0**, en lugar de heredar los valores del modelo
(ej. modelo Grizzly: 112 m² construcción / 105 m² terreno).

## Causa raíz (dos capas)

1. **Frontend — importación masiva** (`ProjectPropertiesImportView.vue`, ~L567-568):
   cuando el origen no traía área, se forzaba `area_sqm = 0` / `lot_area_sqm = 0`
   explícitos en el payload de `/properties/bulk`.

2. **Backend — guard de herencia** (`app/api/v1/properties.py`): la herencia solo
   aplicaba si el valor llegaba como `None` (`... if x is not None else modelo...`).
   Un `0` pasaba el guard y se guardaba tal cual, bloqueando la herencia.

El formulario manual (`PropertiesManager.vue`) ya estaba bien (convertía 0/vacío a
`undefined`), por eso el bug solo aparecía en propiedades **importadas**.

## Alcance real (dry-run contra BD)

No era exclusivo de Persea. **386 propiedades** afectadas, tenant `tenant_dpb`:

| project_id | Proyecto             | Propiedades |
|-----------:|----------------------|------------:|
| 23         | Persea Arrazola      | 164         |
| 22         | Mirabosque           | 146         |
| 17         | Condado San Rafael   | 76          |

## Corrección aplicada

### Backend (`app/api/v1/properties.py`)
- Nuevo helper `_area_provided(value)`: un área es "provista" solo si es `> 0`.
  Un `0`/negativo/`None` se trata como no provista → permite herencia.
- Aplicado en los 3 puntos de herencia: `create_property`,
  `update_property_from_create_data` y el bulk (FASE 5).
- Alcance ceñido a m² (`area_sqm`/`lot_area_sqm`). `bedrooms`/`bathrooms`/
  `parking_spots` se dejan igual (0 puede ser legítimo).

### Frontend (`ProjectPropertiesImportView.vue`)
- Al importar, si el origen no trae área se **omite** el campo (`delete`) en vez de
  enviar `0`, para que el backend herede del modelo.

### Datos existentes
- Script idempotente de backfill (scratchpad, no versionado):
  `backfill_property_areas.py`. Hereda del modelo solo donde el campo de la
  propiedad es `NULL`/`<= 0` y el modelo tiene valor `> 0`. Dry-run por defecto,
  `--apply` para persistir, filtros `--tenant`/`--project`.

### Test de regresión
- `tests/unit/test_property_area_inheritance.py` (8 casos, todos en verde):
  cubre `_area_provided` y la herencia con área 0 / None / explícita / sin modelo.

## Riesgos
- Tratar `0` como "heredar" sobrescribiría un 0 legítimo, pero un área de 0 m² no
  describe una propiedad real → riesgo aceptable.
- El backfill solo toca filas con 0/NULL cuyo modelo tiene valor; idempotente.

## Pendiente operativo
- [ ] Ejecutar el backfill con `--apply` (escribe en BD Azure) — requiere OK.
- [ ] Commit / PR (los hace el usuario).
