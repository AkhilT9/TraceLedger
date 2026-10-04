-- =============================================================================
-- TraceLedger | Layer 2 | 08_live_alert_demo.sql
-- Live demo: a clean customer suddenly structures cash and wires it to a
-- sanctioned-looking UAE company. Run the steps one at a time (not Run All).
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;

-- STEP 0 | Before: ACC-1038 (Karan Verma, salaried IT employee) is clean.
SELECT CUSTOMER_ID, PRIMARY_ACCOUNT_ID, RISK_SCORE, RISK_BAND, SCORE_EXPLANATION
FROM SIGNALS.RISK_SCORES WHERE PRIMARY_ACCOUNT_ID = 'ACC-1038';

-- STEP 1 | New transactions land: three cash deposits just under INR 10 lakh at
-- three branches, then one RTGS of almost all of it to a UAE company.
INSERT INTO CORE.TRANSACTIONS
  (TXN_ID, ACCOUNT_ID, TXN_TS, DIRECTION, AMOUNT, CURRENCY, CHANNEL,
   COUNTERPARTY_ACCOUNT_ID, COUNTERPARTY_NAME, COUNTERPARTY_BANK, COUNTERPARTY_COUNTRY, DESCRIPTION)
SELECT 'TXN-LIVE-01', 'ACC-1038', DATEADD(hour, -30, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, 'CREDIT', 920000, 'INR', 'CASH',
       NULL, NULL, NULL, 'IN', 'Cash deposit at BR-001'
UNION ALL
SELECT 'TXN-LIVE-02', 'ACC-1038', DATEADD(hour, -26, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, 'CREDIT', 965000, 'INR', 'CASH',
       NULL, NULL, NULL, 'IN', 'Cash deposit at BR-003'
UNION ALL
SELECT 'TXN-LIVE-03', 'ACC-1038', DATEADD(hour, -6, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, 'CREDIT', 985000, 'INR', 'CASH',
       NULL, NULL, NULL, 'IN', 'Cash deposit at BR-002'
UNION ALL
SELECT 'TXN-LIVE-04', 'ACC-1038', DATEADD(hour, -1, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, 'DEBIT', 2800000, 'INR', 'RTGS',
       NULL, 'Red Sea Logistics FZE', 'Gulf Crescent Bank', 'AE', 'Payment for goods';

-- STEP 2 | The dynamic tables pick this up on their own within ~1 minute.
-- To skip the wait during a demo, force the refresh:
ALTER DYNAMIC TABLE SIGNALS.ALERTS REFRESH;
ALTER DYNAMIC TABLE SIGNALS.RISK_SCORES REFRESH;

-- STEP 3 | After: new alerts with evidence and the policy clause they breach.
SELECT ALERT_ID, RULE_ID, POLICY_REF, WEIGHT, REASON, EVIDENCE_TXN_IDS
FROM SIGNALS.ALERTS WHERE ACCOUNT_ID = 'ACC-1038' ORDER BY WEIGHT DESC;

SELECT CUSTOMER_ID, RISK_SCORE, RISK_BAND, SCORE_EXPLANATION
FROM SIGNALS.RISK_SCORES WHERE PRIMARY_ACCOUNT_ID = 'ACC-1038';

-- STEP 4 | Reset the demo (remove the inserted transactions).
DELETE FROM CORE.TRANSACTIONS WHERE TXN_ID LIKE 'TXN-LIVE-%';
ALTER DYNAMIC TABLE SIGNALS.ALERTS REFRESH;
ALTER DYNAMIC TABLE SIGNALS.RISK_SCORES REFRESH;
