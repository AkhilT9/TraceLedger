-- =============================================================================
-- TraceLedger | Layer 1 | 01_tables.sql
-- Core tables. Column comments double as business descriptions for the
-- Semantic View / Cortex Analyst in Layer 3.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE SCHEMA TRACELEDGER.CORE;

CREATE OR REPLACE TABLE BRANCHES (
  BRANCH_ID       VARCHAR(10)  PRIMARY KEY COMMENT 'Branch identifier, e.g. BR-002',
  BRANCH_NAME     VARCHAR(100) COMMENT 'Branch name',
  CITY            VARCHAR(50),
  STATE           VARCHAR(50),
  REGION          VARCHAR(10)  COMMENT 'NORTH / SOUTH / EAST / WEST - used for row access policy',
  HIGH_RISK_AREA  BOOLEAN      COMMENT 'Branch located in a cash-intensive / high-risk market area'
) COMMENT = 'Bank branches';

CREATE OR REPLACE TABLE COUNTRY_RISK (
  COUNTRY_CODE  VARCHAR(2) PRIMARY KEY COMMENT 'ISO-2 country code',
  COUNTRY_NAME  VARCHAR(60),
  RISK_LEVEL    VARCHAR(10) COMMENT 'LOW / MEDIUM / HIGH',
  FATF_STATUS   VARCHAR(30) COMMENT 'MEMBER / INCREASED_MONITORING / CALL_FOR_ACTION / TAX_HAVEN'
) COMMENT = 'Country risk register used by the high-risk geography rule (Policy 4.5)';

CREATE OR REPLACE TABLE CUSTOMERS (
  CUSTOMER_ID             VARCHAR(12) PRIMARY KEY COMMENT 'Customer identifier, e.g. CUST-0001',
  FULL_NAME               VARCHAR(120) COMMENT 'Customer or entity name (PII - masked for analysts)',
  CUSTOMER_TYPE           VARCHAR(12)  COMMENT 'INDIVIDUAL or ENTITY',
  DATE_OF_BIRTH           DATE         COMMENT 'Date of birth, or incorporation date for entities',
  GENDER                  VARCHAR(1),
  NATIONALITY             VARCHAR(2),
  COUNTRY_OF_RESIDENCE    VARCHAR(2),
  CITY                    VARCHAR(50),
  STATE                   VARCHAR(50),
  REGION                  VARCHAR(10),
  HOME_BRANCH_ID          VARCHAR(10)  REFERENCES BRANCHES(BRANCH_ID),
  OCCUPATION              VARCHAR(60)  COMMENT 'Occupation (individuals) or business line (entities)',
  DECLARED_ANNUAL_INCOME  NUMBER(16,2) COMMENT 'Declared annual income or turnover in INR (Policy 3.5)',
  KYC_RISK_TIER           VARCHAR(10)  COMMENT 'LOW / MEDIUM / HIGH',
  PEP_FLAG                BOOLEAN      COMMENT 'Politically Exposed Person',
  PAN_NUMBER              VARCHAR(10)  COMMENT 'Indian tax id (PII - masked)',
  PHONE                   VARCHAR(20)  COMMENT 'PII - masked',
  EMAIL                   VARCHAR(120) COMMENT 'PII - masked',
  ONBOARDING_DATE         DATE,
  KYC_LAST_REVIEWED       DATE
) COMMENT = 'Customer master with KYC attributes';

CREATE OR REPLACE TABLE ACCOUNTS (
  ACCOUNT_ID       VARCHAR(12) PRIMARY KEY COMMENT 'Account identifier, e.g. ACC-1042',
  CUSTOMER_ID      VARCHAR(12) REFERENCES CUSTOMERS(CUSTOMER_ID),
  ACCOUNT_TYPE     VARCHAR(12) COMMENT 'SAVINGS / CURRENT',
  BRANCH_ID        VARCHAR(10) REFERENCES BRANCHES(BRANCH_ID),
  OPEN_DATE        DATE,
  STATUS           VARCHAR(10) COMMENT 'ACTIVE / DORMANT / CLOSED',
  CURRENCY         VARCHAR(3),
  CURRENT_BALANCE  NUMBER(16,2) COMMENT 'Balance in INR as of 2026-09-30'
) COMMENT = 'Deposit accounts';

CREATE OR REPLACE TABLE TRANSACTIONS (
  TXN_ID                   VARCHAR(12) PRIMARY KEY COMMENT 'Transaction id, e.g. TXN-0061185',
  ACCOUNT_ID               VARCHAR(12) REFERENCES ACCOUNTS(ACCOUNT_ID),
  TXN_TS                   TIMESTAMP_NTZ COMMENT 'Transaction timestamp (IST)',
  DIRECTION                VARCHAR(6)  COMMENT 'CREDIT (money in) or DEBIT (money out)',
  AMOUNT                   NUMBER(16,2) COMMENT 'Amount in INR (always positive)',
  CURRENCY                 VARCHAR(3),
  CHANNEL                  VARCHAR(6)  COMMENT 'CASH / UPI / IMPS / NEFT / RTGS / SWIFT / CARD',
  COUNTERPARTY_ACCOUNT_ID  VARCHAR(12) COMMENT 'Internal counterparty account (null if external)',
  COUNTERPARTY_NAME        VARCHAR(120),
  COUNTERPARTY_BANK        VARCHAR(80),
  COUNTERPARTY_COUNTRY     VARCHAR(2)  COMMENT 'ISO-2 country of the counterparty',
  DESCRIPTION              VARCHAR(200)
) COMMENT = 'All account transactions, Oct-2025 to Sep-2026'
  CLUSTER BY (ACCOUNT_ID);

CREATE OR REPLACE TABLE LOANS (
  LOAN_ID               VARCHAR(10) PRIMARY KEY,
  CUSTOMER_ID           VARCHAR(12) REFERENCES CUSTOMERS(CUSTOMER_ID),
  ACCOUNT_ID            VARCHAR(12) REFERENCES ACCOUNTS(ACCOUNT_ID) COMMENT 'Repayment account',
  PRODUCT               VARCHAR(20) COMMENT 'HOME_LOAN / PERSONAL_LOAN / AUTO_LOAN / BUSINESS_LOAN / GOLD_LOAN / NBFC_MSME_LOAN',
  SANCTIONED_AMOUNT     NUMBER(16,2),
  OUTSTANDING_AMOUNT    NUMBER(16,2) COMMENT 'Exposure at default (EAD)',
  INTEREST_RATE         NUMBER(5,2),
  DISBURSAL_DATE        DATE,
  TENURE_MONTHS         NUMBER(4),
  DPD                   NUMBER(5)   COMMENT 'Days past due',
  ASSET_CLASSIFICATION  VARCHAR(10) COMMENT 'STANDARD / SMA-0 / SMA-1 / SMA-2 / NPA',
  COLLATERAL_TYPE       VARCHAR(25),
  COLLATERAL_VALUE      NUMBER(16,2),
  STATUS                VARCHAR(10)
) COMMENT = 'Loan book for the credit-risk angle';

CREATE OR REPLACE TABLE SANCTIONS_LIST (
  SANCTION_ID    VARCHAR(10) PRIMARY KEY,
  LISTED_NAME    VARCHAR(120),
  ALIASES        VARCHAR(200) COMMENT 'Semicolon-separated aliases',
  ENTITY_TYPE    VARCHAR(12)  COMMENT 'INDIVIDUAL / ENTITY',
  COUNTRY        VARCHAR(2),
  PROGRAM        VARCHAR(30),
  DATE_OF_BIRTH  DATE,
  LIST_SOURCE    VARCHAR(12)  COMMENT 'Synthetic OFAC / UN / EU style list',
  LISTED_DATE    DATE
) COMMENT = 'Synthetic sanctions watchlist (Policy section 5)';

CREATE OR REPLACE TABLE TRACELEDGER.DOCS.ANALYST_NOTES (
  NOTE_ID      VARCHAR(12) PRIMARY KEY,
  CUSTOMER_ID  VARCHAR(12),
  NOTE_DATE    DATE,
  AUTHOR       VARCHAR(40),
  NOTE_TYPE    VARCHAR(15) COMMENT 'CALL / BRANCH_VISIT / KYC_REVIEW',
  NOTE_TEXT    VARCHAR(2000)
) COMMENT = 'Analyst and call notes per customer';

CREATE OR REPLACE TABLE TRACELEDGER.DOCS.ADVERSE_MEDIA (
  ARTICLE_ID      VARCHAR(10) PRIMARY KEY,
  PUBLISHED_DATE  DATE,
  SOURCE          VARCHAR(60),
  HEADLINE        VARCHAR(300),
  BODY            VARCHAR(4000),
  MENTIONED_NAME  VARCHAR(120),
  SENTIMENT_HINT  VARCHAR(10)
) COMMENT = 'Synthetic news snippets for adverse media screening';

-- Answer key for the evaluation set (Layer 6). Not exposed to the app/agent.
CREATE OR REPLACE TABLE GROUND_TRUTH (
  CUSTOMER_ID       VARCHAR(12),
  ACCOUNT_ID        VARCHAR(12),
  INJECTED_PATTERN  VARCHAR(30),
  DETAIL            VARCHAR(300)
) COMMENT = 'Injected fraud typologies - evaluation only';
