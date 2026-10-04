-- =============================================================================
-- TraceLedger | Layer 3 | 10_semantic_view.sql
-- Semantic View for Cortex Analyst: business names, synonyms, joins and
-- canonical metrics over customers, accounts, transactions, alerts, scores
-- and loans. Analysts ask in plain English; Cortex Analyst writes the SQL.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;

-- Flat views so every column the copilot needs is a simple scalar.
CREATE OR REPLACE VIEW SIGNALS.V_ALERTS_FLAT AS
SELECT ALERT_ID, RULE_ID, RULE_NAME, TYPOLOGY, CUSTOMER_ID, ACCOUNT_ID, BRANCH_ID, REGION,
       WINDOW_START, WINDOW_END, ALERT_DATE, AMOUNT_INR, TXN_COUNT, WEIGHT,
       POLICY_DOC, POLICY_CLAUSE, POLICY_REF, REASON,
       ARRAY_TO_STRING(EVIDENCE_TXN_IDS, ', ') AS EVIDENCE_TXN_LIST
FROM SIGNALS.ALERTS;

-- One row per (alert, evidence transaction) with the transaction details.
CREATE OR REPLACE VIEW SIGNALS.V_ALERT_EVIDENCE AS
WITH e AS (
  SELECT a.ALERT_ID, a.RULE_ID, a.ACCOUNT_ID, a.CUSTOMER_ID, f.VALUE::STRING AS TXN_ID
  FROM SIGNALS.ALERTS a, LATERAL FLATTEN(input => a.EVIDENCE_TXN_IDS) f
)
SELECT e.ALERT_ID, e.RULE_ID, e.ACCOUNT_ID, e.CUSTOMER_ID, e.TXN_ID,
       t.TXN_TS, t.DIRECTION, t.AMOUNT, t.CHANNEL, t.COUNTERPARTY_NAME, t.COUNTERPARTY_BANK,
       t.COUNTERPARTY_COUNTRY, t.DESCRIPTION
FROM e
JOIN CORE.TRANSACTIONS t ON t.TXN_ID = e.TXN_ID;

CREATE OR REPLACE SEMANTIC VIEW APP.TRACELEDGER_SV
  TABLES (
    customers AS TRACELEDGER.CORE.CUSTOMERS
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS = ('clients', 'account holders', 'KYC')
      COMMENT = 'Customer master with KYC attributes, declared income and PEP flag',
    accounts AS TRACELEDGER.CORE.ACCOUNTS
      PRIMARY KEY (ACCOUNT_ID)
      WITH SYNONYMS = ('bank accounts', 'deposit accounts')
      COMMENT = 'Savings and current accounts',
    branches AS TRACELEDGER.CORE.BRANCHES
      PRIMARY KEY (BRANCH_ID)
      COMMENT = 'Bank branches and regions',
    transactions AS TRACELEDGER.CORE.TRANSACTIONS
      PRIMARY KEY (TXN_ID)
      WITH SYNONYMS = ('txns', 'payments', 'deposits', 'transfers', 'wires')
      COMMENT = 'All account transactions (INR) from Oct-2025 to Sep-2026',
    countries AS TRACELEDGER.CORE.COUNTRY_RISK
      PRIMARY KEY (COUNTRY_CODE)
      COMMENT = 'Country risk register (FATF status, tax havens)',
    alerts AS TRACELEDGER.SIGNALS.V_ALERTS_FLAT
      PRIMARY KEY (ALERT_ID)
      WITH SYNONYMS = ('flags', 'red flags', 'AML alerts', 'rule hits')
      COMMENT = 'Explainable AML alerts: one per rule per account, with reason, evidence and policy clause',
    alert_evidence AS TRACELEDGER.SIGNALS.V_ALERT_EVIDENCE
      PRIMARY KEY (ALERT_ID, TXN_ID)
      WITH SYNONYMS = ('evidence', 'flagged transactions', 'transactions behind the alert')
      COMMENT = 'The transactions that caused each alert',
    rules AS TRACELEDGER.SIGNALS.RULE_CATALOG
      PRIMARY KEY (RULE_ID)
      COMMENT = 'Detection rules mapped to AML policy clauses and score weights',
    risk_scores AS TRACELEDGER.SIGNALS.RISK_SCORES
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS = ('risk score', 'risk rating')
      COMMENT = 'Explainable customer risk score 0-100 with band and breakdown',
    loans AS TRACELEDGER.CORE.LOANS
      PRIMARY KEY (LOAN_ID)
      WITH SYNONYMS = ('credit exposure', 'advances', 'borrowings')
      COMMENT = 'Loan book with days past due and asset classification'
  )
  RELATIONSHIPS (
    accounts_to_customers      AS accounts (CUSTOMER_ID)            REFERENCES customers,
    accounts_to_branches       AS accounts (BRANCH_ID)              REFERENCES branches,
    transactions_to_accounts   AS transactions (ACCOUNT_ID)         REFERENCES accounts,
    transactions_to_countries  AS transactions (COUNTERPARTY_COUNTRY) REFERENCES countries,
    alerts_to_accounts         AS alerts (ACCOUNT_ID)               REFERENCES accounts,
    alerts_to_rules            AS alerts (RULE_ID)                  REFERENCES rules,
    evidence_to_alerts         AS alert_evidence (ALERT_ID)         REFERENCES alerts,
    scores_to_customers        AS risk_scores (CUSTOMER_ID)         REFERENCES customers,
    loans_to_customers         AS loans (CUSTOMER_ID)               REFERENCES customers
  )
  FACTS (
    transactions.txn_amount AS AMOUNT
      COMMENT = 'Transaction amount in INR (always positive; see direction)',
    alert_evidence.evidence_amount AS AMOUNT
      COMMENT = 'Amount of an evidence transaction in INR',
    alerts.alert_amount AS AMOUNT_INR
      COMMENT = 'Total INR amount involved in the alert',
    alerts.alert_weight AS WEIGHT
      COMMENT = 'Points this alert adds to the customer risk score',
    loans.outstanding AS OUTSTANDING_AMOUNT
      COMMENT = 'Outstanding loan amount (exposure at default) in INR',
    loans.collateral AS COLLATERAL_VALUE
      COMMENT = 'Collateral value in INR',
    accounts.balance AS CURRENT_BALANCE
      COMMENT = 'Current account balance in INR'
  )
  DIMENSIONS (
    -- customers
    customers.customer_id AS CUSTOMER_ID COMMENT = 'Customer identifier, e.g. CUST-0001',
    customers.customer_name AS FULL_NAME
      WITH SYNONYMS = ('name', 'customer name', 'account holder name')
      COMMENT = 'Customer or company name',
    customers.customer_type AS CUSTOMER_TYPE COMMENT = 'INDIVIDUAL or ENTITY',
    customers.occupation AS OCCUPATION
      WITH SYNONYMS = ('profession', 'business line')
      COMMENT = 'Occupation or line of business',
    customers.declared_income AS DECLARED_ANNUAL_INCOME
      WITH SYNONYMS = ('income', 'annual income', 'turnover')
      COMMENT = 'Declared annual income or turnover in INR',
    customers.kyc_risk_tier AS KYC_RISK_TIER COMMENT = 'KYC risk tier: LOW, MEDIUM or HIGH',
    customers.is_pep AS PEP_FLAG
      WITH SYNONYMS = ('PEP', 'politically exposed person')
      COMMENT = 'TRUE if the customer is a politically exposed person',
    customers.nationality AS NATIONALITY COMMENT = 'ISO-2 nationality',
    customers.customer_region AS REGION COMMENT = 'Customer home region: NORTH, SOUTH, EAST, WEST',
    customers.customer_city AS CITY COMMENT = 'Customer city',
    customers.onboarding_date AS ONBOARDING_DATE COMMENT = 'Date the customer was onboarded',
    -- accounts / branches
    accounts.account_id AS ACCOUNT_ID COMMENT = 'Account identifier, e.g. ACC-1042',
    accounts.account_type AS ACCOUNT_TYPE COMMENT = 'SAVINGS or CURRENT',
    accounts.account_status AS STATUS COMMENT = 'ACTIVE, DORMANT or CLOSED',
    accounts.open_date AS OPEN_DATE COMMENT = 'Account opening date',
    branches.branch_name AS BRANCH_NAME COMMENT = 'Branch name',
    branches.branch_city AS CITY COMMENT = 'Branch city',
    branches.branch_region AS REGION COMMENT = 'Branch region: NORTH, SOUTH, EAST, WEST',
    branches.is_high_risk_branch AS HIGH_RISK_AREA
      WITH SYNONYMS = ('high-risk branch', 'cash-intensive market')
      COMMENT = 'TRUE if the branch is in a high-risk, cash-intensive market area',
    -- transactions
    transactions.transaction_id AS TXN_ID COMMENT = 'Transaction id, e.g. TXN-0059129',
    transactions.txn_timestamp AS TXN_TS COMMENT = 'Transaction date and time',
    transactions.txn_date AS TXN_TS::DATE
      WITH SYNONYMS = ('date', 'transaction date')
      COMMENT = 'Transaction date',
    transactions.txn_month AS DATE_TRUNC('month', TXN_TS)::DATE COMMENT = 'Transaction month',
    transactions.txn_direction AS DIRECTION
      COMMENT = 'CREDIT = money in (deposit / receipt), DEBIT = money out (withdrawal / payment)',
    transactions.txn_channel AS CHANNEL
      WITH SYNONYMS = ('payment mode', 'mode')
      COMMENT = 'CASH, UPI, IMPS, NEFT, RTGS, SWIFT or CARD',
    transactions.counterparty_name AS COUNTERPARTY_NAME
      WITH SYNONYMS = ('beneficiary', 'remitter', 'payee', 'payer')
      COMMENT = 'Other party of the transaction',
    transactions.counterparty_account AS COUNTERPARTY_ACCOUNT_ID COMMENT = 'Internal counterparty account, if any',
    transactions.counterparty_country AS COUNTERPARTY_COUNTRY COMMENT = 'ISO-2 country of the counterparty',
    transactions.description AS DESCRIPTION COMMENT = 'Transaction narration',
    countries.country_name AS COUNTRY_NAME COMMENT = 'Counterparty country name',
    countries.country_risk_level AS RISK_LEVEL COMMENT = 'Country risk: LOW, MEDIUM, HIGH',
    countries.fatf_status AS FATF_STATUS
      COMMENT = 'MEMBER, INCREASED_MONITORING (grey list), CALL_FOR_ACTION (black list) or TAX_HAVEN',
    -- alerts
    alerts.alert_identifier AS ALERT_ID COMMENT = 'Alert id, e.g. AL-TM-STR-ACC-1042',
    alerts.rule_id AS RULE_ID
      COMMENT = 'Rule code: TM-STR structuring, TM-VEL velocity, TM-DOR dormant, TM-GEO high-risk geography, TM-INC income mismatch, TM-RND round amounts, TM-RIO pass-through, TM-NET mule network, SCR-SAN sanctions, SCR-PEP PEP, ADV-MED adverse media',
    alerts.rule_name AS RULE_NAME
      WITH SYNONYMS = ('typology name', 'red flag type')
      COMMENT = 'Human-readable rule name',
    alerts.typology AS TYPOLOGY COMMENT = 'PLACEMENT, LAYERING, MULE, NETWORK, SANCTIONS, CORRUPTION, REPUTATION',
    alerts.alert_date AS ALERT_DATE COMMENT = 'Date of the latest activity behind the alert',
    alerts.alert_region AS REGION COMMENT = 'Region of the flagged account branch',
    alerts.policy_reference AS POLICY_REF
      WITH SYNONYMS = ('policy clause', 'policy section')
      COMMENT = 'AML policy clause the alert maps to, e.g. TL-AML-POL-001 section 4.2',
    alerts.reason AS REASON
      WITH SYNONYMS = ('why flagged', 'explanation')
      COMMENT = 'Plain-English explanation of why the rule fired',
    alerts.evidence_txn_list AS EVIDENCE_TXN_LIST COMMENT = 'Comma-separated evidence transaction ids',
    -- evidence
    alert_evidence.evidence_txn_id AS TXN_ID COMMENT = 'Evidence transaction id',
    alert_evidence.evidence_rule_id AS RULE_ID COMMENT = 'Rule that the evidence supports',
    alert_evidence.evidence_account_id AS ACCOUNT_ID COMMENT = 'Account of the evidence transaction',
    alert_evidence.evidence_txn_ts AS TXN_TS COMMENT = 'Evidence transaction date and time',
    alert_evidence.evidence_direction AS DIRECTION COMMENT = 'CREDIT or DEBIT',
    alert_evidence.evidence_channel AS CHANNEL COMMENT = 'Channel of the evidence transaction',
    alert_evidence.evidence_counterparty AS COUNTERPARTY_NAME COMMENT = 'Counterparty of the evidence transaction',
    alert_evidence.evidence_country AS COUNTERPARTY_COUNTRY COMMENT = 'Counterparty country of the evidence transaction',
    alert_evidence.evidence_description AS DESCRIPTION COMMENT = 'Narration of the evidence transaction',
    -- rules
    rules.rule_description AS DESCRIPTION COMMENT = 'What the rule detects and its threshold',
    rules.policy_clause AS POLICY_CLAUSE COMMENT = 'Clause number in TL-AML-POL-001',
    -- risk scores
    risk_scores.score_band AS RISK_BAND COMMENT = 'LOW (0-39), MEDIUM (40-69) or HIGH (70-100)',
    risk_scores.score_explanation AS SCORE_EXPLANATION
      WITH SYNONYMS = ('score breakdown')
      COMMENT = 'How the score is built, e.g. Score 100 = SCR-SAN 50 + TM-STR 35 + TM-INC 20 + ADV-MED 10',
    risk_scores.primary_account_id AS PRIMARY_ACCOUNT_ID COMMENT = 'Customer main account',
    risk_scores.last_alert_date AS LAST_ALERT_DATE COMMENT = 'Most recent alert date',
    -- loans
    loans.loan_identifier AS LOAN_ID COMMENT = 'Loan identifier',
    loans.product AS PRODUCT COMMENT = 'Loan product, e.g. HOME_LOAN, BUSINESS_LOAN',
    loans.loan_classification AS ASSET_CLASSIFICATION
      WITH SYNONYMS = ('NPA status', 'SMA status')
      COMMENT = 'STANDARD, SMA-0, SMA-1, SMA-2 or NPA',
    loans.dpd AS DPD WITH SYNONYMS = ('days past due') COMMENT = 'Days past due'
  )
  METRICS (
    transactions.transaction_count AS COUNT(*)
      COMMENT = 'Number of transactions',
    transactions.total_amount AS SUM(transactions.AMOUNT)
      WITH SYNONYMS = ('total value', 'volume')
      COMMENT = 'Total transaction value in INR',
    transactions.total_credits AS SUM(IFF(transactions.DIRECTION = 'CREDIT', transactions.AMOUNT, 0))
      WITH SYNONYMS = ('money in', 'inflows', 'total deposits')
      COMMENT = 'Total credited amount in INR',
    transactions.total_debits AS SUM(IFF(transactions.DIRECTION = 'DEBIT', transactions.AMOUNT, 0))
      WITH SYNONYMS = ('money out', 'outflows')
      COMMENT = 'Total debited amount in INR',
    transactions.total_cash_deposits AS SUM(IFF(transactions.CHANNEL = 'CASH' AND transactions.DIRECTION = 'CREDIT', transactions.AMOUNT, 0))
      WITH SYNONYMS = ('cash deposits', 'cash in')
      COMMENT = 'Total cash deposited in INR',
    transactions.cash_deposit_count AS SUM(IFF(transactions.CHANNEL = 'CASH' AND transactions.DIRECTION = 'CREDIT', 1, 0))
      COMMENT = 'Number of cash deposits',
    transactions.sub_threshold_cash_deposit_count AS SUM(IFF(transactions.CHANNEL = 'CASH' AND transactions.DIRECTION = 'CREDIT'
                                                             AND transactions.AMOUNT >= 800000 AND transactions.AMOUNT < 1000000, 1, 0))
      WITH SYNONYMS = ('deposits just below threshold', 'structured deposits')
      COMMENT = 'Cash deposits between INR 8 and 10 lakh (just below the CTR threshold)',
    transactions.cross_border_amount AS SUM(IFF(transactions.CHANNEL = 'SWIFT', transactions.AMOUNT, 0))
      WITH SYNONYMS = ('SWIFT volume', 'foreign remittances')
      COMMENT = 'Total SWIFT (cross-border) value in INR',
    alerts.alert_count AS COUNT(*)
      WITH SYNONYMS = ('number of alerts', 'open alerts', 'flags')
      COMMENT = 'Number of alerts',
    alerts.flagged_amount AS SUM(alerts.AMOUNT_INR)
      COMMENT = 'Total INR amount involved in alerts',
    alerts.flagged_account_count AS COUNT(DISTINCT alerts.ACCOUNT_ID)
      COMMENT = 'Number of distinct flagged accounts',
    alert_evidence.evidence_txn_count AS COUNT(*)
      COMMENT = 'Number of evidence transactions',
    alert_evidence.evidence_total AS SUM(alert_evidence.AMOUNT)
      COMMENT = 'Total INR value of evidence transactions',
    risk_scores.max_risk_score AS MAX(risk_scores.RISK_SCORE)
      WITH SYNONYMS = ('risk score', 'score')
      COMMENT = 'Customer risk score 0-100 (use with a customer dimension)',
    risk_scores.avg_risk_score AS AVG(risk_scores.RISK_SCORE)
      COMMENT = 'Average risk score',
    risk_scores.high_risk_customer_count AS SUM(IFF(risk_scores.RISK_BAND = 'HIGH', 1, 0))
      WITH SYNONYMS = ('high-risk customers')
      COMMENT = 'Number of HIGH band customers',
    loans.total_outstanding AS SUM(loans.OUTSTANDING_AMOUNT)
      WITH SYNONYMS = ('exposure', 'loan exposure', 'EAD')
      COMMENT = 'Total outstanding loan exposure in INR',
    loans.npa_outstanding AS SUM(IFF(loans.ASSET_CLASSIFICATION = 'NPA', loans.OUTSTANDING_AMOUNT, 0))
      COMMENT = 'Outstanding amount of non-performing loans in INR',
    loans.loan_count AS COUNT(*)
      COMMENT = 'Number of loans',
    accounts.total_balance AS SUM(accounts.CURRENT_BALANCE)
      WITH SYNONYMS = ('deposits held', 'total deposits balance')
      COMMENT = 'Sum of account balances in INR'
  )
  COMMENT = 'TraceLedger AML investigation model: customers, accounts, transactions, explainable alerts, risk scores and loans (INR)';

SHOW SEMANTIC VIEWS IN SCHEMA TRACELEDGER.APP;

-- Quick test: alert counts by rule, straight from the semantic view
SELECT * FROM SEMANTIC_VIEW(
  TRACELEDGER.APP.TRACELEDGER_SV
  METRICS alerts.alert_count, alerts.flagged_amount
  DIMENSIONS alerts.rule_name
)
ORDER BY alert_count DESC;
