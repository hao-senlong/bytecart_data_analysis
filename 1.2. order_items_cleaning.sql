-- ============================================================
-- Database: bytecart_data
-- Table   : order_items  →  order_items_clean
--
-- Issues found and addressed
--   [FIXED]   No ID-level duplicates found after exact-match pass
--   [FIXED]   discount_rate — percentage string format (e.g. '4.5%')
--   [FIXED]   item_revenue — negative sign errors
--   [FIXED]   profit_margin — percentage string and 'nan%' values
--   [FIXED]   review_score — empty strings and '.0' suffix
--   [FIXED]   review_text — 'N/A' placeholder converted to NULL
--   [FIXED]   list_price / unit_price / item_cogs / item_profit — cast to type
--   [FLAGGED] quantity = 0 or negative  →  quantity_clean
--   [FLAGGED] review_score outside 1–5  →  flag_review_unrealistic
--   [NOTE]    NULL profit_margin confirmed valid for cancelled
--             orders (zero revenue) — no action taken
--   [NOTE]    NULL quantity_clean where revenue is also zero
--             to be verified against orders_clean
-- ============================================================

USE bytecart_data;


-- ─────────────────────────────────────────────────────────────
-- SECTION 0  │  Deduplication
-- ─────────────────────────────────────────────────────────────

-- Pass 1: remove rows that are fully identical across every column.

DROP TABLE IF EXISTS order_items_stg;

CREATE TABLE order_items_stg AS
    SELECT
        order_item_id, order_id, product_id, quantity,
        list_price, discount_rate, unit_price,
        item_revenue, item_cogs, item_profit, profit_margin,
        review_score, review_text
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY
                    order_item_id, order_id, product_id, quantity,
                    list_price, discount_rate, unit_price,
                    item_revenue, item_cogs, item_profit, profit_margin,
                    review_score, review_text
            ) AS rn
        FROM order_items
    ) AS dedup
    WHERE rn = 1;


-- Pass 2: check whether any order_item_id still appears more than once.

WITH cte AS (
    SELECT order_item_id,
           ROW_NUMBER() OVER (PARTITION BY order_item_id) AS rn
    FROM   order_items_stg
)
SELECT s.*
FROM   order_items_stg AS s
JOIN   cte             ON s.order_item_id = cte.order_item_id
WHERE  cte.rn > 1
ORDER BY s.order_item_id;

-- Finding: no ID-level duplicates remain. Renaming for consistency.

DROP TABLE IF EXISTS order_items_clean;

CREATE TABLE order_items_clean AS
    SELECT *
    FROM   order_items_stg;

DROP TABLE order_items_stg;


-- ─────────────────────────────────────────────────────────────
-- SECTION 1  │  quantity
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT quantity
FROM   order_items_clean
ORDER BY 1;

-- Finding: negative and zero values present.
--          Validate by comparing quantity × unit_price against item_revenue.

WITH cte AS (
    SELECT
        CAST(TRIM(LEADING '-' FROM quantity) AS SIGNED)  AS qty_abs,
        CAST(unit_price  AS FLOAT)                        AS u_price,
        CAST(item_revenue AS FLOAT)                       AS revenue
    FROM order_items_clean
)
SELECT *
FROM   cte
WHERE  qty_abs * u_price <> revenue;

-- Finding: negative quantities match the absolute value of item_revenue
--          when multiplied by unit_price — these are sign errors.
--          Zero quantities where revenue is also zero cannot be
--          recovered from this table alone. Creating a cleaned column
--          and flagging the unresolvable zeros.

ALTER TABLE order_items_clean
ADD COLUMN quantity_clean INT;

UPDATE order_items_clean
SET    quantity_clean = CASE
           WHEN quantity LIKE '-%'
               THEN CAST(TRIM(LEADING '-' FROM quantity) AS SIGNED)
           WHEN CAST(quantity AS SIGNED) = 0 AND CAST(item_revenue AS FLOAT) <> 0
               THEN ROUND(
                       CAST(TRIM(LEADING '-' FROM item_revenue) AS FLOAT)
                       / CAST(unit_price AS FLOAT)
                    )
           WHEN CAST(quantity AS SIGNED) = 0 AND CAST(item_revenue AS FLOAT) = 0
               THEN NULL
           ELSE CAST(quantity AS SIGNED)
       END;

-- Inspect: remaining unresolvable quantities (to be cross-checked later).
SELECT *
FROM   order_items_clean
WHERE  quantity_clean IS NULL;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2  │  list_price  /  unit_price
-- ─────────────────────────────────────────────────────────────

-- Inspect: check for non-numeric values.
SELECT *
FROM   order_items_clean
WHERE  REGEXP_LIKE(list_price,  '\\D')
   OR  REGEXP_LIKE(unit_price,  '\\D');

-- Finding: no issues.

ALTER TABLE order_items_clean
MODIFY COLUMN list_price FLOAT,
MODIFY COLUMN unit_price FLOAT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 3  │  discount_rate
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT discount_rate
FROM   order_items_clean
ORDER BY 1;

-- Finding: a subset of values are stored as percentage strings.

UPDATE order_items_clean
SET    discount_rate = CASE
           WHEN RIGHT(TRIM(discount_rate), 1) = '%'
               THEN CAST(TRIM(TRAILING '%' FROM discount_rate) AS DECIMAL(6, 4)) / 100
           ELSE discount_rate
       END;

ALTER TABLE order_items_clean
MODIFY COLUMN discount_rate FLOAT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4  │  item_revenue
-- ─────────────────────────────────────────────────────────────

-- Inspect: identify zero and negative values.
SELECT DISTINCT item_revenue
FROM   order_items_clean
ORDER BY 1;

-- Check: zeroes may indicate cancelled orders where all financials
--        are expected to be zero. Confirm no mismatched cogs/profit.
SELECT *
FROM   order_items_clean
WHERE  item_revenue = '0'
  AND  (item_cogs <> '0' OR item_profit <> '0');

-- Finding: no rows — zero revenues align with zero costs and profits.
--          These must be cancelled-order rows. No action needed.

-- Check: for negative revenues, confirm profit is not also negative.
SELECT *
FROM   order_items_clean
WHERE  item_revenue LIKE '-%'
  AND  item_profit  LIKE '-%';

-- Finding: no rows — negative revenues all pair with positive profits,
--          confirming these are sign errors. Safe to flip.

UPDATE order_items_clean
SET    item_revenue = TRIM(LEADING '-' FROM item_revenue);

ALTER TABLE order_items_clean
MODIFY COLUMN item_revenue FLOAT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 5  │  item_cogs  /  item_profit
-- ─────────────────────────────────────────────────────────────

-- Inspect: check for non-numeric values.
SELECT *
FROM   order_items_clean
WHERE  REGEXP_LIKE(item_cogs,   '\\D')
   OR  REGEXP_LIKE(item_profit, '\\D');

-- Finding: no issues.

ALTER TABLE order_items_clean
MODIFY COLUMN item_cogs   FLOAT,
MODIFY COLUMN item_profit FLOAT;

-- Consistency check: item_revenue - item_cogs should equal item_profit.
SELECT *
FROM   order_items_clean
WHERE  ROUND(item_revenue - item_cogs, 2) <> ROUND(item_profit, 2);

-- Finding: all rows pass — financial columns are internally consistent.


-- ─────────────────────────────────────────────────────────────
-- SECTION 6  │  profit_margin
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT profit_margin
FROM   order_items_clean
ORDER BY 1;

-- Finding: empty strings, 'nan%', and percentage-string formats.

UPDATE order_items_clean
SET    profit_margin = CASE
           WHEN TRIM(profit_margin) IN ('', 'nan%', 'nan') THEN NULL
           WHEN RIGHT(TRIM(profit_margin), 1) = '%'
               THEN CAST(TRIM(TRAILING '%' FROM profit_margin) AS DECIMAL(6, 4)) / 100
           ELSE profit_margin
       END;

ALTER TABLE order_items_clean
MODIFY COLUMN profit_margin FLOAT;

-- Confirm: NULLs in profit_margin match rows where revenue, cogs,
--          and profit are all zero (i.e. cancelled orders).
SELECT *
FROM   order_items_clean
WHERE  profit_margin IS NULL
  AND  (item_revenue <> 0 OR item_cogs <> 0 OR item_profit <> 0);

-- Finding: no rows — NULL margins are exclusively cancelled-order
--          rows. No action needed.


-- ─────────────────────────────────────────────────────────────
-- SECTION 7  │  review_score
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT review_score
FROM   order_items_clean
ORDER BY 1;

-- Finding: empty strings, '.0' decimal suffixes (e.g. '4.0'),
--          and out-of-range values (6, 7) on what is a 1–5 scale.
--          Out-of-range scores cannot be recovered; flagging them.

ALTER TABLE order_items_clean
ADD COLUMN flag_review_unrealistic BOOLEAN DEFAULT FALSE;

-- Clean the score format first, then set the flag.
UPDATE order_items_clean
SET    review_score = CASE
           WHEN TRIM(review_score) = '' THEN NULL
           ELSE TRIM(TRAILING '.0' FROM TRIM(review_score))
       END;

UPDATE order_items_clean
SET    flag_review_unrealistic = TRUE
WHERE  review_score IS NOT NULL
  AND  CAST(review_score AS SIGNED) > 5 or CAST(review_score AS SIGNED) < 0;

ALTER TABLE order_items_clean
MODIFY COLUMN review_score INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 8  │  review_text
-- ─────────────────────────────────────────────────────────────

-- Inspect: check for placeholder values.
SELECT DISTINCT review_text
FROM   order_items_clean
WHERE  TRIM(LOWER(review_text)) IN ('n/a', '');

-- Finding: 'N/A' placeholders present.

UPDATE order_items_clean
SET    review_text = CASE
           WHEN TRIM(LOWER(review_text)) IN ('n/a', '') THEN NULL
           ELSE TRIM(review_text)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 9  │  NULL audit
-- ─────────────────────────────────────────────────────────────

-- Remaining NULLs: review_score, review_text, profit_margin,
-- quantity_clean.
--   • review_* : expected — not every purchase has a review.
--   • profit_margin : confirmed as cancelled-order rows (Section 6).
--   • quantity_clean : zero-quantity rows where revenue is also zero;
--     to be cross-checked against orders_clean in the final stage.