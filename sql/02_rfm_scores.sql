-- =====================================================================
-- 02_rfm_scores.sql  |  Score every customer on Recency, Frequency, Monetary
-- Dialect: SQLite 3.25+. Run after 01_clean.sql.
-- Output: rfm (one row per customer with R, F, M scores and a segment)
--
-- Each score is a quintile from NTILE(5), where 5 is best:
--   R: fewer days since last order is better
--   F: more distinct orders is better
--   M: more spend is better
-- 35% of customers ordered once, so many tie on frequency. Ties are broken
-- by spend (then customer id) so the scores are repeatable on every run.
-- Segments follow the standard recency x frequency grid.
-- =====================================================================

DROP TABLE IF EXISTS rfm;
CREATE TABLE rfm AS
WITH scored AS (
    SELECT c.*,
           NTILE(5) OVER (ORDER BY recency_days DESC, customer_id)        AS r_score,
           NTILE(5) OVER (ORDER BY frequency, monetary, customer_id)      AS f_score,
           NTILE(5) OVER (ORDER BY monetary, customer_id)                 AS m_score
    FROM customers c
)
SELECT *,
       r_score || '' || f_score || '' || m_score AS rfm_code,
       CASE
           WHEN r_score = 5 AND f_score >= 4                  THEN 'Champions'
           WHEN r_score >= 3 AND f_score >= 4                 THEN 'Loyal customers'
           WHEN r_score >= 4 AND f_score BETWEEN 2 AND 3      THEN 'Potential loyalists'
           WHEN r_score = 5 AND f_score = 1                   THEN 'New customers'
           WHEN r_score = 4 AND f_score = 1                   THEN 'Promising'
           WHEN r_score = 3 AND f_score = 3                   THEN 'Need attention'
           WHEN r_score = 3 AND f_score <= 2                  THEN 'About to sleep'
           WHEN r_score <= 2 AND f_score = 5                  THEN 'Cannot lose them'
           WHEN r_score <= 2 AND f_score BETWEEN 3 AND 4      THEN 'At risk'
           ELSE 'Hibernating'
       END AS segment
FROM scored;

CREATE INDEX idx_rfm_segment ON rfm (segment);
