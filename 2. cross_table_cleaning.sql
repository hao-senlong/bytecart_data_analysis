-- ============================================================
-- Database: bytecart_data
-- Tables  : orders_clean, order_items_clean, customers_clean,
--           deliveries_clean, products_clean
--
-- Issues found and addressed
--   [CONFIRMED] No orphaned IDs in any direction across all tables
--   [FIXED]     total_quantity_clean — recalculated from order_items_clean
--               where all individual item quantities are known
--   [FIXED]     promised/actual_shipping_days_calculated — derived from
--               order and delivery dates; stored as new columns in
--               deliveries_clean
--   [FLAGGED]   Mismatch between promised_shipping_days and
--               DATEDIFF(promised_delivery_date, order_date) and
--               actual_shipping_days vs DATEDIFF(actual_delivery_date,
--               order_date) (~80% of rows affected).
--   [FLAGGED]   ~40 orders where total_revenue or total_profit in
--               orders_clean does not match the sum of order_items_clean
--               → flag_revenue_or_profit_not_consistent
--   [FLAGGED]   ~1,589 customers whose earliest order predates their
--               registration_date → flag_registration_date_unrealistic
-- ============================================================

USE bytecart_data;


-- ─────────────────────────────────────────────────────────────
-- SECTION 1  │  orders  ↔  order_items
-- ─────────────────────────────────────────────────────────────

-- ── 1a. Referential integrity ─────────────────────────────────

-- Inspect: order_items rows whose order_id has no match in orders.
SELECT *
FROM   order_items_clean
WHERE  order_id NOT IN (SELECT order_id FROM orders_clean);

-- Inspect: orders with no line items at all.
SELECT *
FROM   orders_clean
WHERE  order_id NOT IN (SELECT order_id FROM order_items_clean);

-- Finding: no orphaned IDs in either direction. No action needed.


-- ── 1b. Quantity reconciliation ───────────────────────────────

-- Build a working table joining order-level and item-level quantities.

DROP TEMPORARY TABLE IF EXISTS order_quantities;

CREATE TEMPORARY TABLE order_quantities AS
    SELECT
        o.order_id,
        i.order_item_id,
        o.total_quantity,
        o.num_items,
        o.total_quantity_clean,
        o.flag_item_count_mismatch,
        i.quantity,
        i.quantity_clean
    FROM   orders_clean      AS o
    INNER JOIN order_items_clean AS i ON o.order_id = i.order_id
    ORDER BY o.order_id, i.order_item_id;

CREATE INDEX idx_order_quantities_order_id ON order_quantities (order_id);


-- Inspect: orders where total_quantity and total_quantity_clean differ —
--          these are the rows where a negative sign was corrected.
SELECT *
FROM   order_quantities
WHERE  total_quantity <> total_quantity_clean;

-- Finding: in most cases negative signs appear at both order and item
--          level and are simple sign errors. Consistent with the
--          individual-file findings.


-- Inspect: orders flagged for item count / quantity mismatch.
SELECT *
FROM   order_quantities
WHERE  flag_item_count_mismatch = TRUE;

-- Finding: mismatches arise from sign errors at item level — e.g. an
--          order with two items recorded as '-1' and '1' sums to zero
--          at the order level. Confirming that original order totals
--          equal the sum of their original item quantities.

WITH cte AS (
    SELECT
        order_id,
        MAX(total_quantity)  AS total_per_order,
        SUM(quantity)        AS sum_of_item_quantities
    FROM   order_quantities
    GROUP BY order_id
)
SELECT *
FROM   cte
WHERE  total_per_order <> sum_of_item_quantities;

-- Finding: no rows returned — stored order totals are consistent with
--          the sum of original item quantities. The mismatch flags arose
--          from sign errors that have since been corrected in quantity_clean.

-- Fix: recalculate total_quantity_clean from corrected item quantities.
--      Only update orders where every item has a known quantity_clean
--      (orders with at least one NULL quantity_clean are excluded).

DROP TEMPORARY TABLE IF EXISTS clean_totals;

CREATE TEMPORARY TABLE clean_totals AS
    SELECT
        order_id,
        SUM(quantity_clean) AS total_quantity_recalculated
    FROM   order_quantities
    GROUP BY order_id
    HAVING COUNT(*) = COUNT(quantity_clean);

CREATE INDEX idx_clean_totals_order_id ON clean_totals (order_id);
CREATE INDEX idx_orders_clean_order_id ON orders_clean (order_id);

-- Update the working table first, then propagate to orders_clean.
UPDATE order_quantities AS oq
INNER JOIN clean_totals AS ct ON oq.order_id = ct.order_id
SET    oq.total_quantity_clean = ct.total_quantity_recalculated;

UPDATE orders_clean AS oc
INNER JOIN order_quantities AS oq ON oc.order_id = oq.order_id
SET    oc.total_quantity_clean = oq.total_quantity_clean;


-- ── 1c. Revenue and profit reconciliation ─────────────────────

-- Inspect: orders where stored totals do not match the sum of
--          their line items.
WITH order_totals AS (
    SELECT
        o.order_id,
        MAX(o.total_revenue)      AS total_revenue_order,
        MAX(o.total_profit)       AS total_profit_order,
        SUM(oi.item_revenue)      AS total_revenue_items,
        SUM(oi.item_profit)       AS total_profit_items
    FROM   orders_clean      AS o
    INNER JOIN order_items_clean AS oi ON o.order_id = oi.order_id
    GROUP BY o.order_id
),
mismatched AS (
    SELECT order_id
    FROM   order_totals
    WHERE  total_revenue_order <> total_revenue_items
       OR  total_profit_order  <> total_profit_items
)
SELECT
    o.*,
    oi.*
FROM   orders_clean      AS o
INNER JOIN order_items_clean AS oi ON o.order_id   = oi.order_id
INNER JOIN mismatched        AS m  ON o.order_id   = m.order_id;

-- Finding: approximately 40 orders show discrepancies between the
--          stored order totals and the sum of their line items. No
--          clear pattern — flagging for review pending clarification
--          from the data provider.

DROP TEMPORARY TABLE IF EXISTS orders_revenue_profit_mismatch;

CREATE TEMPORARY TABLE orders_revenue_profit_mismatch AS
    WITH order_totals AS (
        SELECT
            o.order_id,
            MAX(o.total_revenue)  AS total_revenue_order,
            MAX(o.total_profit)   AS total_profit_order,
            SUM(oi.item_revenue)  AS total_revenue_items,
            SUM(oi.item_profit)   AS total_profit_items
        FROM   orders_clean      AS o
        INNER JOIN order_items_clean AS oi ON o.order_id = oi.order_id
        GROUP BY o.order_id
    )
    SELECT order_id
    FROM   order_totals
    WHERE  total_revenue_order <> total_revenue_items
       OR  total_profit_order  <> total_profit_items;

ALTER TABLE orders_clean
ADD COLUMN flag_revenue_or_profit_not_consistent BOOLEAN DEFAULT FALSE;

UPDATE orders_clean AS oc
INNER JOIN orders_revenue_profit_mismatch AS m ON oc.order_id = m.order_id
SET    oc.flag_revenue_or_profit_not_consistent = TRUE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 2  │  orders  ↔  deliveries
-- ─────────────────────────────────────────────────────────────

-- ── 2a. Referential integrity ─────────────────────────────────

-- Inspect: deliveries with no matching order.
SELECT *
FROM   deliveries_clean
WHERE  order_id NOT IN (SELECT order_id FROM orders_clean);

-- Inspect: delivered orders with no delivery record.
SELECT *
FROM   orders_clean
WHERE  order_id    NOT IN (SELECT order_id FROM deliveries_clean)
  AND  order_status <> 'Cancelled';

-- Finding: no orphaned IDs in either direction. No action needed.


-- ── 2b. Shipping days — validation and recalculation ──────────

-- Inspect: compare stored shipping day values against values
--          calculated from the date columns themselves.

WITH delivery_validation AS (
    SELECT
        o.order_id,
        o.order_date,
        d.promised_delivery_date,
        d.promised_shipping_days,
        DATEDIFF(d.promised_delivery_date, o.order_date)  AS promised_shipping_days_calculated,
        d.actual_delivery_date,
        d.actual_shipping_days,
        DATEDIFF(d.actual_delivery_date, o.order_date)    AS actual_shipping_days_calculated
    FROM   orders_clean     AS o
    INNER JOIN deliveries_clean AS d ON o.order_id = d.order_id
)
SELECT *
FROM   delivery_validation
WHERE  promised_shipping_days <> promised_shipping_days_calculated
   OR  actual_shipping_days   <> actual_shipping_days_calculated;

-- Finding: approximately 80% of rows show a mismatch.
--
--          For promised_shipping_days, this is expected by design:
--          promised_shipping_days is the delivery window shown to the
--          customer at checkout (determined by subscription tier),
--          while DATEDIFF(promised_delivery_date, order_date) reflects
--          the internal system processing time. These measure different
--          things and will naturally differ.
--
--          For actual_shipping_days, the mismatch is less expected and
--          requires clarification from the data provider. Storing the
--          date-derived values as separate columns in the interim.

DROP TEMPORARY TABLE IF EXISTS calculated_shipping_days;

CREATE TEMPORARY TABLE calculated_shipping_days AS
    SELECT
        o.order_id,
        DATEDIFF(d.promised_delivery_date, o.order_date)  AS promised_shipping_days_calculated,
        DATEDIFF(d.actual_delivery_date,   o.order_date)  AS actual_shipping_days_calculated
    FROM   orders_clean     AS o
    INNER JOIN deliveries_clean AS d ON o.order_id = d.order_id;

CREATE INDEX idx_calculated_shipping_days_order_id ON calculated_shipping_days (order_id);
CREATE INDEX idx_deliveries_clean_order_id         ON deliveries_clean (order_id);

ALTER TABLE deliveries_clean
ADD COLUMN promised_shipping_days_calculated INT,
ADD COLUMN actual_shipping_days_calculated   INT;

UPDATE deliveries_clean AS dc
INNER JOIN calculated_shipping_days AS cs ON dc.order_id = cs.order_id
SET    dc.promised_shipping_days_calculated = cs.promised_shipping_days_calculated,
       dc.actual_shipping_days_calculated   = cs.actual_shipping_days_calculated;


-- ─────────────────────────────────────────────────────────────
-- SECTION 3  │  orders  ↔  customers
-- ─────────────────────────────────────────────────────────────

-- ── 3a. Referential integrity ─────────────────────────────────

-- Inspect: orders whose customer_id has no match in customers_clean.
--          The reverse is not checked — customers with zero orders
--          are valid and expected.
SELECT *
FROM   orders_clean
WHERE  customer_id NOT IN (SELECT customer_id FROM customers_clean);

-- Finding: no orphaned customer IDs. No action needed.


-- ── 3b. Registration date validation ─────────────────────────

-- Inspect: customers whose earliest order predates their
--          registration date.
WITH first_orders AS (
    SELECT
        o.customer_id,
        MIN(o.order_date)        AS first_order_date,
        c.registration_date,
        DATEDIFF(MIN(o.order_date), c.registration_date) AS days_diff
    FROM   orders_clean    AS o
    INNER JOIN customers_clean AS c ON o.customer_id = c.customer_id
    GROUP BY o.customer_id, c.registration_date
)
SELECT *
FROM   first_orders
WHERE  days_diff < 0;

-- Finding: approximately 1,589 out of 2,800 customers have at least
--          one order that predates their recorded registration date.
--          This is a significant proportion and likely reflects a
--          data migration issue rather than random errors.
--          Flagging all affected customers and deferring to the
--          data provider for clarification.

DROP TEMPORARY TABLE IF EXISTS early_order_customers;

CREATE TEMPORARY TABLE early_order_customers AS
    SELECT
        o.customer_id,
        DATEDIFF(MIN(o.order_date), c.registration_date) AS days_diff
    FROM   orders_clean    AS o
    INNER JOIN customers_clean AS c ON o.customer_id = c.customer_id
    GROUP BY o.customer_id, c.registration_date
    HAVING DATEDIFF(MIN(o.order_date), c.registration_date) < 0;

ALTER TABLE customers_clean
ADD COLUMN flag_registration_date_unrealistic BOOLEAN DEFAULT FALSE;

UPDATE customers_clean AS cc
INNER JOIN early_order_customers AS eoc ON cc.customer_id = eoc.customer_id
SET    cc.flag_registration_date_unrealistic = TRUE;


-- ─────────────────────────────────────────────────────────────
-- SECTION 4  │  order_items  ↔  products
-- ─────────────────────────────────────────────────────────────

-- Inspect: order_items rows whose product_id has no match in
--          products_clean. The reverse is not checked — products
--          that were never ordered are valid.
SELECT *
FROM   order_items_clean
WHERE  product_id NOT IN (SELECT product_id FROM products_clean);

-- Finding: no orphaned product IDs. All ordered products exist
--          in the product catalogue. No action needed.