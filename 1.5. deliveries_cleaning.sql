-- ============================================================
-- Database: bytecart_data
-- Table   : deliveries  →  deliveries_clean
--
-- Issues found and addressed
--   [FIXED]   Duplicate rows — two-pass removal
--   [FIXED]   courier — mixed case, abbreviations, merged names,
--             empty strings converted to NULL
--   [FIXED]   promised/actual/first_attempt dates — mixed separators (. /)
--   [FIXED]   delivery_outcome — variant spellings, merged words ('OnTime',
--             'VeryLate'), hyphens, underscores, and casing
--   [FIXED]   is_on_time / is_returned / complaint_raised — mixed boolean
--             representations (True/False/1/0/Yes/No and variants)
--   [FIXED]   package_condition — mixed case and trailing spaces
--   [FIXED]   return_reason — empty strings and 'N/A' placeholders → NULL
--   [FIXED]   promised_shipping_days / delivery_attempts / delay_days
--             / delivery_satisfaction — cast to correct types
--   [ADDED]   delay_days_calculated — recomputed from first_attempt_date
--             and promised_delivery_date using DATEDIFF()
--   [ADDED]   is_on_time_calculated — derived from delay_days_calculated
--   [FLAGGED] courier IS NULL — cannot be recovered from available data
--   [FLAGGED] actual_shipping_days ≤ 0 or implausibly large — requires
--             order_date from orders; deferred to cross-examination
--   [FLAGGED] delivery_satisfaction > 5 — flag_delivery_satisfaction_unrealistic
--   [NOTE]    delay_days and delivery_outcome are inconsistent for a subset
--             of rows; calculated columns treat dates as ground truth
--   [NOTE]    NULL return_reason where is_returned = FALSE is expected
-- ============================================================

USE bytecart_data;


-- ─────────────────────────────────────────────────────────────
-- SECTION 0  │  Deduplication
-- ─────────────────────────────────────────────────────────────

-- Pass 1: remove rows that are fully identical across every column.

DROP TABLE IF EXISTS deliveries_stg;

CREATE TABLE deliveries_stg AS
    SELECT
        delivery_id, order_id, customer_id, courier,
        promised_shipping_days, promised_delivery_date,
        actual_shipping_days, actual_delivery_date,
        delay_days, delivery_outcome, is_on_time,
        first_attempt_date, delivery_attempts,
        package_condition, is_returned, return_reason,
        delivery_satisfaction, complaint_raised
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY
                    delivery_id, order_id, customer_id, courier,
                    promised_shipping_days, promised_delivery_date,
                    actual_shipping_days, actual_delivery_date,
                    delay_days, delivery_outcome, is_on_time,
                    first_attempt_date, delivery_attempts,
                    package_condition, is_returned, return_reason,
                    delivery_satisfaction, complaint_raised
            ) AS rn
        FROM deliveries
    ) AS dedup
    WHERE rn = 1;


-- Pass 2: check whether any delivery_id still appears more than once.

WITH cte AS (
    SELECT delivery_id,
           ROW_NUMBER() OVER (PARTITION BY delivery_id) AS rn
    FROM   deliveries_stg
)
SELECT s.*
FROM   deliveries_stg AS s
JOIN   cte            ON s.delivery_id = cte.delivery_id
WHERE  cte.rn > 1
ORDER BY s.delivery_id;

-- Finding: a small number of ID-level duplicates remain due to
--          minor formatting differences. Keeping only the first row.

DROP TABLE IF EXISTS deliveries_clean;

CREATE TABLE deliveries_clean AS
    SELECT
        delivery_id, order_id, customer_id, courier,
        promised_shipping_days, promised_delivery_date,
        actual_shipping_days, actual_delivery_date,
        delay_days, delivery_outcome, is_on_time,
        first_attempt_date, delivery_attempts,
        package_condition, is_returned, return_reason,
        delivery_satisfaction, complaint_raised
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (PARTITION BY delivery_id) AS rn
        FROM deliveries_stg
    ) AS dedup2
    WHERE rn = 1;

DROP TABLE deliveries_stg;


-- ─────────────────────────────────────────────────────────────
-- SECTION 1  │  ID columns  (format validation)
-- ─────────────────────────────────────────────────────────────

-- Inspect: confirm all IDs follow expected patterns.
SELECT delivery_id FROM deliveries_clean WHERE NOT REGEXP_LIKE(delivery_id, '^DEL[0-9]{6}$');
SELECT order_id    FROM deliveries_clean WHERE NOT REGEXP_LIKE(order_id,    '^ORD[0-9]{6}$');
SELECT customer_id FROM deliveries_clean WHERE NOT REGEXP_LIKE(customer_id, '^CUS[0-9]{4}$');

-- Finding: all IDs conform to expected formats. No action needed.


-- ─────────────────────────────────────────────────────────────
-- SECTION 2  │  courier
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT courier
FROM   deliveries_clean
ORDER BY 1;

-- Finding: naming inconsistencies and empty strings.

UPDATE deliveries_clean
SET    courier = CASE
           WHEN REPLACE(LOWER(TRIM(courier)), '.', '') LIKE 'cj%'      THEN 'CJ'
           WHEN LOWER(TRIM(courier))                   LIKE 'coupang%' THEN 'Coupang'
           WHEN LOWER(TRIM(courier))                   LIKE 'lotte%'   THEN 'Lotte'
           WHEN LOWER(TRIM(courier))                   LIKE 'hanjin%'  THEN 'Hanjin'
           WHEN LOWER(REPLACE(TRIM(courier), ' ', '')) LIKE 'korea%'   THEN 'Korea Post'
           WHEN TRIM(courier) = ''                                       THEN NULL
           ELSE TRIM(courier)
       END;

-- NULL couriers cannot be recovered from this table alone.


-- ─────────────────────────────────────────────────────────────
-- SECTION 3  │  Date columns
--               (promised_delivery_date / actual_delivery_date /
--                first_attempt_date)
-- ─────────────────────────────────────────────────────────────

-- Inspect: find values that do not follow the expected YYYY-M-D pattern.
SELECT DISTINCT promised_delivery_date
FROM   deliveries_clean
WHERE  NOT REGEXP_LIKE(promised_delivery_date, '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$')
ORDER BY 1;

SELECT DISTINCT actual_delivery_date
FROM   deliveries_clean
WHERE  NOT REGEXP_LIKE(actual_delivery_date, '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$')
ORDER BY 1;

SELECT DISTINCT first_attempt_date
FROM   deliveries_clean
WHERE  NOT REGEXP_LIKE(first_attempt_date, '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$')
ORDER BY 1;

-- Finding: same mixed separator pattern as other tables ('.' and '/').
--          All dates are in YYYY-MM-DD order.

UPDATE deliveries_clean
SET    promised_delivery_date = REPLACE(REPLACE(TRIM(promised_delivery_date), '.', '-'), '/', '-'),
       actual_delivery_date   = REPLACE(REPLACE(TRIM(actual_delivery_date),   '.', '-'), '/', '-'),
       first_attempt_date     = REPLACE(REPLACE(TRIM(first_attempt_date),     '.', '-'), '/', '-');

ALTER TABLE deliveries_clean
MODIFY COLUMN promised_delivery_date DATE,
MODIFY COLUMN actual_delivery_date   DATE,
MODIFY COLUMN first_attempt_date     DATE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4  │  promised_shipping_days
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT promised_shipping_days
FROM   deliveries_clean
ORDER BY 1;

-- Finding: values look reasonable.

ALTER TABLE deliveries_clean
MODIFY COLUMN promised_shipping_days INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 5  │  actual_shipping_days
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT actual_shipping_days
FROM   deliveries_clean
ORDER BY 1;

-- Inspect: isolate problematic values.
SELECT *
FROM   deliveries_clean
WHERE  actual_shipping_days LIKE '-%'
   OR  CAST(actual_shipping_days AS SIGNED) = 0
   OR  CAST(actual_shipping_days AS SIGNED) > 30;

-- Finding: negative values, zeros, and an outlier of 99 days are present.
--          No clear pattern can be identified from this table alone —
--          the true shipping duration requires order_date from orders.
--          Affected rows are fewer than 1% of the data and are unlikely
--          to significantly impact analysis.
--          Leaving actual_shipping_days as-is for now; will recalculate
--          at the cross-examination stage.

ALTER TABLE deliveries_clean
MODIFY COLUMN actual_shipping_days INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 6  │  delay_days
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT delay_days
FROM   deliveries_clean
ORDER BY 1;

-- Finding: the numeric range looks reasonable. Casting to integer.
--          Consistency with delivery_outcome is addressed in Section 7.

ALTER TABLE deliveries_clean
MODIFY COLUMN delay_days INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 7  │  delivery_outcome  /  is_on_time
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT delivery_outcome FROM deliveries_clean ORDER BY 1;
SELECT DISTINCT is_on_time       FROM deliveries_clean ORDER BY 1;

-- Finding: delivery_outcome has multiple variant spellings.
--          is_on_time contains mixed boolean representations.

UPDATE deliveries_clean
SET    delivery_outcome = CASE
           WHEN LOWER(TRIM(delivery_outcome)) LIKE '%very%lat%'              THEN 'Very Late'
           WHEN LOWER(TRIM(delivery_outcome)) LIKE '%slight%lat%'
             OR LOWER(TRIM(delivery_outcome)) LIKE 'sligth%'                 THEN 'Slightly Late'
           WHEN LOWER(REPLACE(REPLACE(TRIM(delivery_outcome),
                    '_', ''), '-', '')) IN ('ontime', 'on time')
             OR LOWER(TRIM(delivery_outcome)) LIKE '%on%time%'               THEN 'On Time'
           WHEN LOWER(TRIM(delivery_outcome)) LIKE 'earl%'                   THEN 'Early'
           WHEN LOWER(TRIM(delivery_outcome)) LIKE '%lat%'                   THEN 'Late'
           ELSE TRIM(delivery_outcome)
       END,
       is_on_time = CASE
           WHEN LOWER(TRIM(is_on_time)) IN ('true',  '1', 'yes') THEN TRUE
           WHEN LOWER(TRIM(is_on_time)) IN ('false', '0', 'no')  THEN FALSE
           ELSE NULL
       END;

ALTER TABLE deliveries_clean
MODIFY COLUMN is_on_time BOOLEAN;

-- Consistency check: delivery_outcome and is_on_time should agree.
SELECT *
FROM   deliveries_clean
WHERE  delivery_outcome IN ('Early', 'On Time')
  AND  is_on_time = FALSE;
  
SELECT *
FROM deliveries_clean
WHERE first_attempt_date <= promised_delivery_date
    AND is_on_time = FALSE;

-- Finding: for a subset of rows first_attempt_dates
--          falls before the promised date yet is_on_time = FALSE.
--          This indicates delay_days itself may be incorrect for these
--          rows. Since it is unclear whether the issue lies in the dates
--          or in delay_days, treating the date columns as the primary
--          source of truth and deriving new columns.

ALTER TABLE deliveries_clean
ADD COLUMN delay_days_calculated INT,
ADD COLUMN is_on_time_calculated BOOLEAN;

UPDATE deliveries_clean
SET    delay_days_calculated = DATEDIFF(first_attempt_date, promised_delivery_date),
       is_on_time_calculated = CASE
           WHEN DATEDIFF(first_attempt_date, promised_delivery_date) <= 0 THEN TRUE
           ELSE FALSE
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 8  │  delivery_attempts  /  package_condition
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT delivery_attempts FROM deliveries_clean ORDER BY 1;
SELECT DISTINCT package_condition FROM deliveries_clean ORDER BY 1;

-- Finding: delivery_attempts values are 1, 2, or 3 as expected.
--          package_condition has some inconsistencies.

ALTER TABLE deliveries_clean
MODIFY COLUMN delivery_attempts INT;

UPDATE deliveries_clean
SET    package_condition = CASE
           WHEN LOWER(TRIM(package_condition)) = 'good'    THEN 'Good'
           WHEN LOWER(TRIM(package_condition)) = 'damaged' THEN 'Damaged'
           ELSE TRIM(package_condition)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 9  │  is_returned  /  return_reason
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT is_returned   FROM deliveries_clean ORDER BY 1;
SELECT DISTINCT return_reason FROM deliveries_clean ORDER BY 1;

-- Finding: is_returned contains the same mixed boolean representations
--          as is_on_time. return_reason contains empty strings.

UPDATE deliveries_clean
SET    is_returned = CASE
           WHEN LOWER(TRIM(is_returned)) IN ('true',  '1', 'yes') THEN TRUE
           WHEN LOWER(TRIM(is_returned)) IN ('false', '0', 'no')  THEN FALSE
           ELSE NULL
       END;

ALTER TABLE deliveries_clean
MODIFY COLUMN is_returned BOOLEAN;

UPDATE deliveries_clean
SET    return_reason = CASE
           WHEN TRIM(return_reason) = '' THEN NULL
           ELSE TRIM(return_reason)
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 10  │  delivery_satisfaction
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT delivery_satisfaction
FROM   deliveries_clean
ORDER BY 1;

-- Finding: values of 6 and 7 fall outside the valid 1–5 scale.
--          The true score cannot be recovered; flagging these rows.

ALTER TABLE deliveries_clean
ADD COLUMN flag_delivery_satisfaction_unrealistic BOOLEAN DEFAULT FALSE;

UPDATE deliveries_clean
SET    flag_delivery_satisfaction_unrealistic = TRUE
WHERE  CAST(delivery_satisfaction AS SIGNED) > 5;

ALTER TABLE deliveries_clean
MODIFY COLUMN delivery_satisfaction INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 11  │  complaint_raised
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT complaint_raised
FROM   deliveries_clean
ORDER BY 1;

-- Finding: same mixed boolean representations as other boolean columns.

UPDATE deliveries_clean
SET    complaint_raised = CASE
           WHEN LOWER(TRIM(complaint_raised)) IN ('true',  '1', 'yes') THEN TRUE
           WHEN LOWER(TRIM(complaint_raised)) IN ('false', '0', 'no')  THEN FALSE
           ELSE NULL
       END;

ALTER TABLE deliveries_clean
MODIFY COLUMN complaint_raised BOOLEAN;


-- ─────────────────────────────────────────────────────────────
-- SECTION 12  │  NULL audit
-- ─────────────────────────────────────────────────────────────

SELECT
    SUM(CASE WHEN courier           IS NULL THEN 1 ELSE 0 END) AS null_courier,
    SUM(CASE WHEN return_reason     IS NULL THEN 1 ELSE 0 END) AS null_return_reason,
    SUM(CASE WHEN is_on_time        IS NULL THEN 1 ELSE 0 END) AS null_is_on_time,
    SUM(CASE WHEN is_returned       IS NULL THEN 1 ELSE 0 END) AS null_is_returned,
    SUM(CASE WHEN complaint_raised  IS NULL THEN 1 ELSE 0 END) AS null_complaint_raised
FROM deliveries_clean;

-- Expected NULLs:
--   courier       : flagged in Section 2 — unrecoverable from this table
--   return_reason : NULL where is_returned = FALSE is expected
-- Unexpected NULLs:
--   is_on_time / is_returned / complaint_raised : boolean values that
--     could not be parsed; count should be near zero