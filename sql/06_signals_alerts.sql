-- =============================================================================
-- TraceLedger | Layer 2 | 06_signals_alerts.sql
-- Union of all rules -> ALERTS (Dynamic Table) -> RISK_SCORES (Dynamic Table).
-- Both refresh automatically within ~1 minute of any change to transactions,
-- customers, watchlist or rule parameters. With no changes, a refresh is a
-- NO_DATA refresh and does not wake the warehouse.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA SIGNALS;

CREATE OR REPLACE VIEW V_RULE_HITS AS
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_STR
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_VEL
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_DOR
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_GEO
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_INC
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_RND
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_RIO
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_TM_NET
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_SCR_SAN
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_SCR_PEP
UNION ALL
SELECT RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR, TXN_COUNT, EVIDENCE_TXN_IDS, REASON, DETAIL FROM RULE_ADV_MED;

-- -----------------------------------------------------------------------------
-- ALERTS: one row per (rule, account). ALERT_ID is stable across refreshes so
-- cases in Layer 4 can reference it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ALERTS
  TARGET_LAG = '1 minute'
  WAREHOUSE = TRACELEDGER_WH
  REFRESH_MODE = FULL
  COMMENT = 'Explainable AML alerts - one row per rule per account, with evidence transaction ids and policy clause'
AS
SELECT 'AL-' || h.RULE_ID || '-' || h.ACCOUNT_ID                      AS ALERT_ID,
       h.RULE_ID,
       rc.RULE_NAME,
       rc.TYPOLOGY,
       h.CUSTOMER_ID,
       h.ACCOUNT_ID,
       a.BRANCH_ID,
       b.REGION,
       h.WINDOW_START,
       h.WINDOW_END,
       h.WINDOW_END::DATE                                              AS ALERT_DATE,
       h.AMOUNT_INR,
       h.TXN_COUNT,
       h.EVIDENCE_TXN_IDS,
       h.REASON,
       h.DETAIL,
       IFF(h.DETAIL:match_type::STRING = 'POTENTIAL_TRUE_MATCH',
           COALESCE(rc.ESCALATED_WEIGHT, rc.WEIGHT), rc.WEIGHT)        AS WEIGHT,
       rc.POLICY_DOC,
       rc.POLICY_CLAUSE,
       rc.POLICY_DOC || ' section ' || rc.POLICY_CLAUSE                AS POLICY_REF
FROM V_RULE_HITS h
JOIN RULE_CATALOG rc ON rc.RULE_ID = h.RULE_ID
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = h.ACCOUNT_ID
JOIN CORE.BRANCHES b ON b.BRANCH_ID = a.BRANCH_ID;

-- -----------------------------------------------------------------------------
-- RISK_SCORES: one row per customer. Score = sum of weights of distinct rules
-- fired (plus KYC-HIGH), capped at 100, with a human-readable breakdown.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE RISK_SCORES
  TARGET_LAG = '1 minute'
  WAREHOUSE = TRACELEDGER_WH
  REFRESH_MODE = FULL
  COMMENT = 'Explainable customer risk score (Policy section 6)'
AS
WITH p AS (
  SELECT * FROM V_PARAMS
),
f AS (
  SELECT CUSTOMER_ID, RULE_ID AS FACTOR, MAX(WEIGHT) AS WEIGHT
  FROM ALERTS
  GROUP BY CUSTOMER_ID, RULE_ID
  UNION ALL
  SELECT c.CUSTOMER_ID, rc.RULE_ID, rc.WEIGHT
  FROM CORE.CUSTOMERS c
  JOIN RULE_CATALOG rc ON rc.RULE_ID = 'KYC-HIGH'
  WHERE c.KYC_RISK_TIER = 'HIGH'
),
s AS (
  SELECT CUSTOMER_ID,
         SUM(WEIGHT) AS RAW_SCORE,
         COUNT_IF(FACTOR <> 'KYC-HIGH') AS N_RULES_FIRED,
         LISTAGG(FACTOR || ' ' || WEIGHT, ' + ') WITHIN GROUP (ORDER BY WEIGHT DESC, FACTOR) AS BREAKDOWN,
         ARRAY_AGG(OBJECT_CONSTRUCT('factor', FACTOR, 'weight', WEIGHT))
           WITHIN GROUP (ORDER BY WEIGHT DESC, FACTOR) AS FACTORS
  FROM f
  GROUP BY CUSTOMER_ID
),
al AS (
  SELECT CUSTOMER_ID, COUNT(*) AS N_ALERTS, MAX(ALERT_DATE) AS LAST_ALERT_DATE,
         SUM(AMOUNT_INR) AS FLAGGED_AMOUNT_INR,
         ARRAY_AGG(DISTINCT ACCOUNT_ID) AS FLAGGED_ACCOUNTS
  FROM ALERTS
  GROUP BY CUSTOMER_ID
)
SELECT c.CUSTOMER_ID,
       pa.ACCOUNT_ID                                        AS PRIMARY_ACCOUNT_ID,
       c.REGION,
       c.HOME_BRANCH_ID,
       c.CUSTOMER_TYPE,
       c.OCCUPATION,
       c.KYC_RISK_TIER,
       c.PEP_FLAG,
       LEAST(100, COALESCE(s.RAW_SCORE, 0))                 AS RISK_SCORE,
       COALESCE(s.RAW_SCORE, 0)                             AS RAW_SCORE,
       CASE WHEN LEAST(100, COALESCE(s.RAW_SCORE, 0)) >= p.BAND_HIGH   THEN 'HIGH'
            WHEN LEAST(100, COALESCE(s.RAW_SCORE, 0)) >= p.BAND_MEDIUM THEN 'MEDIUM'
            ELSE 'LOW' END                                  AS RISK_BAND,
       IFF(s.CUSTOMER_ID IS NULL, 'Score 0 = no rules fired',
           'Score ' || LEAST(100, s.RAW_SCORE) || ' = ' || s.BREAKDOWN
           || IFF(s.RAW_SCORE > 100, ' (' || s.RAW_SCORE || ', capped at 100)', ''))
                                                            AS SCORE_EXPLANATION,
       COALESCE(s.N_RULES_FIRED, 0)                         AS N_RULES_FIRED,
       COALESCE(al.N_ALERTS, 0)                             AS N_ALERTS,
       COALESCE(al.FLAGGED_AMOUNT_INR, 0)                   AS FLAGGED_AMOUNT_INR,
       al.LAST_ALERT_DATE,
       al.FLAGGED_ACCOUNTS,
       COALESCE(s.FACTORS, ARRAY_CONSTRUCT())               AS SCORE_FACTORS
FROM CORE.CUSTOMERS c
CROSS JOIN p
LEFT JOIN s  ON s.CUSTOMER_ID  = c.CUSTOMER_ID
LEFT JOIN al ON al.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN V_PRIMARY_ACCOUNT pa ON pa.CUSTOMER_ID = c.CUSTOMER_ID;

-- Flagged-account dashboard view (Layer 4 "Risk dashboard").
CREATE OR REPLACE VIEW V_ACCOUNT_RISK AS
SELECT a.ACCOUNT_ID, a.CUSTOMER_ID, a.BRANCH_ID, b.REGION,
       COUNT(*)                                                       AS N_ALERTS,
       LEAST(100, SUM(al.WEIGHT))                                     AS ACCOUNT_SCORE,
       LISTAGG(al.RULE_ID || ' ' || al.WEIGHT, ' + ') WITHIN GROUP (ORDER BY al.WEIGHT DESC, al.RULE_ID) AS RULES_FIRED,
       MAX(al.ALERT_DATE)                                             AS LAST_ALERT_DATE,
       SUM(al.AMOUNT_INR)                                             AS FLAGGED_AMOUNT_INR
FROM ALERTS al
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = al.ACCOUNT_ID
JOIN CORE.BRANCHES b ON b.BRANCH_ID = a.BRANCH_ID
GROUP BY a.ACCOUNT_ID, a.CUSTOMER_ID, a.BRANCH_ID, b.REGION;

-- Make sure both tables are populated right away.
ALTER DYNAMIC TABLE ALERTS REFRESH;
ALTER DYNAMIC TABLE RISK_SCORES REFRESH;

SELECT RULE_ID, COUNT(*) AS N_ALERTS FROM ALERTS GROUP BY RULE_ID ORDER BY RULE_ID;
