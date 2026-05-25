-- Create database
CREATE DATABASE bytecart_data;
USE bytecart_data;

-- =========================
-- PRODUCTS TABLE
-- =========================

DROP TABLE IF EXISTS products;

CREATE TABLE products (
    product_id VARCHAR(50),
    product_name VARCHAR(255),
    category VARCHAR(255),
    subcategory VARCHAR(255),
    brand VARCHAR(255),
    base_price VARCHAR(50),
    unit_cost VARCHAR(50),
    base_margin VARCHAR(50),
    stock_quantity VARCHAR(50),
    reorder_point VARCHAR(50),
    launch_date VARCHAR(100),
    discontinue_date VARCHAR(100),
    is_active VARCHAR(50),
    weight_kg VARCHAR(50)
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/2/products.csv'
INTO TABLE products
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- =========================
-- ORDERS TABLE
-- =========================

DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id VARCHAR(50),
    customer_id VARCHAR(50),
    order_date VARCHAR(50),
    order_status VARCHAR(100),
    payment_method VARCHAR(100),
    shipping_days VARCHAR(50),
    delivery_date VARCHAR(50),
    total_revenue VARCHAR(50),
    total_profit VARCHAR(50),
    total_quantity VARCHAR(50),
    num_items VARCHAR(50)
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/2/orders.csv'
INTO TABLE orders
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- =========================
-- ORDER ITEMS TABLE
-- =========================

DROP TABLE IF EXISTS order_items;

CREATE TABLE order_items (
    order_item_id VARCHAR(50),
    order_id VARCHAR(50),
    product_id VARCHAR(50),
    quantity VARCHAR(50),
    list_price VARCHAR(50),
    discount_rate VARCHAR(50),
    unit_price VARCHAR(50),
    item_revenue VARCHAR(50),
    item_cogs VARCHAR(50),
    item_profit VARCHAR(50),
    profit_margin VARCHAR(50),
    review_score VARCHAR(50),
    review_text TEXT
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/2/order_items.csv'
INTO TABLE order_items
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- =========================
-- DELIVERIES TABLE
-- =========================

DROP TABLE IF EXISTS deliveries;

CREATE TABLE deliveries (
    delivery_id VARCHAR(50),
    order_id VARCHAR(50),
    customer_id VARCHAR(50),
    courier VARCHAR(255),
    promised_shipping_days VARCHAR(50),
    promised_delivery_date VARCHAR(50),
    actual_shipping_days VARCHAR(50),
    actual_delivery_date VARCHAR(50),
    delay_days VARCHAR(50),
    delivery_outcome VARCHAR(100),
    is_on_time VARCHAR(50),
    first_attempt_date VARCHAR(50),
    delivery_attempts VARCHAR(50),
    package_condition VARCHAR(100),
    is_returned VARCHAR(50),
    return_reason VARCHAR(255),
    delivery_satisfaction VARCHAR(50),
    complaint_raised VARCHAR(50)
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/2/deliveries.csv'
INTO TABLE deliveries
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- =========================
-- CUSTOMERS TABLE
-- =========================

DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id VARCHAR(50),
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    full_name VARCHAR(255),
    gender VARCHAR(50),
    age VARCHAR(50),
    tier VARCHAR(100),
    registration_date VARCHAR(50),
    region VARCHAR(100),
    city VARCHAR(100),
    email VARCHAR(255),
    phone VARCHAR(100)
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/2/customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;
