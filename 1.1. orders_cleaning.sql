-- ============================================================
-- Database: bytecart_data
-- Table   : orders  →  orders_clean
--
-- Issues found and addressed
--   [FIXED]   Duplicate rows — two-pass removal
--   [FIXED]   order_date / delivery_date — mixed separators (. /)
--   [FIXED]   order_status — mixed case, typos, extra whitespace
--   [FIXED]   payment_method — merged spellings, mixed case, spaces
--   [FIXED]   shipping_days — empty strings converted to NULL
--   [FIXED]   delivery_date — empty strings converted to NULL
--   [FIXED]   total_revenue — negative sign errors
--   [FIXED]   shipping_days / total_profit / num_items — cast to type
--   [FLAGGED] total_quantity = 0 or negative  →  total_quantity_clean
--   [FLAGGED] num_items > total_quantity       →  flag_item_count_mismatch
--   [NOTE]    NULL shipping_days / delivery_date confirmed valid
--             for cancelled orders only — no action taken
-- ============================================================

USE bytecart_data;

-- ─────────────────────────────────────────────────────────────
-- SECTION 0  │  Deduplication
-- ─────────────────────────────────────────────────────────────

-- Pass 1: remove rows that are fully identical across every column.

DROP TABLE IF EXISTS orders_stg;

CREATE TABLE orders_stg AS
    SELECT
        order_id, customer_id, order_date, order_status,
        payment_method, shipping_days, delivery_date,
        total_revenue, total_profit, total_quantity, num_items
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY
                    order_id, customer_id, order_date, order_status,
                    payment_method, shipping_days, delivery_date,
                    total_revenue, total_profit, total_quantity, num_items
            ) AS rn
        FROM orders
    ) AS dedup
    WHERE rn = 1;


-- Pass 2: check whether any order_id still appears more than once.

WITH cte AS (
    SELECT order_id,
           ROW_NUMBER() OVER (PARTITION BY order_id) AS rn
    FROM   orders_stg
)
SELECT s.*
FROM   orders_stg   AS s
JOIN   cte          ON s.order_id = cte.order_id
WHERE  cte.rn > 1
ORDER BY s.order_id;

-- Finding: a small number of ID-level duplicates remain due to minor formatting differences.
--          Keeping only the first occurrence.

DROP TABLE IF EXISTS orders_clean;

CREATE TABLE orders_clean AS
    SELECT
        order_id, customer_id, order_date, order_status,
        payment_method, shipping_days, delivery_date,
        total_revenue, total_profit, total_quantity, num_items
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (PARTITION BY order_id) AS rn
        FROM orders_stg
    ) AS dedup2
    WHERE rn = 1;

DROP TABLE orders_stg;


-- ─────────────────────────────────────────────────────────────
-- SECTION 1  │  order_date
-- ─────────────────────────────────────────────────────────────

-- Inspect.
SELECT DISTINCT order_date
FROM   orders_clean
ORDER BY 1;

-- Finding: dates use a mix of '-', '.' and '/' as separators.

UPDATE orders_clean
SET    order_date = REPLACE(REPLACE(TRIM(order_date), '/', '-'), '.', '-');

ALTER TABLE orders_clean
MODIFY COLUMN order_date DATE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2  │  order_status
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT order_status
FROM   orders_clean
ORDER BY 1;

-- Finding: mixed case, leading/trailing spaces, and several typos.

UPDATE orders_clean
SET    order_status = CASE
           WHEN LOWER(TRIM(order_status)) LIKE 'deliv%' THEN 'Delivered'
           WHEN LOWER(TRIM(order_status)) LIKE 'canc%'  THEN 'Cancelled'
           ELSE TRIM(order_status)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 3  │  payment_method
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT payment_method
FROM   orders_clean
ORDER BY 1;

-- Finding: mixed case, merged spellings ('KakaoPay', 'NaverPay'),
--          inconsistent capitalisation ('Credit card'), and extra spaces.

UPDATE orders_clean
SET    payment_method = CASE
           WHEN REPLACE(LOWER(TRIM(payment_method)), ' ', '') LIKE 'kakao%' THEN 'Kakao Pay'
           WHEN REPLACE(LOWER(TRIM(payment_method)), ' ', '') LIKE 'naver%' THEN 'Naver Pay'
           WHEN LOWER(TRIM(payment_method)) LIKE 'credit%'                  THEN 'Credit Card'
           WHEN LOWER(TRIM(payment_method)) LIKE 'debit%'                   THEN 'Debit Card'
           WHEN LOWER(TRIM(payment_method)) LIKE 'bank%'                    THEN 'Bank Transfer'
           WHEN LOWER(TRIM(payment_method)) LIKE 'toss%'                    THEN 'Toss'
           ELSE TRIM(payment_method)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4  │  shipping_days
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT shipping_days
FROM   orders_clean
ORDER BY 1;

-- Finding: a few empty strings that should be NULL.

UPDATE orders_clean
SET    shipping_days = CASE WHEN TRIM(shipping_days) = '' THEN NULL ELSE shipping_days END;

ALTER TABLE orders_clean
MODIFY COLUMN shipping_days INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 5  │  delivery_date
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT delivery_date
FROM   orders_clean
ORDER BY 1;

-- Finding: same mixed separators as order_date; also empty strings.

UPDATE orders_clean
SET    delivery_date = CASE
           WHEN TRIM(delivery_date) = '' THEN NULL
           ELSE REPLACE(REPLACE(TRIM(delivery_date), '/', '-'), '.', '-')
       END;

ALTER TABLE orders_clean
MODIFY COLUMN delivery_date DATE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 6  │  total_revenue
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT total_revenue
FROM   orders_clean
ORDER BY 1;

-- Finding: some values carry a negative sign.
--          Check whether the corresponding total_profit is also
--          negative before treating these as simple sign errors.

SELECT total_revenue, total_profit
FROM   orders_clean
WHERE  total_revenue LIKE '-%'
  AND  total_profit  LIKE '-%';

-- Finding: no rows returned — every negative revenue pairs with a
--          positive profit, confirming these are sign errors.

UPDATE orders_clean
SET    total_revenue = TRIM(LEADING '-' FROM total_revenue);

ALTER TABLE orders_clean
MODIFY COLUMN total_revenue FLOAT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 7  │  total_profit
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT total_profit
FROM   orders_clean
ORDER BY 1;

-- Finding: some NULLs present but no other anomalies.

ALTER TABLE orders_clean
MODIFY COLUMN total_profit FLOAT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 8  │  total_quantity
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT total_quantity
FROM   orders_clean
ORDER BY 1;

-- Inspect: isolate zero and negative values.
SELECT *
FROM   orders_clean
WHERE  total_quantity LIKE '-%'
   OR  total_quantity = '0';

-- Finding: negative values are likely sign errors and can be flipped.
--          Zeros are ambiguous — a quantity of zero is not meaningful
--          for a real order and cannot be recovered without cross-
--          referencing order_items. Creating a cleaned column and
--          leaving the original intact for later verification.

ALTER TABLE orders_clean
ADD COLUMN total_quantity_clean INT;

UPDATE orders_clean
SET    total_quantity_clean = CASE
           WHEN total_quantity LIKE '-%'
               THEN CAST(TRIM(LEADING '-' FROM total_quantity) AS SIGNED)
           WHEN total_quantity = '0'
               THEN NULL
           ELSE CAST(total_quantity AS SIGNED)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 9  │  num_items
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT num_items
FROM   orders_clean
ORDER BY 1;

-- Finding: values look reasonable. Casting to integer.

ALTER TABLE orders_clean
MODIFY COLUMN num_items INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 10  │  Consistency check — item count vs total quantity
-- ─────────────────────────────────────────────────────────────

-- Check: the number of distinct products (num_items) must not
--        exceed the total number of units ordered (total_quantity_clean).

SELECT *
FROM   orders_clean
WHERE  total_quantity_clean IS NOT NULL
  AND  total_quantity_clean < num_items;

-- Finding: a small number of rows violate this constraint.
--          Flagging for review; will verify against order_items
--          during cross-table validation.

ALTER TABLE orders_clean
ADD COLUMN flag_item_count_mismatch BOOLEAN DEFAULT FALSE;

UPDATE orders_clean
SET    flag_item_count_mismatch = TRUE
WHERE  total_quantity_clean IS NOT NULL
  AND  total_quantity_clean < num_items;


-- ─────────────────────────────────────────────────────────────
-- SECTION 11  │  NULL audit
-- ─────────────────────────────────────────────────────────────

-- Inspect: all rows with NULL in shipping or delivery fields.
SELECT *
FROM   orders_clean
WHERE  shipping_days IS NULL
   OR  delivery_date IS NULL;

-- Confirm: check whether any of these belong to delivered orders.
SELECT *
FROM   orders_clean
WHERE  (shipping_days IS NULL OR delivery_date IS NULL)
  AND  order_status <> 'Cancelled';

-- Finding: no rows returned — NULLs in shipping_days and delivery_date
--          belong exclusively to cancelled orders, where they are
--          expected. No action needed.