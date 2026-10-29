-- =====================================================================
-- 02_analysis.sql  |  RFM segmentation, cohorts and revenue concentration
-- Dialect: SQLite 3.25+. Run 01_clean.sql and 02_rfm_scores.sql first.
-- Data runs 1 Dec 2010 to 9 Dec 2011; December 2011 is a partial month
-- and is left out of monthly trend charts.
-- =====================================================================


-- @name: overview
-- @section: Business at a glance
-- @title: Headline numbers
-- @chart: kpi money=revenue,avg_order_value
-- @insight: £8.26M from 4,324 identifiable customers over 12 months. Two in three customers ordered more than once, and the average order is worth £453, consistent with a business that sells largely to small retailers.
SELECT ROUND(SUM(line_revenue), 0)                                          AS revenue,
       COUNT(DISTINCT customer_id)                                          AS customers,
       COUNT(DISTINCT invoice_no)                                           AS orders,
       ROUND(SUM(line_revenue) / COUNT(DISTINCT invoice_no), 2)             AS avg_order_value,
       (SELECT ROUND(100.0 * SUM(frequency > 1) / COUNT(*), 1) FROM customers) AS repeat_customer_pct,
       COUNT(DISTINCT country)                                              AS countries
FROM transactions;


-- @name: monthly_revenue
-- @section: Business at a glance
-- @title: Monthly revenue (Dec 2010 to Nov 2011)
-- @chart: line x=month y=revenue money=revenue
-- @insight: Revenue doubled from a February low of £436K to £1.12M in November, driven by the run-up to Christmas. September to November alone brought in 36% of the year's sales.
SELECT SUBSTR(invoice_date, 1, 7)        AS month,
       ROUND(SUM(line_revenue), 0)       AS revenue,
       COUNT(DISTINCT invoice_no)        AS orders,
       COUNT(DISTINCT customer_id)       AS active_customers
FROM transactions
WHERE invoice_date < '2011-12-01'
GROUP BY month
ORDER BY month;


-- @name: new_vs_returning
-- @section: Business at a glance
-- @title: Active customers each month: new vs returning
-- @chart: bar x=month y=new_customers,returning_customers
-- @insight: Growth came from returning customers. New customers per month fell from about 400 in early 2011 to 170 in August, while returning customers rose from 322 in January to 1,334 in November.
WITH monthly AS (
    SELECT DISTINCT t.customer_id, SUBSTR(t.invoice_date, 1, 7) AS month,
           SUBSTR(c.first_purchase, 1, 7) AS first_month
    FROM transactions t
    JOIN customers c ON c.customer_id = t.customer_id
    WHERE t.invoice_date < '2011-12-01'
)
SELECT month,
       SUM(month = first_month)  AS new_customers,
       SUM(month <> first_month) AS returning_customers
FROM monthly
GROUP BY month
ORDER BY month;


-- @name: rfm_segments
-- @section: RFM segments
-- @title: RFM segment summary
-- @chart: table money=revenue,avg_spend
-- @insight: Champions and loyal customers are a third of the base but bring in 79% of revenue. A quarter of customers are hibernating: mostly single-order customers who last bought about seven months ago on average.
SELECT segment,
       COUNT(*)                                                    AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS customer_share_pct,
       ROUND(SUM(monetary), 0)                                     AS revenue,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS revenue_share_pct,
       ROUND(AVG(recency_days), 0)                                 AS avg_days_since_purchase,
       ROUND(AVG(frequency), 1)                                    AS avg_orders,
       ROUND(AVG(monetary), 0)                                     AS avg_spend
FROM rfm
GROUP BY segment
ORDER BY revenue DESC;


-- @name: segment_share
-- @section: RFM segments
-- @title: Share of customers vs share of revenue, by segment
-- @chart: hbar x=segment y=customer_share_pct,revenue_share_pct w=full
-- @insight: Champions are 15% of customers and 51% of revenue. At risk and Cannot lose them together hold another 9.6% of revenue that is drifting away.
SELECT segment,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS customer_share_pct,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS revenue_share_pct
FROM rfm
GROUP BY segment
ORDER BY revenue_share_pct DESC;


-- @name: rf_grid
-- @section: RFM segments
-- @title: Customers by recency score (rows) and frequency score (columns)
-- @chart: table
-- @insight: The diagonal tells the story: frequent buyers are recent (441 customers score R5 F5) and one-time buyers are lapsed (392 score R1 F1).
SELECT 'R' || r_score        AS recency_score,
       SUM(f_score = 1)      AS f1,
       SUM(f_score = 2)      AS f2,
       SUM(f_score = 3)      AS f3,
       SUM(f_score = 4)      AS f4,
       SUM(f_score = 5)      AS f5
FROM rfm
GROUP BY r_score
ORDER BY r_score DESC;


-- @name: revenue_concentration
-- @section: RFM segments
-- @title: Share of revenue by customer spend quintile
-- @chart: bar x=spend_quintile y=revenue_share_pct
-- @insight: The top 20% of customers by spend generate 74% of revenue, close to the 80/20 rule. The bottom 40% generate 5%.
WITH q AS (
    SELECT monetary, NTILE(5) OVER (ORDER BY monetary DESC) AS quintile
    FROM customers
)
SELECT CASE quintile WHEN 1 THEN 'Top 20%' WHEN 2 THEN '20-40%' WHEN 3 THEN '40-60%'
                     WHEN 4 THEN '60-80%' ELSE 'Bottom 20%' END       AS spend_quintile,
       COUNT(*)                                                      AS customers,
       ROUND(SUM(monetary), 0)                                       AS revenue,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1)  AS revenue_share_pct
FROM q
GROUP BY quintile
ORDER BY quintile;


-- @name: at_risk_customers
-- @section: RFM segments
-- @title: Win-back list: highest-spending customers in At risk and Cannot lose them
-- @chart: table money=lifetime_spend
-- @insight: This is the win-back list. The top 15 lapsed customers spent £122K between them, and several placed 8 to 34 orders before going quiet.
SELECT customer_id,
       segment,
       country,
       frequency                 AS orders,
       ROUND(monetary, 0)        AS lifetime_spend,
       last_purchase,
       recency_days              AS days_since_last_order
FROM rfm
WHERE segment IN ('At risk', 'Cannot lose them')
ORDER BY monetary DESC
LIMIT 15;


-- @name: cohort_retention
-- @section: Retention
-- @title: Monthly cohort retention: % of each month's new customers who bought again N months later
-- @chart: table
-- @insight: December 2010's cohort, the business's established customers, keeps 32% to 38% active each month. Customers acquired during 2011 settle at about 15% to 30%.
WITH first_month AS (
    SELECT customer_id, SUBSTR(first_purchase, 1, 7) AS cohort FROM customers
),
activity AS (
    SELECT DISTINCT t.customer_id, f.cohort,
           (CAST(SUBSTR(t.invoice_date, 1, 4) AS INTEGER) - CAST(SUBSTR(f.cohort, 1, 4) AS INTEGER)) * 12
         + (CAST(SUBSTR(t.invoice_date, 6, 2) AS INTEGER) - CAST(SUBSTR(f.cohort, 6, 2) AS INTEGER)) AS month_number
    FROM transactions t
    JOIN first_month f ON f.customer_id = t.customer_id
    WHERE t.invoice_date < '2011-12-01'
),
sizes AS (
    SELECT cohort, COUNT(*) AS cohort_size FROM first_month GROUP BY cohort
)
SELECT a.cohort,
       s.cohort_size,
       CASE WHEN a.cohort <= STRFTIME('%Y-%m', DATE('2011-11-01', '-1 months'))
            THEN ROUND(100.0 * SUM(a.month_number = 1) / s.cohort_size, 1) END AS m1_pct,
       CASE WHEN a.cohort <= STRFTIME('%Y-%m', DATE('2011-11-01', '-2 months'))
            THEN ROUND(100.0 * SUM(a.month_number = 2) / s.cohort_size, 1) END AS m2_pct,
       CASE WHEN a.cohort <= STRFTIME('%Y-%m', DATE('2011-11-01', '-3 months'))
            THEN ROUND(100.0 * SUM(a.month_number = 3) / s.cohort_size, 1) END AS m3_pct,
       CASE WHEN a.cohort <= STRFTIME('%Y-%m', DATE('2011-11-01', '-6 months'))
            THEN ROUND(100.0 * SUM(a.month_number = 6) / s.cohort_size, 1) END AS m6_pct,
       CASE WHEN a.cohort <= STRFTIME('%Y-%m', DATE('2011-11-01', '-11 months'))
            THEN ROUND(100.0 * SUM(a.month_number = 11) / s.cohort_size, 1) END AS m11_pct
FROM activity a
JOIN sizes s ON s.cohort = a.cohort
WHERE a.cohort < '2011-12'
GROUP BY a.cohort
ORDER BY a.cohort;


-- @name: retention_curve
-- @section: Retention
-- @title: Average retention by months since first purchase (all cohorts, weighted)
-- @chart: line x=month_number y=retention_pct zero=yes
-- @insight: Across all cohorts, about a quarter of new customers order again the next month. The later rise reflects the Christmas season and the strong December 2010 cohort, which is the only one observable at month 11.
WITH first_month AS (
    SELECT customer_id, SUBSTR(first_purchase, 1, 7) AS cohort FROM customers
),
activity AS (
    SELECT DISTINCT t.customer_id, f.cohort,
           (CAST(SUBSTR(t.invoice_date, 1, 4) AS INTEGER) - CAST(SUBSTR(f.cohort, 1, 4) AS INTEGER)) * 12
         + (CAST(SUBSTR(t.invoice_date, 6, 2) AS INTEGER) - CAST(SUBSTR(f.cohort, 6, 2) AS INTEGER)) AS month_number
    FROM transactions t
    JOIN first_month f ON f.customer_id = t.customer_id
    WHERE t.invoice_date < '2011-12-01'
),
eligible AS (
    -- a cohort can only be measured at month N if month N is inside the data
    SELECT n.month_number, SUM(s.cohort_size) AS customers_observable
    FROM (SELECT DISTINCT month_number FROM activity WHERE month_number BETWEEN 1 AND 11) n
    JOIN (SELECT cohort, COUNT(*) AS cohort_size FROM first_month GROUP BY cohort) s
      ON (2011 - CAST(SUBSTR(s.cohort, 1, 4) AS INTEGER)) * 12 + (11 - CAST(SUBSTR(s.cohort, 6, 2) AS INTEGER)) >= n.month_number
    GROUP BY n.month_number
)
SELECT a.month_number,
       COUNT(*)                                                AS customers_active,
       e.customers_observable,
       ROUND(100.0 * COUNT(*) / e.customers_observable, 1)     AS retention_pct
FROM activity a
JOIN eligible e ON e.month_number = a.month_number
GROUP BY a.month_number
ORDER BY a.month_number;


-- @name: second_purchase
-- @section: Retention
-- @title: Days from first to second order (repeat customers)
-- @chart: bar x=days_to_second_order y=customers
-- @insight: A third of repeat customers come back within 30 days, and 67% within 90 days. After 180 days a second order becomes unlikely.
WITH orders AS (
    SELECT customer_id, invoice_no, MIN(invoice_date) AS order_date
    FROM transactions
    GROUP BY customer_id, invoice_no
),
ranked AS (
    SELECT customer_id, order_date,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date, invoice_no) AS n
    FROM orders
),
gaps AS (
    SELECT a.customer_id, JULIANDAY(b.order_date) - JULIANDAY(a.order_date) AS days
    FROM ranked a
    JOIN ranked b ON b.customer_id = a.customer_id AND b.n = 2
    WHERE a.n = 1
)
SELECT CASE WHEN days = 0 THEN 'Same day'
            WHEN days <= 30 THEN '1-30'
            WHEN days <= 60 THEN '31-60'
            WHEN days <= 90 THEN '61-90'
            WHEN days <= 180 THEN '91-180'
            ELSE '180+' END                                 AS days_to_second_order,
       COUNT(*)                                             AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS share_pct
FROM gaps
GROUP BY days_to_second_order
ORDER BY MIN(days);


-- @name: country_revenue
-- @section: Markets and products
-- @title: Revenue by country (top 10)
-- @chart: hbar x=country y=revenue money=revenue,revenue_per_customer
-- @insight: The UK brings 82% of revenue. A handful of overseas accounts are very large: 9 Dutch customers average £31K each and 3 Irish customers £81K.
SELECT country,
       COUNT(DISTINCT customer_id)                                         AS customers,
       ROUND(SUM(line_revenue), 0)                                         AS revenue,
       ROUND(100.0 * SUM(line_revenue) / (SELECT SUM(line_revenue) FROM transactions), 1) AS revenue_share_pct,
       ROUND(SUM(line_revenue) / COUNT(DISTINCT customer_id), 0)           AS revenue_per_customer
FROM transactions
GROUP BY country
ORDER BY revenue DESC
LIMIT 10;


-- @name: top_products
-- @section: Markets and products
-- @title: Top 12 products by revenue
-- @chart: hbar x=description y=revenue money=revenue
-- @insight: The Regency cakestand is the top earner at £136K, bought by 871 customers. Most top products are low-priced decorative lines sold in bulk.
SELECT stock_code,
       MAX(description)               AS description,
       SUM(quantity)                  AS units,
       ROUND(SUM(line_revenue), 0)    AS revenue,
       COUNT(DISTINCT customer_id)    AS customers
FROM transactions
GROUP BY stock_code
ORDER BY revenue DESC
LIMIT 12;


-- @name: data_quality
-- @section: Data quality
-- @title: What the cleaning step found and fixed
-- @chart: table
-- @insight: Removing reversed orders matters: dropping only the 'C' cancellation invoices would leave in a single 80,995-unit paper bird order (£168K) that was cancelled the same day, which would have been the top product of the year.
SELECT check_name, rows_affected, action
FROM data_quality_log;
