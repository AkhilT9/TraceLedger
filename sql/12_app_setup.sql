-- =============================================================================
-- TraceLedger | Layer 4 | 12_app_setup.sql
-- Tables the Streamlit app writes to: cases, case history, generated reports
-- (STR drafts, closure memos, regulatory summaries) and the audit log.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA APP;

CREATE SEQUENCE IF NOT EXISTS CASE_SEQ    START = 1 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS FINDING_SEQ START = 1 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS EVENT_SEQ   START = 1 INCREMENT = 1;

CREATE TABLE IF NOT EXISTS CASES (
  CASE_ID                VARCHAR(12) PRIMARY KEY,
  CUSTOMER_ID            VARCHAR(12),
  PRIMARY_ACCOUNT_ID     VARCHAR(12),
  ALERT_IDS              VARCHAR(2000) COMMENT 'Comma-separated alert ids grouped into this case',
  RISK_SCORE_AT_OPEN     NUMBER(3),
  PRIORITY               VARCHAR(10)   COMMENT 'HIGH / MEDIUM / LOW',
  STATUS                 VARCHAR(25)   COMMENT 'OPEN / UNDER_REVIEW / ESCALATED / STR_FILED / CLOSED_FALSE_POSITIVE / CLOSED_NO_ACTION',
  ASSIGNED_TO            VARCHAR(60),
  CREATED_BY             VARCHAR(60),
  CREATED_PERSONA        VARCHAR(20),
  CREATED_AT             TIMESTAMP_NTZ,
  UPDATED_AT             TIMESTAMP_NTZ,
  DUE_DATE               DATE          COMMENT 'L1 review due in 5 working days (Policy 7.1)',
  DISPOSITION_RATIONALE  VARCHAR(4000) COMMENT 'Required to close (Policy 7.3)'
) COMMENT = 'AML investigation cases';

CREATE TABLE IF NOT EXISTS CASE_EVENTS (
  EVENT_ID     NUMBER,
  CASE_ID      VARCHAR(12),
  EVENT_TS     TIMESTAMP_NTZ,
  USER_NAME    VARCHAR(60),
  PERSONA      VARCHAR(20),
  FROM_STATUS  VARCHAR(25),
  TO_STATUS    VARCHAR(25),
  NOTE         VARCHAR(4000)
) COMMENT = 'Case workflow history and analyst notes';

CREATE TABLE IF NOT EXISTS CASE_FINDINGS (
  FINDING_ID         VARCHAR(12) PRIMARY KEY,
  CASE_ID            VARCHAR(12),
  CUSTOMER_ID        VARCHAR(12),
  REPORT_TYPE        VARCHAR(20)   COMMENT 'STR / CLOSURE_MEMO / REG_SUMMARY',
  VERSION            NUMBER(3),
  TITLE              VARCHAR(200),
  CONTENT            VARCHAR(65000),
  RECOMMENDATION     VARCHAR(60),
  CITED_TXNS         VARCHAR(4000),
  CITED_CLAUSES      VARCHAR(1000),
  UNVERIFIED_IDS     VARCHAR(1000) COMMENT 'Ids cited by the model that are not in the evidence (guardrail)',
  MODEL              VARCHAR(40),
  GENERATED_BY       VARCHAR(60),
  GENERATED_PERSONA  VARCHAR(20),
  GENERATED_AT       TIMESTAMP_NTZ,
  STATUS             VARCHAR(12)   COMMENT 'DRAFT / APPROVED / REJECTED (maker-checker)',
  REVIEWED_BY        VARCHAR(60),
  REVIEWED_PERSONA   VARCHAR(20),
  REVIEWED_AT        TIMESTAMP_NTZ,
  REVIEW_COMMENT     VARCHAR(2000)
) COMMENT = 'Audit-ready findings: STR drafts, closure memos and regulatory summaries, versioned';

CREATE TABLE IF NOT EXISTS AUDIT_LOG (
  EVENT_ID       NUMBER,
  EVENT_TS       TIMESTAMP_NTZ,
  USER_NAME      VARCHAR(60),
  ROLE_NAME      VARCHAR(60),
  PERSONA        VARCHAR(20),
  PAGE           VARCHAR(40),
  ACTION         VARCHAR(60),
  OBJECT_ID      VARCHAR(60),
  QUESTION       VARCHAR(4000),
  GENERATED_SQL  VARCHAR(16000),
  SOURCES        VARCHAR(4000),
  DETAILS        VARIANT
) COMMENT = 'Every question, generated SQL, cited source, report and decision made in the app (Policy 9.2)';

SHOW TABLES IN SCHEMA TRACELEDGER.APP;
