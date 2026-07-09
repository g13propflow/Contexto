/* ============================================================================
   Backfill de metros cuadrados (construcción y lote) en propiedades.

   Corrige propiedades cuyo area_sqm / lot_area_sqm quedó en NULL o 0 pero cuyo
   modelo (property_models) SÍ tiene el valor. Hereda desde el modelo.

   Idempotente: correrlo varias veces no causa daño (solo rellena lo que falta).
   Válido para SQL Server (T-SQL). Sirve igual en dev y en prod.

   ORDEN DE USO:
     0) (Opcional) Ejecutar el PASO 0 para LISTAR propiedad por propiedad las
        afectadas (útil para verlas en el frontend antes/después).
     1) Ejecutar el PASO 1 (pre-check) para ver el impacto ANTES de escribir.
     2) Ejecutar el PASO 2 (backfill). Está en una transacción: revisa los
        conteos y haz COMMIT (o ROLLBACK si algo se ve mal).
     3) Ejecutar el PASO 3 (verificación) — debe devolver 0 restantes.

   IMPORTANTE (prod): desplegar primero el fix de código y DESPUÉS correr esto,
   para que una re-importación posterior no vuelva a meter 0.
   ============================================================================ */


/* ---------------------------------------------------------------------------
   PASO 0 — LISTADO DETALLADO (solo lectura, no escribe nada)
   Lista cada propiedad afectada con su valor actual y el valor que heredaría
   del modelo. Sirve para inspeccionarlas en el frontend (antes/después).
   --------------------------------------------------------------------------- */
SELECT
    p.id,
    p.title,
    prj.name        AS proyecto,
    p.model         AS modelo,
    p.area_sqm      AS area_actual,
    m.construction_area_sqm AS area_modelo,
    p.lot_area_sqm  AS lote_actual,
    m.lot_size_sqm  AS lote_modelo
FROM properties p
JOIN property_models m ON m.id = p.model_id
LEFT JOIN projects prj ON prj.id = p.project_id
WHERE ((p.area_sqm IS NULL OR p.area_sqm <= 0) AND m.construction_area_sqm > 0)
   OR ((p.lot_area_sqm IS NULL OR p.lot_area_sqm <= 0) AND m.lot_size_sqm > 0)
ORDER BY prj.name, p.title;


/* ---------------------------------------------------------------------------
   PASO 1 — PRE-CHECK (solo lectura, no escribe nada)
   Muestra, por proyecto, cuántas propiedades heredarían valores.
   --------------------------------------------------------------------------- */
SELECT
    p.project_id,
    prj.name AS project_name,
    SUM(CASE WHEN (p.area_sqm IS NULL OR p.area_sqm <= 0)
                  AND m.construction_area_sqm > 0 THEN 1 ELSE 0 END) AS falta_construccion,
    SUM(CASE WHEN (p.lot_area_sqm IS NULL OR p.lot_area_sqm <= 0)
                  AND m.lot_size_sqm > 0 THEN 1 ELSE 0 END) AS falta_lote,
    SUM(CASE WHEN ((p.area_sqm IS NULL OR p.area_sqm <= 0) AND m.construction_area_sqm > 0)
                  OR ((p.lot_area_sqm IS NULL OR p.lot_area_sqm <= 0) AND m.lot_size_sqm > 0)
             THEN 1 ELSE 0 END) AS propiedades_afectadas
FROM properties p
JOIN property_models m ON m.id = p.model_id
LEFT JOIN projects prj ON prj.id = p.project_id
GROUP BY p.project_id, prj.name
HAVING SUM(CASE WHEN ((p.area_sqm IS NULL OR p.area_sqm <= 0) AND m.construction_area_sqm > 0)
                     OR ((p.lot_area_sqm IS NULL OR p.lot_area_sqm <= 0) AND m.lot_size_sqm > 0)
                THEN 1 ELSE 0 END) > 0
ORDER BY propiedades_afectadas DESC;


/* ---------------------------------------------------------------------------
   PASO 2 — BACKFILL (escribe). Va en una transacción para poder revertir.

   Cómo ejecutarlo:
     a) Selecciona y ejecuta desde "SET XACT_ABORT ON" hasta el "PRINT ..." final
        (SIN incluir el COMMIT todavía). Deja la transacción ABIERTA.
     b) Revisa los conteos impresos (deben coincidir con el PASO 1).
     c) Si todo se ve bien -> ejecuta 'COMMIT;'
        Si algo se ve mal    -> ejecuta 'ROLLBACK;'

   XACT_ABORT ON: si cualquier UPDATE falla en tiempo de ejecución, la
   transacción se aborta automáticamente y NO queda aplicada a medias.
   --------------------------------------------------------------------------- */
SET XACT_ABORT ON;

BEGIN TRANSACTION;

    -- Mts² de construcción
    UPDATE p
        SET p.area_sqm = m.construction_area_sqm
    FROM properties p
    JOIN property_models m ON m.id = p.model_id
    WHERE (p.area_sqm IS NULL OR p.area_sqm <= 0)
      AND m.construction_area_sqm > 0;
    PRINT 'Construcción actualizadas: ' + CAST(@@ROWCOUNT AS VARCHAR(20));

    -- Mts² de lote
    UPDATE p
        SET p.lot_area_sqm = m.lot_size_sqm
    FROM properties p
    JOIN property_models m ON m.id = p.model_id
    WHERE (p.lot_area_sqm IS NULL OR p.lot_area_sqm <= 0)
      AND m.lot_size_sqm > 0;
    PRINT 'Lote actualizadas: ' + CAST(@@ROWCOUNT AS VARCHAR(20));

-- >>> Revisa los conteos de arriba y ejecuta UNA de estas dos líneas: <<<
-- COMMIT;      -- confirma los cambios
-- ROLLBACK;    -- descarta todo


/* ---------------------------------------------------------------------------
   PASO 3 — VERIFICACIÓN (debe devolver 0)
   --------------------------------------------------------------------------- */
SELECT COUNT(*) AS restantes_sin_heredar
FROM properties p
JOIN property_models m ON m.id = p.model_id
WHERE ((p.area_sqm IS NULL OR p.area_sqm <= 0) AND m.construction_area_sqm > 0)
   OR ((p.lot_area_sqm IS NULL OR p.lot_area_sqm <= 0) AND m.lot_size_sqm > 0);
