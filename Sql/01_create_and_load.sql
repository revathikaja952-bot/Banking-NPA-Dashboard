/* =====================================================================
   Banking Loan Portfolio Project  -  Step 3A
   Script : 01_create_and_load.sql
   Tool   : SQL Server Management Studio (SSMS)

   BEFORE YOU RUN:
   1. Put the 6 CSV files in  C:\BankingProject\data\
   2. If your folder is different, use Find & Replace (Ctrl+H) in SSMS and
      replace  C:\BankingProject\data\  with your folder path.
   3. Press F5 to run the whole script.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 1. CREATE DATABASE
-- ---------------------------------------------------------------------
IF DB_ID('BankingDB') IS NULL
    CREATE DATABASE BankingDB;
GO

USE BankingDB;
GO

-- ---------------------------------------------------------------------
-- 2. DROP OLD TABLES (so the script can be re-run safely)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.repayments;
DROP TABLE IF EXISTS dbo.loans;
DROP TABLE IF EXISTS dbo.customers;
DROP TABLE IF EXISTS dbo.stg_customers;
DROP TABLE IF EXISTS dbo.products;
DROP TABLE IF EXISTS dbo.branches;
DROP TABLE IF EXISTS dbo.date_table;
GO

-- ---------------------------------------------------------------------
-- 3. CREATE TABLES
-- ---------------------------------------------------------------------
CREATE TABLE dbo.branches (
    branch_id    VARCHAR(10)  NOT NULL PRIMARY KEY,
    branch_name  VARCHAR(100) NOT NULL,
    city         VARCHAR(50)  NOT NULL,
    state        VARCHAR(50)  NOT NULL,
    region       VARCHAR(20)  NOT NULL
);

CREATE TABLE dbo.products (
    product_id    VARCHAR(10) NOT NULL PRIMARY KEY,
    product_type  VARCHAR(50) NOT NULL
);

-- Staging table: everything is text, because the raw customer file is dirty
-- (blank credit scores, duplicate rows, messy city names).
CREATE TABLE dbo.stg_customers (
    customer_id    VARCHAR(20),
    age            VARCHAR(20),
    annual_income  VARCHAR(30),
    city           VARCHAR(60),
    credit_score   VARCHAR(20),
    segment        VARCHAR(20)
);

-- Clean table: proper data types, one row per customer.
CREATE TABLE dbo.customers (
    customer_id    VARCHAR(20)   NOT NULL PRIMARY KEY,
    age            INT           NULL,
    annual_income  DECIMAL(12,2) NULL,
    city           VARCHAR(50)   NULL,
    credit_score   INT           NULL,
    segment        VARCHAR(20)   NULL
);

CREATE TABLE dbo.loans (
    loan_id        VARCHAR(12)   NOT NULL PRIMARY KEY,
    customer_id    VARCHAR(20)   NOT NULL,
    branch_id      VARCHAR(10)   NOT NULL,
    product_id     VARCHAR(10)   NOT NULL,
    disbursal_date DATE          NOT NULL,
    loan_amount    DECIMAL(14,2) NOT NULL,
    interest_rate  DECIMAL(5,2)  NOT NULL,
    tenure_months  INT           NOT NULL,
    emi            DECIMAL(12,2) NOT NULL,
    status         VARCHAR(10)   NOT NULL
);

CREATE TABLE dbo.repayments (
    loan_id             VARCHAR(12)   NOT NULL,
    month_end           DATE          NOT NULL,
    emi_due             DECIMAL(12,2) NOT NULL,
    emi_paid            DECIMAL(12,2) NOT NULL,
    dpd                 INT           NOT NULL,
    outstanding_balance DECIMAL(14,2) NOT NULL
);

CREATE TABLE dbo.date_table (
    [date]      DATE        NOT NULL PRIMARY KEY,
    [year]      INT         NOT NULL,
    [quarter]   VARCHAR(5)  NOT NULL,
    month_num   INT         NOT NULL,
    month_name  VARCHAR(5)  NOT NULL,
    year_month  VARCHAR(10) NOT NULL,
    month_end   DATE        NOT NULL
);
GO

-- ---------------------------------------------------------------------
-- 4. LOAD THE CSV FILES  (edit the path if your folder is different)
-- ---------------------------------------------------------------------
BULK INSERT dbo.branches
FROM 'C:\BankingProject\data\branches.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT dbo.products
FROM 'C:\BankingProject\data\products.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT dbo.stg_customers
FROM 'C:\BankingProject\data\customers.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT dbo.loans
FROM 'C:\BankingProject\data\loans.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT dbo.repayments
FROM 'C:\BankingProject\data\repayments.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

BULK INSERT dbo.date_table
FROM 'C:\BankingProject\data\date_table.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);
GO

-- ---------------------------------------------------------------------
-- 5. CLEAN CUSTOMERS  (staging -> clean table)
--    * removes duplicate customers
--    * fixes messy city names (HYDERABAD  ->  Hyderabad) using the branches table
--    * converts blank / "657.0" credit scores into proper integers or NULL
-- ---------------------------------------------------------------------
;WITH cleaned AS (
    SELECT
        customer_id,
        TRY_CAST(age AS INT)                                              AS age,
        TRY_CAST(annual_income AS DECIMAL(12,2))                          AS annual_income,
        LTRIM(RTRIM(city))                                                AS city_raw,
        TRY_CAST(TRY_CAST(NULLIF(LTRIM(RTRIM(credit_score)), '')
                          AS DECIMAL(6,1)) AS INT)                        AS credit_score,
        segment,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY (SELECT NULL)) AS rn
    FROM dbo.stg_customers
)
INSERT INTO dbo.customers (customer_id, age, annual_income, city, credit_score, segment)
SELECT  c.customer_id,
        c.age,
        c.annual_income,
        COALESCE(b.city, c.city_raw),
        c.credit_score,
        LTRIM(RTRIM(c.segment))
FROM cleaned c
OUTER APPLY (SELECT TOP 1 city FROM dbo.branches
             WHERE UPPER(city) = UPPER(c.city_raw)) b
WHERE c.rn = 1;
GO

-- ---------------------------------------------------------------------
-- 6. VERIFY ROW COUNTS   (expected values in the last column)
-- ---------------------------------------------------------------------
SELECT 'branches'      AS table_name, COUNT(*) AS rows_loaded, 42     AS expected FROM dbo.branches
UNION ALL SELECT 'products',      COUNT(*), 4       FROM dbo.products
UNION ALL SELECT 'stg_customers', COUNT(*), 8040    FROM dbo.stg_customers
UNION ALL SELECT 'customers',     COUNT(*), 8000    FROM dbo.customers
UNION ALL SELECT 'loans',         COUNT(*), 9994    FROM dbo.loans
UNION ALL SELECT 'repayments',    COUNT(*), 175375  FROM dbo.repayments
UNION ALL SELECT 'date_table',    COUNT(*), 1461    FROM dbo.date_table;

-- Customers with missing credit score (expected: about 80)
SELECT COUNT(*) AS customers_with_null_score FROM dbo.customers WHERE credit_score IS NULL;

-- City names should now match the branches list exactly (expected: 0 rows)
SELECT DISTINCT c.city FROM dbo.customers c
WHERE c.city NOT IN (SELECT city FROM dbo.branches);
GO
