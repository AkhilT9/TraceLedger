-- =============================================================================
-- TraceLedger | bootstrap.sql
-- One-click setup: connects Snowflake to the GitHub repo, copies the data and
-- policy files from it, and runs every layer's script in order.
-- Paste into a new SQL file in Snowsight and use Run All (takes ~8-10 minutes).
-- Needs a region where Cortex AI is available (e.g. AWS US West - Oregon) and Enterprise edition.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS TRACELEDGER_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE TRACELEDGER_WH;
CREATE DATABASE IF NOT EXISTS TRACELEDGER;

-- 1. Git integration with the public repository
CREATE OR REPLACE API INTEGRATION TRACELEDGER_GITHUB
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/AkhilT9')
  ENABLED = TRUE;

CREATE OR REPLACE GIT REPOSITORY TRACELEDGER.PUBLIC.TRACELEDGER_REPO
  API_INTEGRATION = TRACELEDGER_GITHUB
  ORIGIN = 'https://github.com/AkhilT9/TraceLedger.git';

ALTER GIT REPOSITORY TRACELEDGER.PUBLIC.TRACELEDGER_REPO FETCH;

-- 2. Layer 1: warehouse, schemas, stages, tables
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/00_setup.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/01_tables.sql;

-- 3. Copy data and policy documents from the repo into the stages
COPY FILES INTO @TRACELEDGER.CORE.DATA_STAGE
  FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/data/
  PATTERN = '.*[.]csv';
COPY FILES INTO @TRACELEDGER.DOCS.POLICY_STAGE
  FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/docs/policies/
  PATTERN = '.*[.](md|pdf)';

-- 4. Load, then Layer 2 (signals), then Layer 3 (Cortex AI)
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/02_load.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/04_signals_rules.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/05_signals_screening.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/06_signals_alerts.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/09_docs_ai_search.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/10_semantic_view.sql;
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/11_agent.sql;

-- 5. Layer 4 (app tables + Streamlit app) and Layer 5 (governance)
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/12_app_setup.sql;
CREATE OR REPLACE STREAMLIT TRACELEDGER.APP.TRACELEDGER_APP
  FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/app/
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = TRACELEDGER_WH
  TITLE = 'TraceLedger';
EXECUTE IMMEDIATE FROM @TRACELEDGER.PUBLIC.TRACELEDGER_REPO/branches/main/sql/13_governance.sql;
USE ROLE ACCOUNTADMIN;

-- 6. Check: row counts, alerts and the AI layer
SELECT 'TRANSACTIONS' AS OBJ, COUNT(*) AS N FROM TRACELEDGER.CORE.TRANSACTIONS
UNION ALL SELECT 'ALERTS', COUNT(*) FROM TRACELEDGER.SIGNALS.ALERTS
UNION ALL SELECT 'HIGH-RISK CUSTOMERS', COUNT(*) FROM TRACELEDGER.SIGNALS.RISK_SCORES WHERE RISK_BAND = 'HIGH'
UNION ALL SELECT 'POLICY CHUNKS', COUNT(*) FROM TRACELEDGER.DOCS.POLICY_CHUNKS
UNION ALL SELECT 'AI-TAGGED NOTES', COUNT(*) FROM TRACELEDGER.DOCS.ANALYST_NOTES_ENRICHED;
