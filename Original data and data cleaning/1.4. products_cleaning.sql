-- ============================================================
-- Database: bytecart_data
-- Table   : products  →  products_clean
--
-- Issues found and addressed
--   [FIXED]   Duplicate rows — two-pass removal
--   [FIXED]   product_name — ALL CAPS variants corrected manually;
--             leading/trailing spaces trimmed
--   [FIXED]   category — 'and' vs '&', mixed case, trailing spaces
--   [FIXED]   subcategory — mixed case, full canonical mapping applied
--   [FIXED]   base_price / unit_cost — '₩' currency prefix removed
--   [FIXED]   base_margin — percentage string format converted to decimal
--   [FIXED]   launch_date / discontinue_date — mixed separators (. /),
--             empty strings converted to NULL
--   [NOTE]    is_active, stock_quantity, weight_kg, reorder_point are not
--             used in downstream analysis — left as-is for now
-- ============================================================

USE bytecart_data;


-- ─────────────────────────────────────────────────────────────
-- SECTION 0  │  Deduplication
-- ─────────────────────────────────────────────────────────────

-- Pass 1: remove rows that are fully identical across every column.

DROP TABLE IF EXISTS products_stg;

CREATE TABLE products_stg AS
    SELECT
        product_id, product_name, category, subcategory, brand,
        base_price, unit_cost, base_margin, stock_quantity,
        reorder_point, launch_date, discontinue_date, is_active, weight_kg
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY
                    product_id, product_name, category, subcategory, brand,
                    base_price, unit_cost, base_margin, stock_quantity,
                    reorder_point, launch_date, discontinue_date, is_active, weight_kg
            ) AS rn
        FROM products
    ) AS dedup
    WHERE rn = 1;


-- Pass 2: check whether any product_id still appears more than once.

WITH cte AS (
    SELECT product_id,
           ROW_NUMBER() OVER (PARTITION BY product_id) AS rn
    FROM   products_stg
)
SELECT s.*
FROM   products_stg AS s
JOIN   cte          ON s.product_id = cte.product_id
WHERE  cte.rn > 1
ORDER BY s.product_id;

-- Finding: no ID-level duplicates remain. Renaming for consistency.

DROP TABLE IF EXISTS products_clean;

CREATE TABLE products_clean AS
    SELECT *
    FROM   products_stg;

DROP TABLE products_stg;


-- ─────────────────────────────────────────────────────────────
-- SECTION 1  │  product_id  (format validation)
-- ─────────────────────────────────────────────────────────────

-- Inspect: confirm all IDs follow the expected 'PRDxxxx' pattern.
SELECT *
FROM   products_clean
WHERE  NOT REGEXP_LIKE(product_id, '^PRD[0-9]{4}$');

-- Finding: all IDs conform to the expected format. No action needed.


-- ─────────────────────────────────────────────────────────────
-- SECTION 2  │  product_name
-- ─────────────────────────────────────────────────────────────

-- Inspect

SELECT DISTINCT product_name
FROM   products_clean
ORDER BY 1;


-- Inspect: some names are in ALL CAPS or with leading/trailing spaces.
--          A generic title-case function cannot be applied safely because
--          some product names contain abbreviations that must remain in
--          capitals (e.g. 'RGB', 'OLED', 'QLED'). Inspecting the
--          problematic rows.

SELECT product_name
FROM   products_clean
WHERE  BINARY product_name = BINARY UPPER(product_name);


UPDATE products_clean
SET    product_name = CASE TRIM(product_name)
           WHEN 'XIAOMI ULTRA CLEAR 10'          THEN 'Xiaomi Ultra Clear 10'
           WHEN 'XIAOMI MINI SMART SPEAKER 6'    THEN 'Xiaomi Mini Smart Speaker 6'
           WHEN 'GOOGLE ECHO 10'                 THEN 'Google Echo 10'
           WHEN 'APPLE GALAXY Z FOLD 7'          THEN 'Apple Galaxy Z Fold 7'
           WHEN 'LG SMART PLUG 1'                THEN 'LG Smart Plug 1'
           WHEN 'AKG JBL CHARGE 8'               THEN 'AKG JBL Charge 8'
           WHEN 'LOGITECH K65 RGB 5'             THEN 'Logitech K65 RGB 5'
           ELSE TRIM(product_name)
       END;

-- Note: 'Apple Galaxy Z Fold 7' is an unrealistic brand-product
--       combination but is likely to be an artefact of the fictional dataset.


-- ─────────────────────────────────────────────────────────────
-- SECTION 3  │  category
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT category
FROM   products_clean
ORDER BY 1;

-- Finding: inconsistent formatting

UPDATE products_clean
SET    category = TRIM(REPLACE(category, 'and', '&'));

-- ─────────────────────────────────────────────────────────────
-- SECTION 4  │  subcategory
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT subcategory
FROM   products_clean
ORDER BY 1;

-- Finding: lowercase and uppercase variants present.
--          A simple CONCAT title-case approach is not used because
--          several subcategories contain abbreviations or multi-word
--          patterns that require exact mapping (e.g. 'Desktop PCs',
--          'OLED TVs', 'DSLR Cameras').

UPDATE products_clean
SET    subcategory = CASE LOWER(TRIM(subcategory))
			WHEN 'desktop pcs' then 'Desktop PCs'
			WHEN 'external storage' THEN 'External Storage'
			WHEN 'phone mounts' THEN 'Phone Mounts'
			WHEN 'projectors' THEN 'Projectors'
			ELSE TRIM(subcategory)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 5  │  brand  (consistency check)
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT brand
FROM   products_clean
ORDER BY 1;

-- Finding: no formatting issues.

-- Check: brand should match the start of product_name.
SELECT product_name, brand
FROM   products_clean
WHERE  product_name NOT LIKE CONCAT(brand, '%');

-- Finding: all product names begin with their recorded brand.
--          No action needed.


-- ─────────────────────────────────────────────────────────────
-- SECTION 6  │  base_price  /  unit_cost
-- ─────────────────────────────────────────────────────────────

-- Inspect: look for non-numeric values.
SELECT DISTINCT base_price FROM products_clean WHERE REGEXP_LIKE(base_price, '[^0-9]') ORDER BY 1;
SELECT DISTINCT unit_cost  FROM products_clean WHERE REGEXP_LIKE(unit_cost,  '[^0-9]') ORDER BY 1;

-- Finding: a subset of values carry a '₩' currency prefix.

UPDATE products_clean
SET    base_price = TRIM(LEADING '₩' FROM base_price),
       unit_cost  = TRIM(LEADING '₩' FROM unit_cost);

ALTER TABLE products_clean
MODIFY COLUMN base_price FLOAT,
MODIFY COLUMN unit_cost  FLOAT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 7  │  base_margin
-- ─────────────────────────────────────────────────────────────

-- Inspect.
SELECT DISTINCT base_margin
FROM   products_clean
WHERE  base_margin NOT LIKE '0.%'
ORDER BY 1;

-- Finding: a subset of values are stored as percentage strings.

UPDATE products_clean
SET    base_margin = CASE
           WHEN RIGHT(TRIM(base_margin), 1) = '%'
               THEN CAST(TRIM(TRAILING '%' FROM base_margin) AS DECIMAL(6, 4)) / 100
           ELSE base_margin
       END;

ALTER TABLE products_clean
MODIFY COLUMN base_margin FLOAT;

-- Consistency check: base_margin should be consistent with the
--                    difference between base_price and unit_cost.
SELECT *
FROM   products_clean
WHERE  ABS(base_margin - ROUND((base_price - unit_cost) / base_price, 3)) > 0.01;

-- Finding: no rows returned — base_margin is consistent with
--          recorded prices across all products.


-- ─────────────────────────────────────────────────────────────
-- SECTION 8  │  launch_date  /  discontinue_date
-- ─────────────────────────────────────────────────────────────

-- Inspect: find values that do not follow the expected pattern.
SELECT DISTINCT launch_date
FROM   products_clean
WHERE  NOT REGEXP_LIKE(launch_date, '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$')
ORDER BY 1;

SELECT DISTINCT discontinue_date
FROM   products_clean
WHERE  NOT REGEXP_LIKE(discontinue_date, '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$')
ORDER BY 1;

-- Finding: launch_date has mixed separators. discontinue_date has
--          empty strings.

UPDATE products_clean
SET    launch_date      = REPLACE(REPLACE(TRIM(launch_date), '.', '-'), '/', '-'),
       discontinue_date = CASE
			WHEN discontinue_date = '' THEN NULL
            ELSE discontinue_date
       END;

ALTER TABLE products_clean
MODIFY COLUMN launch_date      DATE,
MODIFY COLUMN discontinue_date DATE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 9  │  NULL audit
-- ─────────────────────────────────────────────────────────────

SELECT
    SUM(CASE WHEN product_id       IS NULL THEN 1 ELSE 0 END) AS null_product_id,
    SUM(CASE WHEN product_name     IS NULL THEN 1 ELSE 0 END) AS null_product_name,
    SUM(CASE WHEN category         IS NULL THEN 1 ELSE 0 END) AS null_category,
    SUM(CASE WHEN subcategory      IS NULL THEN 1 ELSE 0 END) AS null_subcategory,
    SUM(CASE WHEN base_price       IS NULL THEN 1 ELSE 0 END) AS null_base_price,
    SUM(CASE WHEN unit_cost        IS NULL THEN 1 ELSE 0 END) AS null_unit_cost,
    SUM(CASE WHEN base_margin      IS NULL THEN 1 ELSE 0 END) AS null_base_margin,
    SUM(CASE WHEN launch_date      IS NULL THEN 1 ELSE 0 END) AS null_launch_date,
    SUM(CASE WHEN discontinue_date IS NULL THEN 1 ELSE 0 END) AS null_discontinue_date
FROM products_clean;

-- Expected NULLs:
--   discontinue_date : NULL for all active products — expected
-- Unexpected NULLs:
--   Any other column with NULLs should be investigated

-- Note: is_active, stock_quantity, weight_kg, and reorder_point are
--       not used in downstream analysis and have been left as-is.