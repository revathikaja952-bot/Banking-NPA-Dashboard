/* =====================================================================
   Banking Loan Portfolio Project  -  Step 3B
   Script : 02_views_and_checks.sql
   Run in : SSMS, after 01_create_and_load.sql has finished.
   Run it : select all (Ctrl+A) and press F5.  Safe to re-run.
   ===================================================================== */

USE BankingDB;
GO

/* =====================================================================
   PART 1  -  RECONCILIATION CHECKS  (run these BEFORE building views)
   Every check should return 0 rows / 0 count unless noted.
   ===================================================================== */

-- R1. Loans whose customer does not exist                         (expect 0)
SELECT COUNT(*) AS loans_without_customer
FROM dbo.loans l
LEFT JOIN dbo.customers c ON c.customer_id = l.customer_id
WHERE c.customer_id IS NULL;

-- R2. Loans whose branch or product does not exist                (expect 0)
SELECT COUNT(*) AS loans_with_bad_branch_or_product
FROM dbo.loans l
LEFT JOIN dbo.branches b ON b.branch_id  = l.branch_id
LEFT JOIN dbo.products p ON p.product_id = l.product_id
WHERE b.branch_id IS NULL OR p.product_id IS NULL;

-- R3. Repayment rows whose loan does not exist                    (expect 0)
SELECT COUNT(*) AS repayments_without_loan
FROM dbo.repayments r
LEFT JOIN dbo.loans l ON l.loan_id = r.loan_id
WHERE l.loan_id IS NULL;

-- R4. Duplicate loan + month in repayments                        (expect 0)
SELECT COUNT(*) AS duplicate_loan_months
FROM (SELECT loan_id, month_end FROM dbo.repayments
      GROUP BY loan_id, month_end HAVING COUNT(*) > 1) d;

-- R5. Paid more than due                                          (expect 0)
SELECT COUNT(*) AS overpaid_rows
FROM dbo.repayments WHERE emi_paid > emi_due + 0.01;

-- R6. Outstanding balance larger than the original loan amount    (expect 0)
SELECT COUNT(*) AS balance_above_loan_amount
FROM dbo.repayments r
JOIN dbo.loans l ON l.loan_id = r.loan_id
WHERE r.outstanding_balance > l.loan_amount + 0.01;

-- R7. DPD values that are not multiples of 30                     (expect 0)
SELECT COUNT(*) AS odd_dpd_values FROM dbo.repayments WHERE dpd % 30 <> 0;

-- R8. Loans that have no repayment rows at all (informational)    (expect 0 here)
SELECT COUNT(*) AS loans_without_repayments
FROM dbo.loans l
WHERE NOT EXISTS (SELECT 1 FROM dbo.repayments r WHERE r.loan_id = l.loan_id);
GO

/* =====================================================================
   PART 2  -  MAIN FACT VIEW : vw_loan_monthly
   One row per loan per month, enriched with:
     * dpd_bucket / bucket_order  (Standard, SMA-0, SMA-1, SMA-2, NPA)
     * prev_bucket                (last month's bucket, using LAG)
     * movement                   (Deteriorated / Improved / Stable)
     * is_npa                     (1 if DPD > 90)
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_loan_monthly AS
WITH base AS (
    SELECT
        r.loan_id, r.month_end, r.emi_due, r.emi_paid, r.dpd, r.outstanding_balance,
        l.customer_id, l.branch_id, l.product_id, l.disbursal_date,
        l.loan_amount, l.interest_rate, l.tenure_months, l.status,
        CASE WHEN r.dpd = 0  THEN 'Standard'
             WHEN r.dpd <= 30 THEN 'SMA-0'
             WHEN r.dpd <= 60 THEN 'SMA-1'
             WHEN r.dpd <= 90 THEN 'SMA-2'
             ELSE 'NPA' END AS dpd_bucket,
        CASE WHEN r.dpd = 0  THEN 1
             WHEN r.dpd <= 30 THEN 2
             WHEN r.dpd <= 60 THEN 3
             WHEN r.dpd <= 90 THEN 4
             ELSE 5 END AS bucket_order
    FROM dbo.repayments r
    JOIN dbo.loans l ON l.loan_id = r.loan_id
),
lagged AS (
    SELECT b.*,
           LAG(b.dpd_bucket)   OVER (PARTITION BY b.loan_id ORDER BY b.month_end) AS prev_bucket,
           LAG(b.bucket_order) OVER (PARTITION BY b.loan_id ORDER BY b.month_end) AS prev_bucket_order
    FROM base b
)
SELECT
    lg.*,
    CASE WHEN lg.prev_bucket_order IS NULL             THEN 'First record'
         WHEN lg.bucket_order > lg.prev_bucket_order   THEN 'Deteriorated'
         WHEN lg.bucket_order < lg.prev_bucket_order   THEN 'Improved'
         ELSE 'Stable' END AS movement,
    CASE WHEN lg.bucket_order = 5 THEN 1 ELSE 0 END AS is_npa
FROM lagged lg;
GO

/* =====================================================================
   PART 3  -  MONTHLY PORTFOLIO SUMMARY : vw_portfolio_monthly
   Feeds the executive page: outstanding, GNPA %, collection efficiency
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_portfolio_monthly AS
SELECT
    month_end,
    SUM(CASE WHEN outstanding_balance > 0 THEN 1 ELSE 0 END)            AS active_accounts,
    SUM(outstanding_balance)                                            AS total_outstanding,
    SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END)       AS gnpa_amount,
    CAST(100.0 * SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END)
         / NULLIF(SUM(outstanding_balance), 0) AS DECIMAL(6,2))         AS gnpa_pct,
    SUM(emi_due)                                                        AS emi_due,
    SUM(emi_paid)                                                       AS emi_paid,
    CAST(100.0 * SUM(emi_paid) / NULLIF(SUM(emi_due), 0) AS DECIMAL(6,2)) AS collection_efficiency_pct
FROM dbo.vw_loan_monthly
GROUP BY month_end;
GO

/* =====================================================================
   PART 4  -  BUCKET MIGRATION : vw_bucket_migration
   How many accounts moved from bucket A (last month) to bucket B (this month)
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_bucket_migration AS
SELECT
    month_end,
    prev_bucket   AS from_bucket,
    dpd_bucket    AS to_bucket,
    COUNT(*)      AS accounts,
    SUM(outstanding_balance) AS outstanding
FROM dbo.vw_loan_monthly
WHERE prev_bucket IS NOT NULL
GROUP BY month_end, prev_bucket, dpd_bucket;
GO

/* =====================================================================
   PART 5  -  BRANCH RANKING (latest month) : vw_branch_npa_ranking
   RANK() over all branches, and RANK() inside each region
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_branch_npa_ranking AS
WITH latest AS (
    SELECT * FROM dbo.vw_loan_monthly
    WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments)
),
agg AS (
    SELECT
        b.branch_id, b.branch_name, b.city, b.region,
        COUNT(*)                                                     AS accounts,
        SUM(l.outstanding_balance)                                   AS outstanding,
        SUM(CASE WHEN l.is_npa = 1 THEN l.outstanding_balance ELSE 0 END) AS npa_amount
    FROM latest l
    JOIN dbo.branches b ON b.branch_id = l.branch_id
    GROUP BY b.branch_id, b.branch_name, b.city, b.region
)
SELECT
    a.*,
    CAST(100.0 * a.npa_amount / NULLIF(a.outstanding, 0) AS DECIMAL(6,2)) AS npa_pct,
    RANK() OVER (ORDER BY a.npa_amount * 1.0 / NULLIF(a.outstanding, 0) DESC)                         AS overall_rank,
    RANK() OVER (PARTITION BY a.region ORDER BY a.npa_amount * 1.0 / NULLIF(a.outstanding, 0) DESC)   AS rank_in_region
FROM agg a;
GO

/* =====================================================================
   PART 6  -  COHORT VIEW (by disbursal month) : vw_cohort_disbursal
   Are recently disbursed loans riskier than older ones?
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_cohort_disbursal AS
WITH latest AS (
    SELECT * FROM dbo.vw_loan_monthly
    WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments)
)
SELECT
    DATEFROMPARTS(YEAR(disbursal_date), MONTH(disbursal_date), 1) AS cohort_month,
    COUNT(*)                                                      AS loans,
    SUM(loan_amount)                                              AS amount_disbursed,
    SUM(outstanding_balance)                                      AS outstanding,
    SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END) AS npa_amount,
    CAST(100.0 * SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END)
         / NULLIF(SUM(outstanding_balance), 0) AS DECIMAL(6,2))   AS npa_pct
FROM latest
GROUP BY DATEFROMPARTS(YEAR(disbursal_date), MONTH(disbursal_date), 1);
GO

/* =====================================================================
   PART 7  -  CUSTOMER RISK VIEW (latest month) : vw_customer_risk_latest
   One row per loan with age group, income band and credit-score band.
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_customer_risk_latest AS
SELECT
    m.loan_id, m.customer_id, m.dpd_bucket, m.is_npa, m.outstanding_balance,
    p.product_type, b.region, b.state, b.city,
    CASE WHEN c.age < 30 THEN '21-29'
         WHEN c.age < 40 THEN '30-39'
         WHEN c.age < 50 THEN '40-49'
         WHEN c.age < 60 THEN '50-59'
         ELSE '60+' END AS age_group,
    CASE WHEN c.annual_income < 600000  THEN 'Low (<6L)'
         WHEN c.annual_income < 1500000 THEN 'Middle (6-15L)'
         ELSE 'High (15L+)' END AS income_band,
    CASE WHEN c.credit_score IS NULL THEN 'Unknown'
         WHEN c.credit_score < 650   THEN 'Poor (<650)'
         WHEN c.credit_score < 750   THEN 'Fair (650-749)'
         ELSE 'Good (750+)' END AS credit_band
FROM dbo.vw_loan_monthly m
JOIN dbo.customers c ON c.customer_id = m.customer_id
JOIN dbo.branches  b ON b.branch_id   = m.branch_id
JOIN dbo.products  p ON p.product_id  = m.product_id
WHERE m.month_end = (SELECT MAX(month_end) FROM dbo.repayments);
GO

/* =====================================================================
   PART 8  -  TEST THE VIEWS  (run each SELECT on its own to see results)
   ===================================================================== */

-- T1. Monthly trend: GNPA % and collection efficiency
SELECT * FROM dbo.vw_portfolio_monthly ORDER BY month_end;

-- T2. Bucket distribution in the latest month
SELECT dpd_bucket, bucket_order, COUNT(*) AS accounts, SUM(outstanding_balance) AS outstanding
FROM dbo.vw_loan_monthly
WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments)
GROUP BY dpd_bucket, bucket_order
ORDER BY bucket_order;

-- T3. Movement summary in the latest month
SELECT movement, COUNT(*) AS accounts
FROM dbo.vw_loan_monthly
WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments)
GROUP BY movement;

-- T4. Top 10 riskiest branches
SELECT TOP 10 overall_rank, branch_name, region, accounts, outstanding, npa_pct
FROM dbo.vw_branch_npa_ranking
ORDER BY overall_rank;

-- T5. NPA % by product
SELECT product_type,
       CAST(100.0 * SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END)
            / SUM(outstanding_balance) AS DECIMAL(6,2)) AS npa_pct
FROM dbo.vw_customer_risk_latest
GROUP BY product_type
ORDER BY npa_pct DESC;

-- T6. NPA % by region, for Personal Loans only (finds the hotspot)
SELECT region,
       CAST(100.0 * SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END)
            / SUM(outstanding_balance) AS DECIMAL(6,2)) AS npa_pct
FROM dbo.vw_customer_risk_latest
WHERE product_type = 'Personal Loan'
GROUP BY region
ORDER BY npa_pct DESC;

-- T7. NPA % by credit-score band
SELECT credit_band,
       CAST(100.0 * SUM(CASE WHEN is_npa = 1 THEN outstanding_balance ELSE 0 END)
            / SUM(outstanding_balance) AS DECIMAL(6,2)) AS npa_pct
FROM dbo.vw_customer_risk_latest
GROUP BY credit_band
ORDER BY npa_pct DESC;

-- T8. Bucket migration matrix for the latest month
SELECT from_bucket, to_bucket, accounts
FROM dbo.vw_bucket_migration
WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments)
ORDER BY from_bucket, to_bucket;

-- T9. SOURCE-TO-TARGET RECONCILIATION: the view must match the raw table
--     (difference should be 0.00)
SELECT
    (SELECT SUM(outstanding_balance) FROM dbo.repayments
      WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments))          AS source_total,
    (SELECT total_outstanding FROM dbo.vw_portfolio_monthly
      WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments))          AS view_total,
    (SELECT SUM(outstanding_balance) FROM dbo.repayments
      WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments))
  - (SELECT total_outstanding FROM dbo.vw_portfolio_monthly
      WHERE month_end = (SELECT MAX(month_end) FROM dbo.repayments))          AS difference;
GO
