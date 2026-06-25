/* ============================================================
   UK FINANCIAL SERVICES COMPLAINTS ANALYSIS
   ------------------------------------------------------------
   Source : Financial Conduct Authority (FCA) firm-level
            complaints data
   Periods: H2 2024, H1 2025, H2 2025
   Engine : PostgreSQL 16

   Tables:
     complaints_opened  - complaints received per firm /
                          product / period
     complaints_upheld  - % of complaints upheld (firm at fault)
     complaints_closed  - complaints resolved per firm /
                          product / period

   ============================================================ */


/* ============================================================
   DATABASE SETUP - Table Definitions
   ------------------------------------------------------------
   Data provenance:
   The raw data originates from the Financial Conduct Authority
   (FCA) firm-level complaints publications, downloaded as Excel
   workbooks from fca.org.uk/data/complaints-data for the
   periods H2 2024, H1 2025, and H2 2025.

   The raw FCA workbooks store each product category as a
   separate column (wide format) across multiple sheets. A
   Python/pandas cleaning step reshaped this into long format
   (one row per firm / product / period), removed empty
   records, standardised column names, and converted uphold
   rates from decimals to percentages. The resulting three
   CSV files are imported into the tables below.

   Data was imported using pgAdmin's Import tool; the CREATE
   TABLE statements are included here so the schema is fully
   reproducible.
   ============================================================ */

CREATE TABLE complaints_opened (
    firm_name         TEXT,
    firm_group        TEXT,
    reporting_period  TEXT,
    period            TEXT,
    product_category  TEXT,
    complaints_opened INTEGER
);

CREATE TABLE complaints_upheld (
    firm_name         TEXT,
    firm_group        TEXT,
    reporting_period  TEXT,
    period            TEXT,
    product_category  TEXT,
    uphold_rate       NUMERIC
);

CREATE TABLE complaints_closed (
    firm_name         TEXT,
    firm_group        TEXT,
    reporting_period  TEXT,
    period            TEXT,
    product_category  TEXT,
    complaints_closed INTEGER
);


/* ============================================================
   QUERY 1 - Top 10 Most Complained-About Firms (H2 2025)
   Question: Which firms received the most complaints in the
             most recent period?
   Skills  : SUM aggregation, GROUP BY, ORDER BY, LIMIT
   ============================================================ */
SELECT
    firm_name,
    SUM(complaints_opened) AS total_complaints
FROM complaints_opened
WHERE period = 'H2 2025'
GROUP BY firm_name
ORDER BY total_complaints DESC
LIMIT 10;


/* ============================================================
   QUERY 2 - Firms with the Highest Uphold Rates (H2 2025)
   Question: Which firms admitted being at fault most often
             (uphold rate above 80%)?
   Note    : A high uphold rate means the firm agreed the
             complaint was justified.
   Skills  : AVG, ROUND, GROUP BY, HAVING
   ============================================================ */
SELECT
    firm_name,
    product_category,
    ROUND(AVG(uphold_rate), 1) AS avg_uphold_rate
FROM complaints_upheld
WHERE period = 'H2 2025'
GROUP BY firm_name, product_category
HAVING AVG(uphold_rate) > 80
ORDER BY avg_uphold_rate DESC;


/* ============================================================
   QUERY 3 - Year-on-Year Complaint Change (H2 2024 vs H2 2025)
   Question: Which firms saw the largest percentage change in
             complaints over a full year?
   Skills  : Common Table Expressions (CTEs), JOIN,
             calculated percentage change
   ============================================================ */
WITH h2_2024 AS (
    SELECT
        firm_name,
        SUM(complaints_opened) AS total_2024
    FROM complaints_opened
    WHERE period = 'H2 2024'
    GROUP BY firm_name
),
h2_2025 AS (
    SELECT
        firm_name,
        SUM(complaints_opened) AS total_2025
    FROM complaints_opened
    WHERE period = 'H2 2025'
    GROUP BY firm_name
)
SELECT
    h2_2024.firm_name,
    h2_2024.total_2024,
    h2_2025.total_2025,
    (h2_2025.total_2025 - h2_2024.total_2024) AS change,
    ROUND(
        (h2_2025.total_2025 - h2_2024.total_2024) * 100.0
        / h2_2024.total_2024,
    1) AS pct_change
FROM h2_2024
JOIN h2_2025 ON h2_2024.firm_name = h2_2025.firm_name
ORDER BY pct_change DESC
LIMIT 15;


/* ============================================================
   QUERY 4 - Complaints and Uphold Rates by Product Category
   Question: Which financial product generates the most
             complaints, and how often are they upheld?
   Skills  : Multi-key LEFT JOIN, aggregation by two
             dimensions (product and period)
   ============================================================ */
SELECT
    complaints_opened.product_category,
    complaints_opened.period,
    SUM(complaints_opened.complaints_opened)      AS total_complaints,
    ROUND(AVG(complaints_upheld.uphold_rate), 1)  AS avg_uphold_rate
FROM complaints_opened
LEFT JOIN complaints_upheld
    ON  complaints_opened.firm_name        = complaints_upheld.firm_name
    AND complaints_opened.period           = complaints_upheld.period
    AND complaints_opened.product_category = complaints_upheld.product_category
GROUP BY complaints_opened.product_category, complaints_opened.period
ORDER BY complaints_opened.product_category, complaints_opened.period;


/* ============================================================
   QUERY 5 - Consistently Most-Complained-About Firms
   Question: Which firms ranked in the top 20 for complaints
             in ALL THREE periods?
   Skills  : RANK() window function, PARTITION BY,
             nested CTEs, HAVING
   ============================================================ */
WITH firm_period_totals AS (
    SELECT
        firm_name,
        period,
        SUM(complaints_opened) AS total_complaints
    FROM complaints_opened
    GROUP BY firm_name, period
),
ranked AS (
    SELECT
        firm_name,
        period,
        total_complaints,
        RANK() OVER (
            PARTITION BY period
            ORDER BY total_complaints DESC
        ) AS rank_in_period
    FROM firm_period_totals
)
SELECT
    firm_name,
    COUNT(*)                        AS periods_in_top20,
    ROUND(AVG(total_complaints), 0) AS avg_complaints
FROM ranked
WHERE rank_in_period <= 20
GROUP BY firm_name
HAVING COUNT(*) = 3
ORDER BY avg_complaints DESC;


/* ============================================================
   QUERY 6 - Complaint Concentration Analysis (H2 2025)
   Question: What share of ALL UK financial complaints comes
             from the largest firms?
   Skills  : Cumulative SUM() OVER() window function,
             grand-total window, running percentage
   ============================================================ */
WITH firm_totals AS (
    SELECT
        firm_name,
        SUM(complaints_opened) AS total_complaints
    FROM complaints_opened
    WHERE period = 'H2 2025'
    GROUP BY firm_name
)
SELECT
    firm_name,
    total_complaints,
    SUM(total_complaints) OVER (
        ORDER BY total_complaints DESC
    ) AS cumulative_complaints,
    ROUND(
        100.0 * SUM(total_complaints) OVER (ORDER BY total_complaints DESC)
        / SUM(total_complaints) OVER (),
    1) AS cumulative_pct
FROM firm_totals
ORDER BY total_complaints DESC
LIMIT 20;


/* ============================================================
   QUERY 7 - Parent Group Analysis vs Average (H2 2025)
   Question: Which corporate GROUPS (not individual brands)
             generate the most complaints, and are they above
             or below the average group?
   Skills  : Scalar subquery, CASE conditional logic,
             grouping on parent company
   ============================================================ */
SELECT
    firm_group,
    SUM(complaints_opened) AS group_total,
    CASE
        WHEN SUM(complaints_opened) > (
            SELECT AVG(group_sum)
            FROM (
                SELECT SUM(complaints_opened) AS group_sum
                FROM complaints_opened
                WHERE period = 'H2 2025'
                GROUP BY firm_group
            ) AS sub
        )
        THEN 'Above Average'
        ELSE 'Below Average'
    END AS vs_average
FROM complaints_opened
WHERE period = 'H2 2025'
  AND firm_group <> 'NO GROUP'
GROUP BY firm_group
ORDER BY group_total DESC
LIMIT 15;


/* ============================================================
   QUERY 8 - Complaint Resolution Backlog (H2 2025)
   Question: Which firms opened more complaints than they
             closed in the period (falling behind)?
   Skills  : Two CTEs joined, calculated backlog,
             filtering on a derived value
   ============================================================ */
WITH opened AS (
    SELECT
        firm_name,
        SUM(complaints_opened) AS total_opened
    FROM complaints_opened
    WHERE period = 'H2 2025'
    GROUP BY firm_name
),
closed AS (
    SELECT
        firm_name,
        SUM(complaints_closed) AS total_closed
    FROM complaints_closed
    WHERE period = 'H2 2025'
    GROUP BY firm_name
)
SELECT
    opened.firm_name,
    opened.total_opened,
    closed.total_closed,
    (opened.total_opened - closed.total_closed) AS backlog
FROM opened
JOIN closed ON opened.firm_name = closed.firm_name
WHERE (opened.total_opened - closed.total_closed) > 0
ORDER BY backlog DESC
LIMIT 15;
