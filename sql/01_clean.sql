-- =====================================================================
-- 01_clean.sql  |  Online Retail transactions: profiling and cleaning
-- Dialect: SQLite 3.25+  (also runs in DB Browser for SQLite)
-- Input : retail_raw (UCI Online Retail CSV, every column TEXT)
-- Output: transactions (clean sales lines), customers (one row per
--         customer with RFM inputs), data_quality_log
-- =====================================================================

DROP TABLE IF EXISTS data_quality_log;
CREATE TABLE data_quality_log (check_name TEXT, rows_affected INTEGER, action TEXT);

INSERT INTO data_quality_log SELECT 'Raw invoice lines loaded', COUNT(*), 'none' FROM retail_raw;

INSERT INTO data_quality_log
SELECT 'No customer id (guest checkout)', COUNT(*), 'excluded: cannot be tied to a customer'
FROM retail_raw WHERE CustomerID IS NULL;

INSERT INTO data_quality_log
SELECT 'Cancelled invoices (invoice number starts with C)', COUNT(*), 'excluded'
FROM retail_raw WHERE InvoiceNo LIKE 'C%';

INSERT INTO data_quality_log
SELECT 'Zero or negative quantity or price (adjustments, damages)', COUNT(*), 'excluded'
FROM retail_raw WHERE CAST(Quantity AS INTEGER) <= 0 OR CAST(UnitPrice AS REAL) <= 0;

INSERT INTO data_quality_log
SELECT 'Non-product lines (postage, fees, manual, vouchers)', COUNT(*), 'excluded'
FROM retail_raw
WHERE StockCode IN ('POST', 'DOT', 'M', 'm', 'C2', 'D', 'S', 'B', 'BANK CHARGES', 'AMAZONFEE', 'CRUK', 'PADS')
   OR StockCode LIKE 'gift%';

INSERT INTO data_quality_log
SELECT 'Exact duplicate lines', COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM retail_raw)), 'kept one copy'
FROM retail_raw;

-- ---------------------------------------------------------------------
-- Step 1: typed, de-duplicated lines (sales AND cancellations).
-- InvoiceDate arrives as 'M/D/YYYY H:MM' text, which sorts wrongly;
-- rebuild it as ISO 'YYYY-MM-DD HH:MM' so date functions work.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS lines;
CREATE TABLE lines AS
WITH dedup AS (
    SELECT DISTINCT * FROM retail_raw WHERE CustomerID IS NOT NULL
),
d1 AS (
    SELECT *, SUBSTR(InvoiceDate, INSTR(InvoiceDate, '/') + 1) AS after_month FROM dedup
),
d2 AS (
    SELECT *, SUBSTR(after_month, INSTR(after_month, '/') + 1) AS after_day FROM d1
)
SELECT
    InvoiceNo                                                     AS invoice_no,
    StockCode                                                     AS stock_code,
    TRIM(Description)                                             AS description,
    CAST(Quantity AS INTEGER)                                     AS quantity,
    CAST(UnitPrice AS REAL)                                       AS unit_price,
    ROUND(CAST(Quantity AS INTEGER) * CAST(UnitPrice AS REAL), 2) AS line_revenue,
    CAST(CAST(CustomerID AS REAL) AS INTEGER)                     AS customer_id,
    Country                                                       AS country,
    SUBSTR(after_day, 1, 4) || '-' ||
        PRINTF('%02d', CAST(SUBSTR(InvoiceDate, 1, INSTR(InvoiceDate, '/') - 1) AS INTEGER)) || '-' ||
        PRINTF('%02d', CAST(SUBSTR(after_month, 1, INSTR(after_month, '/') - 1) AS INTEGER)) || ' ' ||
        REPLACE(PRINTF('%5s', SUBSTR(after_day, 6)), ' ', '0')    AS invoice_ts
FROM d2;

-- ---------------------------------------------------------------------
-- Step 2: valid sales lines
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS transactions;
CREATE TABLE transactions AS
SELECT *, SUBSTR(invoice_ts, 1, 10) AS invoice_date
FROM lines
WHERE invoice_no NOT LIKE 'C%'
  AND quantity > 0
  AND unit_price > 0
  AND stock_code NOT IN ('POST', 'DOT', 'M', 'm', 'C2', 'D', 'S', 'B', 'BANK CHARGES', 'AMAZONFEE', 'CRUK', 'PADS')
  AND stock_code NOT LIKE 'gift%';

-- ---------------------------------------------------------------------
-- Step 3: remove orders that were later cancelled.
-- Dropping the 'C' invoices alone leaves the original order in place: the
-- single biggest line in the file (80,995 paper birds, £168K) was cancelled
-- the same day. Match each cancellation to the sale it reverses.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS reversed_lines;
CREATE TABLE reversed_lines AS
SELECT DISTINCT t.rowid AS sale_rowid
FROM transactions t
JOIN lines c
  ON  c.invoice_no LIKE 'C%'
  AND c.customer_id = t.customer_id
  AND c.stock_code  = t.stock_code
  AND -c.quantity   = t.quantity
  AND c.invoice_ts >= t.invoice_ts;

INSERT INTO data_quality_log
SELECT 'Sales later reversed by a matching cancellation', COUNT(*), 'excluded'
FROM reversed_lines;

DELETE FROM transactions WHERE rowid IN (SELECT sale_rowid FROM reversed_lines);

INSERT INTO data_quality_log SELECT 'Clean sales lines', COUNT(*), 'final table' FROM transactions;

CREATE INDEX idx_t_customer ON transactions (customer_id);
CREATE INDEX idx_t_invoice ON transactions (invoice_no);

-- ---------------------------------------------------------------------
-- One row per customer: the R, F and M inputs.
-- Recency is measured from the day after the last invoice in the data.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS customers;
CREATE TABLE customers AS
WITH snapshot AS (
    SELECT DATE(MAX(invoice_date), '+1 day') AS snapshot_date FROM transactions
)
SELECT
    t.customer_id,
    MAX(t.country)                                                         AS country,
    MIN(t.invoice_date)                                                    AS first_purchase,
    MAX(t.invoice_date)                                                    AS last_purchase,
    CAST(JULIANDAY(s.snapshot_date) - JULIANDAY(MAX(t.invoice_date)) AS INTEGER) AS recency_days,
    COUNT(DISTINCT t.invoice_no)                                           AS frequency,
    ROUND(SUM(t.line_revenue), 2)                                          AS monetary
FROM transactions t
CROSS JOIN snapshot s
GROUP BY t.customer_id;
