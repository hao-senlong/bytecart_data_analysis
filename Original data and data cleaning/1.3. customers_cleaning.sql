-- ============================================================
-- Database: bytecart_data
-- Table   : customers  →  customers_clean
--
-- Issues found and addressed
--   [FIXED]   No ID-level duplicates found after exact-match pass
--   [FIXED]   gender — abbreviations (M/F), mixed case
--   [FIXED]   age — impossible values (0, negative, > 110) → NULL
--   [FIXED]   tier — abbreviations (Reg/Gld/Prem/Slvr), mixed case
--   [FIXED]   registration_date — mixed separators (. /)
--   [FIXED]   region / city — mixed case, leading/trailing spaces
--   [NOTE]    age NULLs cannot be recovered from available data
--   [NOTE]    email / phone / full_name not cleaned — these fields
--             are not used in downstream analysis
-- ============================================================

USE bytecart_data;


-- ─────────────────────────────────────────────────────────────
-- SECTION 0  │  Deduplication
-- ─────────────────────────────────────────────────────────────

-- Pass 1: remove rows that are fully identical across every column.

DROP TABLE IF EXISTS customers_stg;

CREATE TABLE customers_stg AS
    SELECT
        customer_id, first_name, last_name, full_name,
        gender, age, tier, registration_date,
        region, city, email, phone
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY
                    customer_id, first_name, last_name, full_name,
                    gender, age, tier, registration_date,
                    region, city, email, phone
            ) AS rn
        FROM customers
    ) AS dedup
    WHERE rn = 1;


-- Pass 2: check whether any customer_id still appears more than once.

WITH cte AS (
    SELECT customer_id,
           ROW_NUMBER() OVER (PARTITION BY customer_id) AS rn
    FROM   customers_stg
)
SELECT s.*
FROM   customers_stg AS s
JOIN   cte           ON s.customer_id = cte.customer_id
WHERE  cte.rn > 1
ORDER BY s.customer_id;

-- Finding: no ID-level duplicates remain. Renaming for consistency.

DROP TABLE IF EXISTS customers_clean;

CREATE TABLE customers_clean AS
    SELECT *
    FROM   customers_stg;

DROP TABLE customers_stg;


-- ─────────────────────────────────────────────────────────────
-- SECTION 1  │  customer_id  (format validation)
-- ─────────────────────────────────────────────────────────────

-- Inspect: confirm all IDs follow the expected 'CUSxxxx' pattern.
SELECT *
FROM   customers_clean
WHERE  NOT REGEXP_LIKE(customer_id, '^CUS[0-9]{4}$');

-- Finding: all IDs conform to the expected format. No action needed.


-- ─────────────────────────────────────────────────────────────
-- SECTION 2  │  gender
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT gender
FROM   customers_clean;

-- Finding: values include 'Male', 'Female' and abbreviations 'M'/'F'.

UPDATE customers_clean
SET    gender = CASE
           WHEN UPPER(LEFT(TRIM(gender), 1)) = 'M' THEN 'Male'
           WHEN UPPER(LEFT(TRIM(gender), 1)) = 'F' THEN 'Female'
           ELSE gender
       END;


-- ─────────────────────────────────────────────────────────────
-- SECTION 3  │  age
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT age
FROM   customers_clean
ORDER BY 1;

-- Finding: impossible values of 0, -1, 150 and 999.
--          No other field can be used to recover the true age,
--          so these are converted to NULL.

UPDATE customers_clean
SET    age = CASE
           WHEN CAST(age AS SIGNED) > 110 OR CAST(age AS SIGNED) < 5
               THEN NULL
           ELSE age
       END;

ALTER TABLE customers_clean
MODIFY COLUMN age INT;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4  │  tier
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT tier
FROM   customers_clean
ORDER BY 1;

-- Inspect: tiers written fully in uppercase or lowercase.
SELECT DISTINCT tier
FROM   customers_clean
WHERE  BINARY UPPER(TRIM(tier)) = BINARY TRIM(tier)
   OR  BINARY LOWER(TRIM(tier)) = BINARY TRIM(tier)
ORDER BY 1;

-- Finding: mix of full names, abbreviations, and casing variants.

UPDATE customers_clean
SET    tier = CASE
           WHEN LOWER(TRIM(tier)) LIKE 'reg%'              THEN 'Regular'
           WHEN LOWER(TRIM(tier)) LIKE 'slv%'              
			 OR LOWER(TRIM(tier)) LIKE 'silver%'             THEN 'Silver'
           WHEN LOWER(TRIM(tier)) LIKE 'gld%'
             OR LOWER(TRIM(tier)) LIKE 'gold%'             THEN 'Gold'
           WHEN LOWER(TRIM(tier)) LIKE 'prem%'             THEN 'Premium'
           ELSE TRIM(tier)
       END;

-- ─────────────────────────────────────────────────────────────
-- SECTION 5  │  registration_date
-- ─────────────────────────────────────────────────────────────

-- Inspect: find any values that do not follow the expected pattern.
SELECT DISTINCT registration_date
FROM   customers_clean
WHERE  NOT REGEXP_LIKE(registration_date, '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$')
ORDER BY 1;

-- Finding: some dates use '.' or '/' as separators.

UPDATE customers_clean
SET    registration_date = REPLACE(REPLACE(TRIM(registration_date), '.', '-'), '/', '-');

ALTER TABLE customers_clean
MODIFY COLUMN registration_date DATE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 6  │  region  /  city
-- ─────────────────────────────────────────────────────────────

-- Inspect
SELECT DISTINCT region FROM customers_clean ORDER BY 1;
SELECT DISTINCT city   FROM customers_clean ORDER BY 1;

-- Finding: uppercase, lowercase, and leading/trailing space variants.

UPDATE customers_clean
SET    region = CONCAT(
                    UPPER(LEFT(TRIM(region), 1)),
                    LOWER(SUBSTRING(TRIM(region), 2))
               ),
       city   = CONCAT(
                    UPPER(LEFT(TRIM(city), 1)),
                    LOWER(SUBSTRING(TRIM(city), 2))
               );


-- ─────────────────────────────────────────────────────────────
-- SECTION 7  │  NULL audit
-- ─────────────────────────────────────────────────────────────

-- The only remaining NULLs are in age, introduced in Section 3 for 
--          impossible values. These cannot be recovered from available
--          data — no further action taken.

-- Note: email, phone, and full_name are left uncleaned, as they
--       are not required for downstream analysis or visualisations.
