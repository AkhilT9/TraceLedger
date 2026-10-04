-- =============================================================================
-- TraceLedger | Layer 1 | 02_load.sql
-- Load CSVs from @CORE.DATA_STAGE into the tables.
--
-- BEFORE running this, upload the files (see README "Layer 1"):
--   data/*.csv                  -> TRACELEDGER.CORE.DATA_STAGE
--   docs/policies/pdf/*.pdf     -> TRACELEDGER.DOCS.POLICY_STAGE
-- Either via Snowsight (Data > Databases > TRACELEDGER > CORE > Stages >
-- DATA_STAGE > "+ Files") or with the Snowflake CLI:
--   snow stage copy data/ @TRACELEDGER.CORE.DATA_STAGE --overwrite
--   snow stage copy docs/policies/pdf/ @TRACELEDGER.DOCS.POLICY_STAGE --overwrite
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE SCHEMA TRACELEDGER.CORE;

LIST @DATA_STAGE;   -- expect 10 csv files

COPY INTO BRANCHES       FROM @DATA_STAGE/branches.csv       MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO COUNTRY_RISK   FROM @DATA_STAGE/country_risk.csv   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO CUSTOMERS      FROM @DATA_STAGE/customers.csv      MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO ACCOUNTS       FROM @DATA_STAGE/accounts.csv       MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRANSACTIONS   FROM @DATA_STAGE/transactions.csv   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO LOANS          FROM @DATA_STAGE/loans.csv          MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO SANCTIONS_LIST FROM @DATA_STAGE/sanctions_list.csv MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO GROUND_TRUTH   FROM @DATA_STAGE/ground_truth.csv   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACELEDGER.DOCS.ANALYST_NOTES FROM @DATA_STAGE/analyst_notes.csv MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACELEDGER.DOCS.ADVERSE_MEDIA FROM @DATA_STAGE/adverse_media.csv MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Refresh the PDF directory table so AI_PARSE_DOCUMENT can see the files (Layer 3).
ALTER STAGE TRACELEDGER.DOCS.POLICY_STAGE REFRESH;
SELECT RELATIVE_PATH, SIZE FROM DIRECTORY(@TRACELEDGER.DOCS.POLICY_STAGE);   -- expect 3 PDFs
