-- =============================================================================
-- TraceLedger | Layer 1 | 00_setup.sql
-- Warehouse, database, schemas, file formats and stages.
-- Run as ACCOUNTADMIN (or a role with CREATE WAREHOUSE / DATABASE).
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Use a region where Cortex AI runs natively (e.g. AWS US West - Oregon). Trial accounts
-- cannot use cross-region inference. On a paid account in another region, enable it with:
--   ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- Extra-small warehouse that suspends after 60s idle (keeps credit burn tiny).
CREATE WAREHOUSE IF NOT EXISTS TRACELEDGER_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'TraceLedger AML copilot compute';

CREATE DATABASE IF NOT EXISTS TRACELEDGER COMMENT = 'TraceLedger - AML & Fraud Investigation Copilot';

CREATE SCHEMA IF NOT EXISTS TRACELEDGER.CORE   COMMENT = 'Structured banking data: customers, accounts, transactions, KYC, loans';
CREATE SCHEMA IF NOT EXISTS TRACELEDGER.DOCS   COMMENT = 'Unstructured data: policy PDFs, analyst notes, adverse media';
CREATE SCHEMA IF NOT EXISTS TRACELEDGER.SIGNALS COMMENT = 'Layer 2: rule views, sanctions screening, network, risk scores';
CREATE SCHEMA IF NOT EXISTS TRACELEDGER.APP    COMMENT = 'Layer 3-5: semantic view, search services, cases, audit log, Streamlit';

USE WAREHOUSE TRACELEDGER_WH;
USE SCHEMA TRACELEDGER.CORE;

-- CSVs produced by data_gen/generate_data.py (header row = column names).
CREATE OR REPLACE FILE FORMAT TRACELEDGER.CORE.CSV_HEADER
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('')
  TRIM_SPACE = TRUE
  ENCODING = 'UTF8';

CREATE STAGE IF NOT EXISTS TRACELEDGER.CORE.DATA_STAGE
  FILE_FORMAT = TRACELEDGER.CORE.CSV_HEADER
  COMMENT = 'Landing zone for synthetic CSV files';

-- Policy PDFs. Server-side encryption + directory table are required by AI_PARSE_DOCUMENT.
CREATE STAGE IF NOT EXISTS TRACELEDGER.DOCS.POLICY_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'AML policy, regulatory guidance and risk notes (PDF)';
