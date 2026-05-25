-- ============================================================
-- Database: bytecart_data
-- Purpose : final data-engineering feedback implementation
--           and final table creation for Tableau CSV exports
-- ============================================================

USE bytecart_data;


-- ------------------------------------------------------------
-- SECTION 1  |  data-engineering feedback and decisions
-- ------------------------------------------------------------

-- 1. Problem:
--      Inconsistencies between delivery dates and the stored
--      promised_shipping_days / actual_shipping_days fields.
--    Data provider answer:
--      promised_shipping_days is the customer-facing delivery window
--      based on customer tier, while promised_delivery_date is the
--      internal system estimate based on warehouse load.
--      actual_shipping_days is measured from carrier dispatch date,
--      not from order_date.
--    Conclusion:
--      Drop promised_shipping_days and actual_shipping_days from the
--      final analytical exports. Keep the date columns and recalculate
--      only the delay metric needed for analysis.

-- 2. Problem:
--      delay_days is inconsistent with delivery_outcome and the
--      delivery date columns.
--    Data provider answer:
--      delay_days was populated from the carrier API and contains
--      known errors. The date columns are the ground truth.
--    Conclusion:
--      Use recalculated delay_days based on first_attempt_date and
--      promised_delivery_date in deliveries_final.

-- 3. Problem:
--      actual_shipping_days contains negative values, zeros, and a
--      99-day outlier.
--    Data provider answer:
--      Negative values and zeros came from a known carrier webhook
--      bug. The 99-day value is a specific parcel from December 2022
--      that was misrouted.
--    Conclusion:
--      Drop actual_shipping_days from the final delivery export and
--      rely on delivery dates for date-based analysis.

-- 4. Problem:
--      Some customers have an earliest order date before their
--      registration_date.
--    Data provider answer:
--      This is a CRM migration artefact. registration_date was set to
--      the account creation date in the new platform, not the date
--      when the customer first transacted.
--    Conclusion:
--      Exclude registration_date from customers_final.

-- 5. Problem:
--      review_score and delivery_satisfaction contain values of 6
--      and 7, although the current scale is 1-5.
--    Data provider answer:
--      These values came from a legacy 10-point review scale before
--      migration and cannot be reliably remapped to the current 1-5
--      scale.
--    Conclusion:
--      Convert out-of-range review_score and delivery_satisfaction
--      values to NULL in the final exports.

-- 6. Problem:
--      Some revenue and quantity values are negative.
--    Data provider answer:
--      These values were caused by a sign-convention bug in the batch
--      export script.
--    Conclusion:
--      Use the absolute / cleaned values already created in the
--      individual table cleaning scripts.

-- 7. Problem:
--      Courier data is missing for some orders.
--    Data provider answer:
--      These deliveries were processed through a third-party fulfilment
--      aggregator during peak overflow. The aggregator confirms delivery
--      but does not expose carrier name through the API.
--    Conclusion:
--      Keep NULL courier values.

-- 8. Problem:
--      Approximately 40 orders have total_revenue or total_profit
--      values that do not match the sum of order_items_clean.
--    Data provider answer:
--      Order-level totals include last-minute sales, manual adjustments,
--      and order-level corrections that were written directly to the
--      order totals and not pushed down to individual product rows.
--    Conclusion:
--      Keep order-level total_revenue and total_profit as the source
--      of truth for order-level revenue and profit analysis.

-- 9. Problem:
--      Some order_items rows have quantity_clean IS NULL while revenue,
--      cost, and profit are all zero.
--    Data provider answer:
--      These are cancelled lines. No units were fulfilled, and the zero
--      financial values confirm that the business event is known rather
--      than missing.
--    Conclusion:
--      Set final quantity to 0 for these cancelled zero-value lines.
--      Use NULL only when a value is genuinely unknown.


-- ------------------------------------------------------------
-- SECTION 2  |  final table creation
-- ------------------------------------------------------------

-- Customers: keep only analytical customer attributes. Exclude PII,
-- registration_date, and cross-table flag columns.

DROP TABLE IF EXISTS customers_final;

CREATE TABLE customers_final AS
    SELECT
        customer_id,
        gender,
        age,
        tier,
        region,
        city
    FROM   customers_clean;


-- Orders: keep order-level analytical fields. Replace total_quantity
-- with the corrected value, set cancelled zero-value orders to 0, and
-- exclude flag columns.

DROP TABLE IF EXISTS orders_final;

CREATE TABLE orders_final AS
    SELECT
        order_id,
        customer_id,
        order_date,
        order_status,
        payment_method,
        shipping_days,
        delivery_date,
        total_revenue,
        total_profit,
        CASE
            WHEN total_quantity_clean IS NOT NULL THEN total_quantity_clean
            WHEN total_revenue = 0
             AND total_profit  = 0 THEN 0
            ELSE NULL
        END AS total_quantity,
        num_items
    FROM   orders_clean;


-- Order items: retain analytical line-item fields. Replace quantity
-- with the corrected value, set cancelled zero-value lines to 0, and
-- convert legacy out-of-range review scores to NULL.

DROP TABLE IF EXISTS order_items_final;

CREATE TABLE order_items_final AS
    SELECT
        order_item_id,
        order_id,
        product_id,
        CASE
            WHEN quantity_clean IS NOT NULL THEN quantity_clean
            WHEN item_revenue = 0
             AND item_cogs    = 0
             AND item_profit  = 0 THEN 0
            ELSE NULL
        END AS quantity,
        list_price,
        discount_rate,
        unit_price,
        item_revenue,
        item_cogs,
        item_profit,
        profit_margin,
        CASE
            WHEN review_score BETWEEN 1 AND 5 THEN review_score
            ELSE NULL
        END AS review_score,
        review_text
    FROM   order_items_clean;


-- Deliveries: keep delivery identifiers, dates, selected operational
-- fields, and a recalculated delay metric. Drop ambiguous day-count
-- fields, delivery_outcome, is_on_time, attempts, and flags.

DROP TABLE IF EXISTS deliveries_final;

CREATE TABLE deliveries_final AS
    SELECT
        delivery_id,
        order_id,
        customer_id,
        courier,
        promised_delivery_date,
        actual_delivery_date,
        first_attempt_date,
        DATEDIFF(first_attempt_date, promised_delivery_date) AS delay_days,
        package_condition,
        is_returned,
        return_reason,
        CASE
            WHEN delivery_satisfaction BETWEEN 1 AND 5 THEN delivery_satisfaction
            ELSE NULL
        END AS delivery_satisfaction,
        complaint_raised
    FROM   deliveries_clean;


-- Products: keep catalogue and pricing fields used for analysis.
-- Exclude reorder_point, weight_kg, and is_active. Keep
-- discontinue_date because it can support product lifecycle analysis.

DROP TABLE IF EXISTS products_final;

CREATE TABLE products_final AS
    SELECT
        product_id,
        product_name,
        category,
        subcategory,
        brand,
        base_price,
        unit_cost,
        base_margin,
        stock_quantity,
        launch_date,
        discontinue_date
    FROM   products_clean;

-- ------------------------------------------------------------
-- SECTION 3  |  CSV exports
-- ------------------------------------------------------------

SELECT
    customer_id, gender, age, tier, region, city
FROM (
    SELECT
        'customer_id' AS customer_id,
        'gender'      AS gender,
        'age'         AS age,
        'tier'        AS tier,
        'region'      AS region,
        'city'        AS city
    UNION ALL
    SELECT
        customer_id,
        gender,
        CAST(age AS CHAR),
        tier,
        region,
        city
    FROM   customers_final
) AS export_customers
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/customers_final.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';


SELECT
    order_id, customer_id, order_date, order_status,
    payment_method, shipping_days, delivery_date,
    total_revenue, total_profit, total_quantity, num_items
FROM (
    SELECT
        'order_id'       AS order_id,
        'customer_id'    AS customer_id,
        'order_date'     AS order_date,
        'order_status'   AS order_status,
        'payment_method' AS payment_method,
        'shipping_days'  AS shipping_days,
        'delivery_date'  AS delivery_date,
        'total_revenue'  AS total_revenue,
        'total_profit'   AS total_profit,
        'total_quantity' AS total_quantity,
        'num_items'      AS num_items
    UNION ALL
    SELECT
        order_id,
        customer_id,
        CAST(order_date AS CHAR),
        order_status,
        payment_method,
        CAST(shipping_days AS CHAR),
        CAST(delivery_date AS CHAR),
        CAST(total_revenue AS CHAR),
        CAST(total_profit AS CHAR),
        CAST(total_quantity AS CHAR),
        CAST(num_items AS CHAR)
    FROM   orders_final
) AS export_orders
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/orders_final.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';


SELECT
    order_item_id, order_id, product_id, quantity,
    list_price, discount_rate, unit_price, item_revenue,
    item_cogs, item_profit, profit_margin,
    review_score, review_text
FROM (
    SELECT
        'order_item_id' AS order_item_id,
        'order_id'      AS order_id,
        'product_id'    AS product_id,
        'quantity'      AS quantity,
        'list_price'    AS list_price,
        'discount_rate' AS discount_rate,
        'unit_price'    AS unit_price,
        'item_revenue'  AS item_revenue,
        'item_cogs'     AS item_cogs,
        'item_profit'   AS item_profit,
        'profit_margin' AS profit_margin,
        'review_score'  AS review_score,
        'review_text'   AS review_text
    UNION ALL
    SELECT
        order_item_id,
        order_id,
        product_id,
        CAST(quantity AS CHAR),
        CAST(list_price AS CHAR),
        CAST(discount_rate AS CHAR),
        CAST(unit_price AS CHAR),
        CAST(item_revenue AS CHAR),
        CAST(item_cogs AS CHAR),
        CAST(item_profit AS CHAR),
        CAST(profit_margin AS CHAR),
        CAST(review_score AS CHAR),
        review_text
    FROM   order_items_final
) AS export_order_items
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/order_items_final.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';


SELECT
    delivery_id, order_id, customer_id, courier,
    promised_delivery_date, actual_delivery_date,
    first_attempt_date, delay_days, package_condition,
    is_returned, return_reason, delivery_satisfaction,
    complaint_raised
FROM (
    SELECT
        'delivery_id'           AS delivery_id,
        'order_id'              AS order_id,
        'customer_id'           AS customer_id,
        'courier'               AS courier,
        'promised_delivery_date' AS promised_delivery_date,
        'actual_delivery_date'  AS actual_delivery_date,
        'first_attempt_date'    AS first_attempt_date,
        'delay_days'            AS delay_days,
        'package_condition'     AS package_condition,
        'is_returned'           AS is_returned,
        'return_reason'         AS return_reason,
        'delivery_satisfaction' AS delivery_satisfaction,
        'complaint_raised'      AS complaint_raised
    UNION ALL
    SELECT
        delivery_id,
        order_id,
        customer_id,
        courier,
        CAST(promised_delivery_date AS CHAR),
        CAST(actual_delivery_date AS CHAR),
        CAST(first_attempt_date AS CHAR),
        CAST(delay_days AS CHAR),
        package_condition,
        CAST(is_returned AS CHAR),
        return_reason,
        CAST(delivery_satisfaction AS CHAR),
        CAST(complaint_raised AS CHAR)
    FROM   deliveries_final
) AS export_deliveries
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/deliveries_final.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';


SELECT
    product_id, product_name, category, subcategory,
    brand, base_price, unit_cost, base_margin,
    stock_quantity, launch_date, discontinue_date
FROM (
    SELECT
        'product_id'        AS product_id,
        'product_name'      AS product_name,
        'category'          AS category,
        'subcategory'       AS subcategory,
        'brand'             AS brand,
        'base_price'        AS base_price,
        'unit_cost'         AS unit_cost,
        'base_margin'       AS base_margin,
        'stock_quantity'    AS stock_quantity,
        'launch_date'       AS launch_date,
        'discontinue_date'  AS discontinue_date
    UNION ALL
    SELECT
        product_id,
        product_name,
        category,
        subcategory,
        brand,
        CAST(base_price AS CHAR),
        CAST(unit_cost AS CHAR),
        CAST(base_margin AS CHAR),
        CAST(stock_quantity AS CHAR),
        CAST(launch_date AS CHAR),
        CAST(discontinue_date AS CHAR)
    FROM   products_final
) AS export_products
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/products_final.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';
