-- =============================================================================
-- TraceLedger | Layer 2 | 04_signals_rules.sql
-- Rule catalog, tunable parameters and one view per transaction-monitoring
-- typology. Every rule maps to a numbered clause in TL-AML-POL-001.
--
-- Every RULE_* view returns the same columns so they can be unioned:
--   RULE_ID, CUSTOMER_ID, ACCOUNT_ID, WINDOW_START, WINDOW_END, AMOUNT_INR,
--   TXN_COUNT, EVIDENCE_TXN_IDS (ARRAY), REASON (text), DETAIL (OBJECT)
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA SIGNALS;

-- -----------------------------------------------------------------------------
-- Rule catalog: rule -> policy clause -> weight (Policy section 6.2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE RULE_CATALOG (
  RULE_ID           VARCHAR(10) PRIMARY KEY,
  RULE_NAME         VARCHAR(60),
  TYPOLOGY          VARCHAR(30),
  POLICY_DOC        VARCHAR(20),
  POLICY_CLAUSE     VARCHAR(10),
  WEIGHT            NUMBER(3)  COMMENT 'Points added to the customer risk score',
  ESCALATED_WEIGHT  NUMBER(3)  COMMENT 'Weight used for the escalated variant (e.g. potential true sanctions match)',
  DESCRIPTION       VARCHAR(400)
) COMMENT = 'Explainable rule catalog mapping each detection rule to the AML policy';

INSERT INTO RULE_CATALOG VALUES
 ('TM-STR',  'Structuring',                        'PLACEMENT',   'TL-AML-POL-001', '4.2',  35, NULL, 'Three or more cash deposits between INR 8 lakh and INR 10 lakh within 7 days.'),
 ('TM-VEL',  'Velocity spike',                     'MULE',        'TL-AML-POL-001', '4.3',  15, NULL, '30+ transactions in 3 days and more than 5x the 90-day baseline.'),
 ('TM-DOR',  'Dormant account reactivation',       'MULE',        'TL-AML-POL-001', '4.4',  20, NULL, 'Inactive 180+ days, then INR 5 lakh+ credited within 30 days.'),
 ('TM-GEO',  'High-risk geography / round-tripping','LAYERING',   'TL-AML-POL-001', '4.5',  25, NULL, 'Transactions with FATF call-for-action, increased-monitoring or tax-haven jurisdictions; round-tripping.'),
 ('TM-INC',  'Income / profile mismatch',          'MULE',        'TL-AML-POL-001', '4.6',  20, NULL, '12-month credits above 5x declared income and at least INR 10 lakh.'),
 ('TM-RND',  'Round-amount transactions',          'LAYERING',    'TL-AML-POL-001', '4.7',  10, NULL, '5+ transactions of exact INR 1 lakh multiples within 90 days.'),
 ('TM-RIO',  'Rapid in-out / pass-through',        'LAYERING',    'TL-AML-POL-001', '4.8',  20, NULL, 'Credit of INR 5 lakh+ with 90%+ debited within 48 hours, at least 75% of it in one onward payment.'),
 ('TM-NET',  'Mule ring / fan-in hub',             'NETWORK',     'TL-AML-POL-001', '4.9',  30, NULL, 'Circular flows back to origin within 7 days, or 10+ senders into one account then 80%+ sent out.'),
 ('SCR-SAN', 'Sanctions / watchlist match',        'SANCTIONS',   'TL-AML-POL-001', '5.2',  30, 50,   'Fuzzy name match of customer or counterparty against the watchlist (85+ near match, 95+ potential true match).'),
 ('SCR-PEP', 'PEP third-party credits',            'CORRUPTION',  'TL-AML-POL-001', '3.4',  10, NULL, 'PEP account receiving INR 10 lakh+ from third parties.'),
 ('ADV-MED', 'Adverse media',                      'REPUTATION',  'TL-AML-POL-001', '4.10', 10, NULL, 'Negative news mentioning the customer.'),
 ('KYC-HIGH','KYC risk tier HIGH',                 'CDD',         'TL-AML-POL-001', '6.2',  10, NULL, 'Customer rated HIGH risk at onboarding or last KYC review (score factor, not an alert).');

-- -----------------------------------------------------------------------------
-- Tunable parameters (the What-If simulator in Layer 4 reads these)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE RULE_PARAMS (
  PARAM_NAME   VARCHAR(40) PRIMARY KEY,
  PARAM_VALUE  NUMBER(18,4),
  RULE_ID      VARCHAR(10),
  DESCRIPTION  VARCHAR(200)
) COMMENT = 'Detection thresholds - change a value and the dynamic tables recompute alerts';

INSERT INTO RULE_PARAMS VALUES
 ('CTR_THRESHOLD',          1000000, 'TM-CTR',  'Cash transaction reporting threshold (INR)'),
 ('STR_MIN_AMOUNT',          800000, 'TM-STR',  'Lower bound of a sub-threshold cash deposit (INR)'),
 ('STR_MIN_COUNT',                3, 'TM-STR',  'Deposits needed inside the window'),
 ('STR_WINDOW_DAYS',              7, 'TM-STR',  'Rolling window (days)'),
 ('VEL_MIN_TXNS',                30, 'TM-VEL',  'Minimum transactions in the velocity window'),
 ('VEL_MULTIPLIER',               5, 'TM-VEL',  'Multiple of baseline activity'),
 ('VEL_WINDOW_DAYS',              3, 'TM-VEL',  'Velocity window (days)'),
 ('VEL_BASELINE_DAYS',           90, 'TM-VEL',  'Baseline look-back (days)'),
 ('DOR_INACTIVE_DAYS',          180, 'TM-DOR',  'Days without activity to be treated as inactive'),
 ('DOR_MIN_CREDIT',          500000, 'TM-DOR',  'Credits after reactivation that trigger an alert (INR)'),
 ('DOR_LOOKAHEAD_DAYS',          30, 'TM-DOR',  'Days after reactivation to aggregate'),
 ('GEO_MIN_AGG',            1000000, 'TM-GEO',  'Aggregate with high-risk jurisdictions in the window (INR)'),
 ('GEO_WINDOW_DAYS',             90, 'TM-GEO',  'Aggregation window (days)'),
 ('GEO_RT_DAYS',                 30, 'TM-GEO',  'Max days between outflow and returning inflow (round-trip)'),
 ('GEO_RT_TOLERANCE',          0.10, 'TM-GEO',  'Max relative value difference for a round-trip pair'),
 ('INC_MULTIPLIER',               5, 'TM-INC',  'Credits as a multiple of declared annual income'),
 ('INC_MIN_CREDITS',        1000000, 'TM-INC',  'Minimum 12-month credits (INR)'),
 ('INC_LOOKBACK_MONTHS',         12, 'TM-INC',  'Look-back (months)'),
 ('RND_UNIT',                100000, 'TM-RND',  'Round unit and minimum amount (INR 1 lakh)'),
 ('RND_MIN_COUNT',                5, 'TM-RND',  'Round-amount transactions inside the window'),
 ('RND_WINDOW_DAYS',             90, 'TM-RND',  'Window (days)'),
 ('RIO_MIN_CREDIT',          500000, 'TM-RIO',  'Minimum credit (INR)'),
 ('RIO_HOURS',                   48, 'TM-RIO',  'Hours within which the money leaves'),
 ('RIO_OUT_PCT',               0.90, 'TM-RIO',  'Share of the credit debited'),
 ('RIO_SINGLE_PCT',            0.75, 'TM-RIO',  'Share of the credit that must leave in one onward payment'),
 ('NET_CYCLE_DAYS',               7, 'TM-NET',  'Max days for funds to return to origin'),
 ('NET_CYCLE_MIN_HOPS',           3, 'TM-NET',  'Min transfers in a cycle (origin + 2 intermediaries)'),
 ('NET_CYCLE_MAX_HOPS',           6, 'TM-NET',  'Max transfers searched'),
 ('NET_FANIN_MIN_SENDERS',       10, 'TM-NET',  'Distinct senders into one account'),
 ('NET_FANIN_DAYS',               7, 'TM-NET',  'Fan-in window (days)'),
 ('NET_FANIN_OUT_PCT',         0.80, 'TM-NET',  'Share of receipts sent onward'),
 ('SAN_TRUE_MATCH',              95, 'SCR-SAN', 'Jaro-Winkler score for a potential true match'),
 ('SAN_NEAR_MATCH',              85, 'SCR-SAN', 'Jaro-Winkler score for a near match'),
 ('PEP_MIN_CREDIT',         1000000, 'SCR-PEP', 'Third-party credit to a PEP that needs review (INR)'),
 ('ADV_NAME_MATCH',              95, 'ADV-MED', 'Jaro-Winkler score to link an article to a customer'),
 ('BAND_MEDIUM',                 40, 'SCORE',   'Score at or above which the band is MEDIUM'),
 ('BAND_HIGH',                   70, 'SCORE',   'Score at or above which the band is HIGH');

CREATE OR REPLACE VIEW V_PARAMS AS
SELECT
  MAX(IFF(PARAM_NAME = 'CTR_THRESHOLD',         PARAM_VALUE, NULL))::NUMBER(18,2) AS CTR_THRESHOLD,
  MAX(IFF(PARAM_NAME = 'STR_MIN_AMOUNT',        PARAM_VALUE, NULL))::NUMBER(18,2) AS STR_MIN_AMOUNT,
  MAX(IFF(PARAM_NAME = 'STR_MIN_COUNT',         PARAM_VALUE, NULL))::INT          AS STR_MIN_COUNT,
  MAX(IFF(PARAM_NAME = 'STR_WINDOW_DAYS',       PARAM_VALUE, NULL))::INT          AS STR_WINDOW_DAYS,
  MAX(IFF(PARAM_NAME = 'VEL_MIN_TXNS',          PARAM_VALUE, NULL))::INT          AS VEL_MIN_TXNS,
  MAX(IFF(PARAM_NAME = 'VEL_MULTIPLIER',        PARAM_VALUE, NULL))::FLOAT        AS VEL_MULTIPLIER,
  MAX(IFF(PARAM_NAME = 'VEL_WINDOW_DAYS',       PARAM_VALUE, NULL))::INT          AS VEL_WINDOW_DAYS,
  MAX(IFF(PARAM_NAME = 'VEL_BASELINE_DAYS',     PARAM_VALUE, NULL))::INT          AS VEL_BASELINE_DAYS,
  MAX(IFF(PARAM_NAME = 'DOR_INACTIVE_DAYS',     PARAM_VALUE, NULL))::INT          AS DOR_INACTIVE_DAYS,
  MAX(IFF(PARAM_NAME = 'DOR_MIN_CREDIT',        PARAM_VALUE, NULL))::NUMBER(18,2) AS DOR_MIN_CREDIT,
  MAX(IFF(PARAM_NAME = 'DOR_LOOKAHEAD_DAYS',    PARAM_VALUE, NULL))::INT          AS DOR_LOOKAHEAD_DAYS,
  MAX(IFF(PARAM_NAME = 'GEO_MIN_AGG',           PARAM_VALUE, NULL))::NUMBER(18,2) AS GEO_MIN_AGG,
  MAX(IFF(PARAM_NAME = 'GEO_WINDOW_DAYS',       PARAM_VALUE, NULL))::INT          AS GEO_WINDOW_DAYS,
  MAX(IFF(PARAM_NAME = 'GEO_RT_DAYS',           PARAM_VALUE, NULL))::INT          AS GEO_RT_DAYS,
  MAX(IFF(PARAM_NAME = 'GEO_RT_TOLERANCE',      PARAM_VALUE, NULL))::FLOAT        AS GEO_RT_TOLERANCE,
  MAX(IFF(PARAM_NAME = 'INC_MULTIPLIER',        PARAM_VALUE, NULL))::FLOAT        AS INC_MULTIPLIER,
  MAX(IFF(PARAM_NAME = 'INC_MIN_CREDITS',       PARAM_VALUE, NULL))::NUMBER(18,2) AS INC_MIN_CREDITS,
  MAX(IFF(PARAM_NAME = 'INC_LOOKBACK_MONTHS',   PARAM_VALUE, NULL))::INT          AS INC_LOOKBACK_MONTHS,
  MAX(IFF(PARAM_NAME = 'RND_UNIT',              PARAM_VALUE, NULL))::NUMBER(18,2) AS RND_UNIT,
  MAX(IFF(PARAM_NAME = 'RND_MIN_COUNT',         PARAM_VALUE, NULL))::INT          AS RND_MIN_COUNT,
  MAX(IFF(PARAM_NAME = 'RND_WINDOW_DAYS',       PARAM_VALUE, NULL))::INT          AS RND_WINDOW_DAYS,
  MAX(IFF(PARAM_NAME = 'RIO_MIN_CREDIT',        PARAM_VALUE, NULL))::NUMBER(18,2) AS RIO_MIN_CREDIT,
  MAX(IFF(PARAM_NAME = 'RIO_HOURS',             PARAM_VALUE, NULL))::INT          AS RIO_HOURS,
  MAX(IFF(PARAM_NAME = 'RIO_OUT_PCT',           PARAM_VALUE, NULL))::FLOAT        AS RIO_OUT_PCT,
  MAX(IFF(PARAM_NAME = 'RIO_SINGLE_PCT',        PARAM_VALUE, NULL))::FLOAT        AS RIO_SINGLE_PCT,
  MAX(IFF(PARAM_NAME = 'NET_CYCLE_DAYS',        PARAM_VALUE, NULL))::INT          AS NET_CYCLE_DAYS,
  MAX(IFF(PARAM_NAME = 'NET_CYCLE_MIN_HOPS',    PARAM_VALUE, NULL))::INT          AS NET_CYCLE_MIN_HOPS,
  MAX(IFF(PARAM_NAME = 'NET_CYCLE_MAX_HOPS',    PARAM_VALUE, NULL))::INT          AS NET_CYCLE_MAX_HOPS,
  MAX(IFF(PARAM_NAME = 'NET_FANIN_MIN_SENDERS', PARAM_VALUE, NULL))::INT          AS NET_FANIN_MIN_SENDERS,
  MAX(IFF(PARAM_NAME = 'NET_FANIN_DAYS',        PARAM_VALUE, NULL))::INT          AS NET_FANIN_DAYS,
  MAX(IFF(PARAM_NAME = 'NET_FANIN_OUT_PCT',     PARAM_VALUE, NULL))::FLOAT        AS NET_FANIN_OUT_PCT,
  MAX(IFF(PARAM_NAME = 'SAN_TRUE_MATCH',        PARAM_VALUE, NULL))::INT          AS SAN_TRUE_MATCH,
  MAX(IFF(PARAM_NAME = 'SAN_NEAR_MATCH',        PARAM_VALUE, NULL))::INT          AS SAN_NEAR_MATCH,
  MAX(IFF(PARAM_NAME = 'PEP_MIN_CREDIT',        PARAM_VALUE, NULL))::NUMBER(18,2) AS PEP_MIN_CREDIT,
  MAX(IFF(PARAM_NAME = 'ADV_NAME_MATCH',        PARAM_VALUE, NULL))::INT          AS ADV_NAME_MATCH,
  MAX(IFF(PARAM_NAME = 'BAND_MEDIUM',           PARAM_VALUE, NULL))::INT          AS BAND_MEDIUM,
  MAX(IFF(PARAM_NAME = 'BAND_HIGH',             PARAM_VALUE, NULL))::INT          AS BAND_HIGH
FROM RULE_PARAMS;

-- -----------------------------------------------------------------------------
-- Helper views
-- -----------------------------------------------------------------------------

-- The customer's main account (most transactions) - used for customer-level rules.
CREATE OR REPLACE VIEW V_PRIMARY_ACCOUNT AS
WITH n AS (
  SELECT ACCOUNT_ID, COUNT(*) AS N_TXNS FROM CORE.TRANSACTIONS GROUP BY ACCOUNT_ID
)
SELECT a.CUSTOMER_ID, a.ACCOUNT_ID
FROM CORE.ACCOUNTS a
LEFT JOIN n ON n.ACCOUNT_ID = a.ACCOUNT_ID
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.CUSTOMER_ID
                           ORDER BY COALESCE(n.N_TXNS, 0) DESC, a.OPEN_DATE, a.ACCOUNT_ID) = 1;

-- Transfers between two TraceLedger accounts (one row per sending debit).
CREATE OR REPLACE VIEW V_INTERNAL_TRANSFERS AS
SELECT TXN_ID, ACCOUNT_ID AS SRC_ACCOUNT_ID, COUNTERPARTY_ACCOUNT_ID AS DST_ACCOUNT_ID,
       TXN_TS, AMOUNT, CHANNEL
FROM CORE.TRANSACTIONS
WHERE DIRECTION = 'DEBIT'
  AND COUNTERPARTY_ACCOUNT_ID IS NOT NULL
  AND COUNTERPARTY_ACCOUNT_ID <> ACCOUNT_ID;

-- Graph edges for the network visual: internal transfers plus large external wires.
CREATE OR REPLACE VIEW V_NETWORK_EDGES AS
SELECT SRC_ACCOUNT_ID AS SRC_NODE, DST_ACCOUNT_ID AS DST_NODE, 'INTERNAL' AS EDGE_TYPE,
       COUNT(*) AS N_TXNS, SUM(AMOUNT) AS TOTAL_INR, MIN(TXN_TS) AS FIRST_TS, MAX(TXN_TS) AS LAST_TS
FROM V_INTERNAL_TRANSFERS
GROUP BY SRC_ACCOUNT_ID, DST_ACCOUNT_ID
UNION ALL
SELECT ACCOUNT_ID, 'EXT: ' || COUNTERPARTY_NAME || ' (' || COUNTERPARTY_COUNTRY || ')', 'EXTERNAL_OUT',
       COUNT(*), SUM(AMOUNT), MIN(TXN_TS), MAX(TXN_TS)
FROM CORE.TRANSACTIONS
WHERE DIRECTION = 'DEBIT' AND COUNTERPARTY_ACCOUNT_ID IS NULL AND COUNTERPARTY_NAME IS NOT NULL
  AND CHANNEL IN ('SWIFT', 'RTGS') AND AMOUNT >= 500000
GROUP BY ACCOUNT_ID, COUNTERPARTY_NAME, COUNTERPARTY_COUNTRY
UNION ALL
SELECT 'EXT: ' || COUNTERPARTY_NAME || ' (' || COUNTERPARTY_COUNTRY || ')', ACCOUNT_ID, 'EXTERNAL_IN',
       COUNT(*), SUM(AMOUNT), MIN(TXN_TS), MAX(TXN_TS)
FROM CORE.TRANSACTIONS
WHERE DIRECTION = 'CREDIT' AND COUNTERPARTY_ACCOUNT_ID IS NULL AND COUNTERPARTY_NAME IS NOT NULL
  AND CHANNEL IN ('SWIFT', 'RTGS') AND AMOUNT >= 500000
GROUP BY ACCOUNT_ID, COUNTERPARTY_NAME, COUNTERPARTY_COUNTRY;

-- Cash Transaction Report candidates (Policy 4.1). A regulatory report, not an alert.
CREATE OR REPLACE VIEW V_CTR_REPORT AS
WITH p AS (SELECT * FROM V_PARAMS),
cash AS (
  SELECT a.CUSTOMER_ID, t.ACCOUNT_ID, t.TXN_ID, t.TXN_TS, t.DIRECTION, t.AMOUNT,
         DATE_TRUNC('month', t.TXN_TS)::DATE AS REPORT_MONTH
  FROM CORE.TRANSACTIONS t
  JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID
  WHERE t.CHANNEL = 'CASH'
)
SELECT c.REPORT_MONTH, c.CUSTOMER_ID,
       SUM(IFF(c.DIRECTION = 'CREDIT', c.AMOUNT, 0)) AS CASH_DEPOSITS_INR,
       SUM(IFF(c.DIRECTION = 'DEBIT',  c.AMOUNT, 0)) AS CASH_WITHDRAWALS_INR,
       COUNT(*) AS N_CASH_TXNS,
       MAX(c.AMOUNT) AS LARGEST_CASH_TXN_INR,
       IFF(MAX(c.AMOUNT) >= ANY_VALUE(p.CTR_THRESHOLD), 'SINGLE_TXN_ABOVE_THRESHOLD',
           'CONNECTED_TXNS_ABOVE_THRESHOLD') AS CTR_REASON,
       ARRAY_AGG(c.TXN_ID) WITHIN GROUP (ORDER BY c.TXN_TS) AS TXN_IDS,
       DATEADD(day, 14, DATEADD(month, 1, c.REPORT_MONTH)) AS DUE_DATE
FROM cash c CROSS JOIN p
GROUP BY c.REPORT_MONTH, c.CUSTOMER_ID
HAVING SUM(c.AMOUNT) > ANY_VALUE(p.CTR_THRESHOLD) OR MAX(c.AMOUNT) >= ANY_VALUE(p.CTR_THRESHOLD);

-- =============================================================================
-- TM-STR | Structuring (Policy 4.2)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_STR AS
WITH p AS (SELECT * FROM V_PARAMS),
dep AS (
  SELECT t.TXN_ID, t.ACCOUNT_ID, t.TXN_TS, t.AMOUNT,
         p.STR_WINDOW_DAYS AS WD, p.STR_MIN_COUNT AS MC
  FROM CORE.TRANSACTIONS t CROSS JOIN p
  WHERE t.CHANNEL = 'CASH' AND t.DIRECTION = 'CREDIT'
    AND t.AMOUNT >= p.STR_MIN_AMOUNT AND t.AMOUNT < p.CTR_THRESHOLD
),
win AS (
  SELECT a.ACCOUNT_ID, a.TXN_ID AS ANCHOR_TXN_ID, a.TXN_TS AS WINDOW_START, a.WD,
         MAX(b.TXN_TS) AS WINDOW_END, COUNT(*) AS N, SUM(b.AMOUNT) AS TOTAL,
         ARRAY_AGG(b.TXN_ID) WITHIN GROUP (ORDER BY b.TXN_TS) AS TXNS
  FROM dep a
  JOIN dep b
    ON b.ACCOUNT_ID = a.ACCOUNT_ID
   AND b.TXN_TS >= a.TXN_TS
   AND b.TXN_TS < DATEADD(day, a.WD, a.TXN_TS)
  GROUP BY a.ACCOUNT_ID, a.TXN_ID, a.TXN_TS, a.WD, a.MC
  HAVING COUNT(*) >= a.MC
),
best AS (
  SELECT * FROM win
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID ORDER BY N DESC, TOTAL DESC, WINDOW_START) = 1
),
yr AS (
  SELECT ACCOUNT_ID, COUNT(*) AS N_ALL, SUM(AMOUNT) AS AMT_ALL FROM dep GROUP BY ACCOUNT_ID
)
SELECT 'TM-STR'                                   AS RULE_ID,
       a.CUSTOMER_ID,
       b.ACCOUNT_ID,
       b.WINDOW_START::TIMESTAMP_NTZ              AS WINDOW_START,
       b.WINDOW_END::TIMESTAMP_NTZ                AS WINDOW_END,
       b.TOTAL::NUMBER(18,2)                      AS AMOUNT_INR,
       b.N::INT                                   AS TXN_COUNT,
       b.TXNS                                     AS EVIDENCE_TXN_IDS,
       b.N || ' cash deposits between INR 8 and 10 lakh within ' || b.WD || ' days (total INR '
         || ROUND(b.TOTAL / 100000, 2) || ' lakh), each just below the INR 10 lakh CTR threshold. '
         || y.N_ALL || ' such deposits in total, worth INR ' || ROUND(y.AMT_ALL / 100000, 2) || ' lakh.'
                                                  AS REASON,
       OBJECT_CONSTRUCT('deposits_in_window', b.N, 'window_days', b.WD,
                        'sub_threshold_deposits_total', y.N_ALL,
                        'sub_threshold_amount_total', y.AMT_ALL) AS DETAIL
FROM best b
JOIN yr y ON y.ACCOUNT_ID = b.ACCOUNT_ID
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = b.ACCOUNT_ID;

-- =============================================================================
-- TM-VEL | Velocity spike (Policy 4.3)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_VEL AS
WITH p AS (SELECT * FROM V_PARAMS),
daily AS (
  SELECT ACCOUNT_ID, TXN_TS::DATE AS D, COUNT(*) AS N
  FROM CORE.TRANSACTIONS
  GROUP BY ACCOUNT_ID, TXN_TS::DATE
),
w AS (
  SELECT a.ACCOUNT_ID, a.D AS END_D, p.VEL_WINDOW_DAYS AS WD, p.VEL_BASELINE_DAYS AS BD,
         p.VEL_MIN_TXNS AS MIN_N, p.VEL_MULTIPLIER AS MULT,
         SUM(IFF(b.D >  DATEADD(day, -p.VEL_WINDOW_DAYS, a.D), b.N, 0)) AS N_WIN,
         SUM(IFF(b.D <= DATEADD(day, -p.VEL_WINDOW_DAYS, a.D), b.N, 0)) AS N_BASE
  FROM daily a
  CROSS JOIN p
  JOIN daily b
    ON b.ACCOUNT_ID = a.ACCOUNT_ID
   AND b.D <= a.D
   AND b.D >  DATEADD(day, -(p.VEL_WINDOW_DAYS + p.VEL_BASELINE_DAYS), a.D)
  GROUP BY a.ACCOUNT_ID, a.D, p.VEL_WINDOW_DAYS, p.VEL_BASELINE_DAYS, p.VEL_MIN_TXNS, p.VEL_MULTIPLIER
),
hit AS (
  SELECT ACCOUNT_ID, END_D, WD, N_WIN, MULT, N_BASE * WD / BD AS BASELINE
  FROM w
  WHERE N_WIN >= MIN_N AND N_WIN > MULT * (N_BASE * WD / BD)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID ORDER BY N_WIN DESC, END_D DESC) = 1
)
SELECT 'TM-VEL'                                   AS RULE_ID,
       a.CUSTOMER_ID,
       h.ACCOUNT_ID,
       MIN(t.TXN_TS)::TIMESTAMP_NTZ               AS WINDOW_START,
       MAX(t.TXN_TS)::TIMESTAMP_NTZ               AS WINDOW_END,
       SUM(t.AMOUNT)::NUMBER(18,2)                AS AMOUNT_INR,
       COUNT(*)::INT                              AS TXN_COUNT,
       ARRAY_AGG(t.TXN_ID) WITHIN GROUP (ORDER BY t.TXN_TS) AS EVIDENCE_TXN_IDS,
       COUNT(*) || ' transactions in ' || ANY_VALUE(h.WD) || ' days with '
         || COUNT(DISTINCT t.COUNTERPARTY_NAME) || ' different counterparties, versus a normal '
         || ROUND(ANY_VALUE(h.BASELINE), 1) || ' per ' || ANY_VALUE(h.WD) || ' days over the previous 90 days.'
                                                  AS REASON,
       OBJECT_CONSTRUCT('txns_in_window', COUNT(*), 'baseline_per_window', ROUND(ANY_VALUE(h.BASELINE), 2),
                        'distinct_counterparties', COUNT(DISTINCT t.COUNTERPARTY_NAME),
                        'window_end_date', ANY_VALUE(h.END_D)) AS DETAIL
FROM hit h
JOIN CORE.TRANSACTIONS t
  ON t.ACCOUNT_ID = h.ACCOUNT_ID
 AND t.TXN_TS::DATE >  DATEADD(day, -h.WD, h.END_D)
 AND t.TXN_TS::DATE <= h.END_D
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = h.ACCOUNT_ID
GROUP BY a.CUSTOMER_ID, h.ACCOUNT_ID;

-- =============================================================================
-- TM-DOR | Dormant account reactivation (Policy 4.4)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_DOR AS
WITH p AS (SELECT * FROM V_PARAMS),
bounds AS (
  SELECT MIN(TXN_TS) AS DATA_START FROM CORE.TRANSACTIONS
),
seq AS (
  SELECT TXN_ID, ACCOUNT_ID, TXN_TS,
         LAG(TXN_TS) OVER (PARTITION BY ACCOUNT_ID ORDER BY TXN_TS, TXN_ID) AS PREV_TS
  FROM CORE.TRANSACTIONS
),
react AS (
  SELECT s.ACCOUNT_ID, s.TXN_TS AS REACT_TS,
         -- with no earlier transaction on record, the account has been inactive at least since
         -- the later of its opening date and the start of the transaction history
         COALESCE(s.PREV_TS, GREATEST(a.OPEN_DATE::TIMESTAMP_NTZ, b.DATA_START)) AS LAST_ACTIVE_TS,
         p.DOR_LOOKAHEAD_DAYS AS LOOKAHEAD, p.DOR_MIN_CREDIT AS MIN_CREDIT
  FROM seq s
  JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = s.ACCOUNT_ID
  CROSS JOIN bounds b
  CROSS JOIN p
  WHERE DATEDIFF(day, COALESCE(s.PREV_TS, GREATEST(a.OPEN_DATE::TIMESTAMP_NTZ, b.DATA_START)), s.TXN_TS)
        >= p.DOR_INACTIVE_DAYS
),
agg AS (
  SELECT r.ACCOUNT_ID, r.REACT_TS, r.LAST_ACTIVE_TS, r.LOOKAHEAD, r.MIN_CREDIT,
         DATEDIFF(day, r.LAST_ACTIVE_TS, r.REACT_TS) AS INACTIVE_DAYS,
         SUM(IFF(t.DIRECTION = 'CREDIT', t.AMOUNT, 0)) AS CREDITS,
         SUM(IFF(t.DIRECTION = 'DEBIT',  t.AMOUNT, 0)) AS DEBITS,
         COUNT(*) AS N, MAX(t.TXN_TS) AS END_TS,
         ARRAY_AGG(t.TXN_ID) WITHIN GROUP (ORDER BY t.TXN_TS) AS TXNS
  FROM react r
  JOIN CORE.TRANSACTIONS t
    ON t.ACCOUNT_ID = r.ACCOUNT_ID
   AND t.TXN_TS >= r.REACT_TS
   AND t.TXN_TS <  DATEADD(day, r.LOOKAHEAD, r.REACT_TS)
  GROUP BY r.ACCOUNT_ID, r.REACT_TS, r.LAST_ACTIVE_TS, r.LOOKAHEAD, r.MIN_CREDIT
  HAVING SUM(IFF(t.DIRECTION = 'CREDIT', t.AMOUNT, 0)) >= r.MIN_CREDIT
),
best AS (
  SELECT * FROM agg
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID ORDER BY REACT_TS DESC) = 1
)
SELECT 'TM-DOR'                                   AS RULE_ID,
       a.CUSTOMER_ID,
       b.ACCOUNT_ID,
       b.REACT_TS::TIMESTAMP_NTZ                  AS WINDOW_START,
       b.END_TS::TIMESTAMP_NTZ                    AS WINDOW_END,
       b.CREDITS::NUMBER(18,2)                    AS AMOUNT_INR,
       b.N::INT                                   AS TXN_COUNT,
       b.TXNS                                     AS EVIDENCE_TXN_IDS,
       'Account inactive for at least ' || b.INACTIVE_DAYS || ' days, then received INR '
         || ROUND(b.CREDITS / 100000, 2) || ' lakh and paid out INR ' || ROUND(b.DEBITS / 100000, 2)
         || ' lakh within ' || b.LOOKAHEAD || ' days of reactivation.'
                                                  AS REASON,
       OBJECT_CONSTRUCT('inactive_days', b.INACTIVE_DAYS, 'last_active_ts', b.LAST_ACTIVE_TS,
                        'reactivated_ts', b.REACT_TS, 'credits', b.CREDITS, 'debits', b.DEBITS,
                        'account_status', a.STATUS) AS DETAIL
FROM best b
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = b.ACCOUNT_ID;

-- =============================================================================
-- TM-GEO | High-risk geography and round-tripping (Policy 4.5)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_GEO AS
WITH p AS (SELECT * FROM V_PARAMS),
hr AS (
  SELECT t.TXN_ID, t.ACCOUNT_ID, t.TXN_TS, t.DIRECTION, t.AMOUNT, t.COUNTERPARTY_COUNTRY, c.FATF_STATUS
  FROM CORE.TRANSACTIONS t
  JOIN CORE.COUNTRY_RISK c ON c.COUNTRY_CODE = t.COUNTERPARTY_COUNTRY
  WHERE c.RISK_LEVEL = 'HIGH'
),
roll AS (
  SELECT a.ACCOUNT_ID, a.TXN_ID, SUM(b.AMOUNT) AS AMT_WINDOW
  FROM hr a
  CROSS JOIN p
  JOIN hr b
    ON b.ACCOUNT_ID = a.ACCOUNT_ID
   AND b.TXN_TS <= a.TXN_TS
   AND b.TXN_TS >  DATEADD(day, -p.GEO_WINDOW_DAYS, a.TXN_TS)
  GROUP BY a.ACCOUNT_ID, a.TXN_ID
),
roll_max AS (
  SELECT ACCOUNT_ID, MAX(AMT_WINDOW) AS MAX_WINDOW_AMT FROM roll GROUP BY ACCOUNT_ID
),
rt AS (
  SELECT o.ACCOUNT_ID, COUNT(*) AS N_ROUND_TRIPS,
         ARRAY_AGG(o.COUNTERPARTY_COUNTRY || '->' || i.COUNTERPARTY_COUNTRY) AS RT_ROUTES
  FROM hr o
  CROSS JOIN p
  JOIN hr i
    ON i.ACCOUNT_ID = o.ACCOUNT_ID
   AND o.DIRECTION = 'DEBIT' AND i.DIRECTION = 'CREDIT'
   AND i.TXN_TS > o.TXN_TS
   AND i.TXN_TS <= DATEADD(day, p.GEO_RT_DAYS, o.TXN_TS)
   AND i.COUNTERPARTY_COUNTRY <> o.COUNTERPARTY_COUNTRY
   AND ABS(i.AMOUNT - o.AMOUNT) <= p.GEO_RT_TOLERANCE * o.AMOUNT
  GROUP BY o.ACCOUNT_ID
),
acct AS (
  SELECT ACCOUNT_ID, MIN(TXN_TS) AS WS, MAX(TXN_TS) AS WE, SUM(AMOUNT) AS TOTAL, COUNT(*) AS N,
         ARRAY_AGG(TXN_ID) WITHIN GROUP (ORDER BY TXN_TS) AS TXNS,
         COUNT_IF(FATF_STATUS = 'CALL_FOR_ACTION') AS N_CFA,
         LISTAGG(DISTINCT COUNTERPARTY_COUNTRY, ', ') WITHIN GROUP (ORDER BY COUNTERPARTY_COUNTRY) AS COUNTRIES
  FROM hr
  GROUP BY ACCOUNT_ID
)
SELECT 'TM-GEO'                                   AS RULE_ID,
       ac.CUSTOMER_ID,
       x.ACCOUNT_ID,
       x.WS::TIMESTAMP_NTZ                        AS WINDOW_START,
       x.WE::TIMESTAMP_NTZ                        AS WINDOW_END,
       x.TOTAL::NUMBER(18,2)                      AS AMOUNT_INR,
       x.N::INT                                   AS TXN_COUNT,
       x.TXNS                                     AS EVIDENCE_TXN_IDS,
       x.N || ' transactions worth INR ' || ROUND(x.TOTAL / 100000, 2)
         || ' lakh with high-risk jurisdictions (' || x.COUNTRIES || ').'
         || IFF(COALESCE(rt.N_ROUND_TRIPS, 0) > 0,
                ' ' || rt.N_ROUND_TRIPS || ' round-trip(s): money sent to one high-risk jurisdiction came back from another within '
                || p.GEO_RT_DAYS || ' days at a similar value.', '')
         || IFF(x.N_CFA > 0, ' ' || x.N_CFA || ' transaction(s) involve FATF call-for-action countries (same-day escalation).', '')
                                                  AS REASON,
       OBJECT_CONSTRUCT('countries', x.COUNTRIES, 'round_trips', COALESCE(rt.N_ROUND_TRIPS, 0),
                        'round_trip_routes', rt.RT_ROUTES, 'call_for_action_txns', x.N_CFA,
                        'max_window_amount', r.MAX_WINDOW_AMT) AS DETAIL
FROM acct x
CROSS JOIN p
JOIN CORE.ACCOUNTS ac ON ac.ACCOUNT_ID = x.ACCOUNT_ID
LEFT JOIN rt ON rt.ACCOUNT_ID = x.ACCOUNT_ID
LEFT JOIN roll_max r ON r.ACCOUNT_ID = x.ACCOUNT_ID
WHERE x.N_CFA > 0
   OR r.MAX_WINDOW_AMT >= p.GEO_MIN_AGG
   OR COALESCE(rt.N_ROUND_TRIPS, 0) > 0;

-- =============================================================================
-- TM-INC | Income / profile mismatch (Policy 4.6) - customer level
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_INC AS
WITH p AS (SELECT * FROM V_PARAMS),
mx AS (
  SELECT MAX(TXN_TS) AS MAX_TS FROM CORE.TRANSACTIONS
),
cr AS (
  SELECT a.CUSTOMER_ID, t.ACCOUNT_ID, t.TXN_ID, t.TXN_TS, t.AMOUNT
  FROM CORE.TRANSACTIONS t
  JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID
  CROSS JOIN mx
  CROSS JOIN p
  WHERE t.DIRECTION = 'CREDIT'
    AND t.TXN_TS > DATEADD(month, -p.INC_LOOKBACK_MONTHS, mx.MAX_TS)
),
ranked AS (
  SELECT cr.*, ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY AMOUNT DESC, TXN_ID) AS RN
  FROM cr
),
cust AS (
  SELECT CUSTOMER_ID, SUM(AMOUNT) AS TOTAL, COUNT(*) AS N, MIN(TXN_TS) AS WS, MAX(TXN_TS) AS WE,
         ARRAY_AGG(IFF(RN <= 25, TXN_ID, NULL)) WITHIN GROUP (ORDER BY AMOUNT DESC) AS TOP_TXNS
  FROM ranked
  GROUP BY CUSTOMER_ID
),
top_acct AS (
  SELECT CUSTOMER_ID, ACCOUNT_ID
  FROM (SELECT CUSTOMER_ID, ACCOUNT_ID, SUM(AMOUNT) AS AMT FROM cr GROUP BY CUSTOMER_ID, ACCOUNT_ID)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY AMT DESC, ACCOUNT_ID) = 1
)
SELECT 'TM-INC'                                   AS RULE_ID,
       c.CUSTOMER_ID,
       ta.ACCOUNT_ID,
       x.WS::TIMESTAMP_NTZ                        AS WINDOW_START,
       x.WE::TIMESTAMP_NTZ                        AS WINDOW_END,
       x.TOTAL::NUMBER(18,2)                      AS AMOUNT_INR,
       x.N::INT                                   AS TXN_COUNT,
       x.TOP_TXNS                                 AS EVIDENCE_TXN_IDS,
       'INR ' || ROUND(x.TOTAL / 100000, 2) || ' lakh credited in the last ' || p.INC_LOOKBACK_MONTHS
         || ' months against a declared annual income of INR ' || ROUND(c.DECLARED_ANNUAL_INCOME / 100000, 2)
         || ' lakh (' || c.OCCUPATION || ')'
         || IFF(c.DECLARED_ANNUAL_INCOME > 0,
                ', i.e. ' || ROUND(x.TOTAL / c.DECLARED_ANNUAL_INCOME, 1) || 'x the declared income.', '.')
                                                  AS REASON,
       OBJECT_CONSTRUCT('credits_12m', x.TOTAL, 'declared_income', c.DECLARED_ANNUAL_INCOME,
                        'occupation', c.OCCUPATION,
                        'multiple', IFF(c.DECLARED_ANNUAL_INCOME > 0,
                                        ROUND(x.TOTAL / c.DECLARED_ANNUAL_INCOME, 2), NULL)) AS DETAIL
FROM cust x
JOIN CORE.CUSTOMERS c ON c.CUSTOMER_ID = x.CUSTOMER_ID
JOIN top_acct ta ON ta.CUSTOMER_ID = x.CUSTOMER_ID
CROSS JOIN p
WHERE x.TOTAL >= p.INC_MIN_CREDITS
  AND x.TOTAL >  p.INC_MULTIPLIER * c.DECLARED_ANNUAL_INCOME;

-- =============================================================================
-- TM-RND | Round-amount transactions (Policy 4.7)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_RND AS
WITH p AS (SELECT * FROM V_PARAMS),
q AS (
  SELECT t.TXN_ID, t.ACCOUNT_ID, t.TXN_TS, t.AMOUNT, p.RND_WINDOW_DAYS AS WD, p.RND_MIN_COUNT AS MC
  FROM CORE.TRANSACTIONS t CROSS JOIN p
  WHERE t.AMOUNT >= p.RND_UNIT AND MOD(t.AMOUNT, p.RND_UNIT) = 0
),
win AS (
  SELECT a.ACCOUNT_ID, a.TXN_TS AS WINDOW_START, a.WD,
         MAX(b.TXN_TS) AS WINDOW_END, COUNT(*) AS N, SUM(b.AMOUNT) AS TOTAL,
         ARRAY_AGG(b.TXN_ID) WITHIN GROUP (ORDER BY b.TXN_TS) AS TXNS
  FROM q a
  JOIN q b
    ON b.ACCOUNT_ID = a.ACCOUNT_ID
   AND b.TXN_TS >= a.TXN_TS
   AND b.TXN_TS < DATEADD(day, a.WD, a.TXN_TS)
  GROUP BY a.ACCOUNT_ID, a.TXN_ID, a.TXN_TS, a.WD, a.MC
  HAVING COUNT(*) >= a.MC
),
best AS (
  SELECT * FROM win
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID ORDER BY N DESC, TOTAL DESC, WINDOW_START) = 1
)
SELECT 'TM-RND'                                   AS RULE_ID,
       a.CUSTOMER_ID,
       b.ACCOUNT_ID,
       b.WINDOW_START::TIMESTAMP_NTZ              AS WINDOW_START,
       b.WINDOW_END::TIMESTAMP_NTZ                AS WINDOW_END,
       b.TOTAL::NUMBER(18,2)                      AS AMOUNT_INR,
       b.N::INT                                   AS TXN_COUNT,
       b.TXNS                                     AS EVIDENCE_TXN_IDS,
       b.N || ' transactions in exact multiples of INR 1 lakh within ' || b.WD || ' days (total INR '
         || ROUND(b.TOTAL / 100000, 2) || ' lakh) with no documented commercial reason.'
                                                  AS REASON,
       OBJECT_CONSTRUCT('round_txns_in_window', b.N, 'window_days', b.WD) AS DETAIL
FROM best b
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = b.ACCOUNT_ID;

-- =============================================================================
-- TM-RIO | Rapid in-out / pass-through (Policy 4.8)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_TM_RIO AS
WITH p AS (SELECT * FROM V_PARAMS),
c AS (
  SELECT t.TXN_ID, t.ACCOUNT_ID, t.TXN_TS, t.AMOUNT, p.RIO_HOURS AS H, p.RIO_OUT_PCT AS PCT,
         p.RIO_SINGLE_PCT AS SINGLE_PCT
  FROM CORE.TRANSACTIONS t CROSS JOIN p
  WHERE t.DIRECTION = 'CREDIT' AND t.AMOUNT >= p.RIO_MIN_CREDIT
),
pairs AS (
  SELECT c.ACCOUNT_ID, c.TXN_ID AS CREDIT_ID, c.TXN_TS AS CREDIT_TS, c.AMOUNT AS CREDIT_AMT, c.PCT, c.SINGLE_PCT, c.H,
         d.TXN_ID AS DEBIT_ID, d.TXN_TS AS DEBIT_TS, d.AMOUNT AS DEBIT_AMT
  FROM c
  JOIN CORE.TRANSACTIONS d
    ON d.ACCOUNT_ID = c.ACCOUNT_ID
   AND d.DIRECTION = 'DEBIT'
   AND d.TXN_TS > c.TXN_TS
   AND d.TXN_TS <= DATEADD(hour, c.H, c.TXN_TS)
),
events AS (
  SELECT ACCOUNT_ID, CREDIT_ID, CREDIT_AMT, H, SUM(DEBIT_AMT) AS OUT_AMT
  FROM pairs
  GROUP BY ACCOUNT_ID, CREDIT_ID, CREDIT_AMT, PCT, SINGLE_PCT, H
  HAVING SUM(DEBIT_AMT) >= PCT * CREDIT_AMT          -- most of the money leaves ...
     AND MAX(DEBIT_AMT) >= SINGLE_PCT * CREDIT_AMT   -- ... largely in one onward payment
),
evid AS (
  SELECT p.ACCOUNT_ID, p.CREDIT_ID AS TXN_ID, p.CREDIT_TS AS TXN_TS
  FROM pairs p JOIN events e ON e.CREDIT_ID = p.CREDIT_ID
  UNION
  SELECT p.ACCOUNT_ID, p.DEBIT_ID, p.DEBIT_TS
  FROM pairs p JOIN events e ON e.CREDIT_ID = p.CREDIT_ID
),
ev_agg AS (
  SELECT ACCOUNT_ID, MIN(TXN_TS) AS WS, MAX(TXN_TS) AS WE, COUNT(*) AS N,
         ARRAY_AGG(TXN_ID) WITHIN GROUP (ORDER BY TXN_TS) AS TXNS
  FROM evid GROUP BY ACCOUNT_ID
),
out_debits AS (
  -- one debit can follow several credits; count it once
  SELECT DISTINCT p.ACCOUNT_ID, p.DEBIT_ID, p.DEBIT_AMT
  FROM pairs p JOIN events e ON e.CREDIT_ID = p.CREDIT_ID
),
amt AS (
  SELECT e.ACCOUNT_ID, COUNT(*) AS N_EVENTS, SUM(e.CREDIT_AMT) AS IN_AMT, MAX(e.H) AS H,
         ANY_VALUE(o.OUT_AMT) AS OUT_AMT
  FROM events e
  JOIN (SELECT ACCOUNT_ID, SUM(DEBIT_AMT) AS OUT_AMT FROM out_debits GROUP BY ACCOUNT_ID) o
    ON o.ACCOUNT_ID = e.ACCOUNT_ID
  GROUP BY e.ACCOUNT_ID
)
SELECT 'TM-RIO'                                   AS RULE_ID,
       a.CUSTOMER_ID,
       m.ACCOUNT_ID,
       v.WS::TIMESTAMP_NTZ                        AS WINDOW_START,
       v.WE::TIMESTAMP_NTZ                        AS WINDOW_END,
       m.IN_AMT::NUMBER(18,2)                     AS AMOUNT_INR,
       v.N::INT                                   AS TXN_COUNT,
       v.TXNS                                     AS EVIDENCE_TXN_IDS,
       m.N_EVENTS || ' large credit(s) totalling INR ' || ROUND(m.IN_AMT / 100000, 2)
         || ' lakh were passed on within ' || m.H || ' hours (INR ' || ROUND(m.OUT_AMT / 100000, 2)
         || ' lakh debited, mostly in a single onward payment), leaving the account as a pass-through.'
                                                  AS REASON,
       OBJECT_CONSTRUCT('pass_through_events', m.N_EVENTS, 'credited', m.IN_AMT, 'debited_within_window', m.OUT_AMT,
                        'hours', m.H) AS DETAIL
FROM amt m
JOIN ev_agg v ON v.ACCOUNT_ID = m.ACCOUNT_ID
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = m.ACCOUNT_ID;

-- =============================================================================
-- TM-NET | Mule rings (circular flows) and fan-in hubs (Policy 4.9)
-- =============================================================================

-- Every chain of internal transfers that returns to the account it started from.
CREATE OR REPLACE VIEW V_TRANSFER_CYCLES AS
WITH RECURSIVE paths (ORIGIN, CUR, START_TS, LAST_TS, HOPS, NODES, TXNS, CYCLE_DAYS, MAX_HOPS) AS (
  SELECT e.SRC_ACCOUNT_ID, e.DST_ACCOUNT_ID, e.TXN_TS, e.TXN_TS, 1,
         ARRAY_CONSTRUCT(e.SRC_ACCOUNT_ID, e.DST_ACCOUNT_ID), ARRAY_CONSTRUCT(e.TXN_ID),
         p.NET_CYCLE_DAYS, p.NET_CYCLE_MAX_HOPS
  FROM V_INTERNAL_TRANSFERS e
  CROSS JOIN V_PARAMS p
  UNION ALL
  SELECT pa.ORIGIN, e.DST_ACCOUNT_ID, pa.START_TS, e.TXN_TS, pa.HOPS + 1,
         ARRAY_APPEND(pa.NODES, e.DST_ACCOUNT_ID), ARRAY_APPEND(pa.TXNS, e.TXN_ID),
         pa.CYCLE_DAYS, pa.MAX_HOPS
  FROM paths pa
  JOIN V_INTERNAL_TRANSFERS e
    ON e.SRC_ACCOUNT_ID = pa.CUR
   AND e.TXN_TS > pa.LAST_TS                                   -- money moves forward in time
   AND e.TXN_TS <= DATEADD(day, pa.CYCLE_DAYS, pa.START_TS)
  WHERE pa.HOPS < pa.MAX_HOPS
    AND pa.CUR <> pa.ORIGIN
    AND (e.DST_ACCOUNT_ID = pa.ORIGIN OR NOT ARRAY_CONTAINS(e.DST_ACCOUNT_ID::VARIANT, pa.NODES))
)
SELECT pa.ORIGIN || '@' || TO_VARCHAR(pa.START_TS, 'YYYY-MM-DD HH24:MI:SS') AS CYCLE_KEY,
       pa.ORIGIN AS ORIGIN_ACCOUNT_ID, pa.HOPS, pa.START_TS, pa.LAST_TS AS END_TS, pa.NODES, pa.TXNS
FROM paths pa
CROSS JOIN V_PARAMS p
WHERE pa.CUR = pa.ORIGIN
  AND pa.HOPS >= p.NET_CYCLE_MIN_HOPS;

CREATE OR REPLACE VIEW RULE_TM_NET AS
WITH p AS (SELECT * FROM V_PARAMS),
-- (a) circular flows -------------------------------------------------------
members AS (
  SELECT DISTINCT c.CYCLE_KEY, f.VALUE::STRING AS ACCOUNT_ID
  FROM V_TRANSFER_CYCLES c, LATERAL FLATTEN(input => c.NODES) f
),
cyc_txns AS (
  SELECT DISTINCT c.CYCLE_KEY, f.VALUE::STRING AS TXN_ID
  FROM V_TRANSFER_CYCLES c, LATERAL FLATTEN(input => c.TXNS) f
),
cyc_acct AS (
  SELECT m.ACCOUNT_ID,
         COUNT(DISTINCT m.CYCLE_KEY) AS N_CYCLES,
         MIN(c.START_TS) AS WS, MAX(c.END_TS) AS WE,
         MAX(c.HOPS) AS MAX_HOPS
  FROM members m
  JOIN V_TRANSFER_CYCLES c ON c.CYCLE_KEY = m.CYCLE_KEY
  GROUP BY m.ACCOUNT_ID
),
cyc_partners AS (
  SELECT m.ACCOUNT_ID,
         LISTAGG(DISTINCT o.ACCOUNT_ID, ', ') WITHIN GROUP (ORDER BY o.ACCOUNT_ID) AS PARTNERS
  FROM members m
  JOIN members o ON o.CYCLE_KEY = m.CYCLE_KEY AND o.ACCOUNT_ID <> m.ACCOUNT_ID
  GROUP BY m.ACCOUNT_ID
),
cyc_evid AS (
  SELECT DISTINCT m.ACCOUNT_ID, t.TXN_ID, t.TXN_TS, t.AMOUNT
  FROM members m
  JOIN cyc_txns x ON x.CYCLE_KEY = m.CYCLE_KEY
  JOIN CORE.TRANSACTIONS t ON t.TXN_ID = x.TXN_ID
),
-- (b) fan-in hubs ------------------------------------------------------------
fin AS (
  SELECT TXN_ID, ACCOUNT_ID, TXN_TS, AMOUNT,
         COALESCE(COUNTERPARTY_ACCOUNT_ID, COUNTERPARTY_NAME) AS SENDER
  FROM CORE.TRANSACTIONS
  WHERE DIRECTION = 'CREDIT' AND CHANNEL <> 'CASH'
    AND COALESCE(COUNTERPARTY_ACCOUNT_ID, COUNTERPARTY_NAME) IS NOT NULL
    AND COALESCE(DESCRIPTION, '') <> 'Salary credit'
),
fwin AS (
  SELECT a.ACCOUNT_ID, a.TXN_ID AS ANCHOR, a.TXN_TS AS WS,
         MAX(b.TXN_TS) AS WE, COUNT(DISTINCT b.SENDER) AS N_SENDERS, SUM(b.AMOUNT) AS AMT_IN,
         ARRAY_AGG(b.TXN_ID) WITHIN GROUP (ORDER BY b.TXN_TS) AS IN_TXNS
  FROM fin a
  CROSS JOIN p
  JOIN fin b
    ON b.ACCOUNT_ID = a.ACCOUNT_ID
   AND b.TXN_TS >= a.TXN_TS
   AND b.TXN_TS <  DATEADD(day, p.NET_FANIN_DAYS, a.TXN_TS)
  GROUP BY a.ACCOUNT_ID, a.TXN_ID, a.TXN_TS, p.NET_FANIN_MIN_SENDERS
  HAVING COUNT(DISTINCT b.SENDER) >= p.NET_FANIN_MIN_SENDERS
),
fbest AS (
  SELECT * FROM fwin
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID ORDER BY N_SENDERS DESC, AMT_IN DESC, WS) = 1
),
fout AS (
  SELECT f.ACCOUNT_ID, SUM(d.AMOUNT) AS AMT_OUT, MAX(d.TXN_TS) AS LAST_OUT_TS,
         ARRAY_AGG(d.TXN_ID) WITHIN GROUP (ORDER BY d.TXN_TS) AS OUT_TXNS,
         LISTAGG(DISTINCT d.COUNTERPARTY_NAME || ' (' || d.COUNTERPARTY_COUNTRY || ')', '; ')
           WITHIN GROUP (ORDER BY d.COUNTERPARTY_NAME || ' (' || d.COUNTERPARTY_COUNTRY || ')') AS OUT_TO
  FROM fbest f
  CROSS JOIN p
  JOIN CORE.TRANSACTIONS d
    ON d.ACCOUNT_ID = f.ACCOUNT_ID
   AND d.DIRECTION = 'DEBIT'
   AND d.TXN_TS >= f.WS
   AND d.TXN_TS <= DATEADD(day, p.NET_FANIN_DAYS, f.WE)
  GROUP BY f.ACCOUNT_ID
),
fan AS (
  SELECT f.ACCOUNT_ID, f.WS, GREATEST(f.WE, o.LAST_OUT_TS) AS WE, f.N_SENDERS, f.AMT_IN, o.AMT_OUT, o.OUT_TO,
         ARRAY_CAT(f.IN_TXNS, o.OUT_TXNS) AS TXNS
  FROM fbest f
  JOIN fout o ON o.ACCOUNT_ID = f.ACCOUNT_ID
  CROSS JOIN p
  WHERE o.AMT_OUT >= p.NET_FANIN_OUT_PCT * f.AMT_IN
),
-- combine ---------------------------------------------------------------------
accts AS (
  SELECT ACCOUNT_ID FROM cyc_acct
  UNION
  SELECT ACCOUNT_ID FROM fan
),
cyc_agg AS (
  SELECT ACCOUNT_ID, COUNT(*) AS N, SUM(AMOUNT) AS AMT,
         ARRAY_AGG(TXN_ID) WITHIN GROUP (ORDER BY TXN_TS) AS TXNS
  FROM cyc_evid GROUP BY ACCOUNT_ID
)
SELECT 'TM-NET'                                   AS RULE_ID,
       a.CUSTOMER_ID,
       x.ACCOUNT_ID,
       LEAST(COALESCE(ca.WS, f.WS), COALESCE(f.WS, ca.WS))::TIMESTAMP_NTZ  AS WINDOW_START,
       GREATEST(COALESCE(ca.WE, f.WE), COALESCE(f.WE, ca.WE))::TIMESTAMP_NTZ AS WINDOW_END,
       (COALESCE(cg.AMT, 0) + COALESCE(f.AMT_IN, 0))::NUMBER(18,2) AS AMOUNT_INR,
       (COALESCE(cg.N, 0) + COALESCE(ARRAY_SIZE(f.TXNS), 0))::INT  AS TXN_COUNT,
       ARRAY_CAT(COALESCE(cg.TXNS, ARRAY_CONSTRUCT()), COALESCE(f.TXNS, ARRAY_CONSTRUCT())) AS EVIDENCE_TXN_IDS,
       TRIM(
         IFF(ca.ACCOUNT_ID IS NOT NULL,
             'Part of ' || ca.N_CYCLES || ' circular transfer chain(s) of up to ' || ca.MAX_HOPS
             || ' hops with ' || cp.PARTNERS || '; funds returned to the originating account within '
             || p.NET_CYCLE_DAYS || ' days. ', '')
         || IFF(f.ACCOUNT_ID IS NOT NULL,
             'Fan-in hub: ' || f.N_SENDERS || ' different senders paid in INR ' || ROUND(f.AMT_IN / 100000, 2)
             || ' lakh within ' || p.NET_FANIN_DAYS || ' days and INR ' || ROUND(f.AMT_OUT / 100000, 2)
             || ' lakh was sent on to ' || COALESCE(f.OUT_TO, 'other parties') || '.', '')
       )                                          AS REASON,
       OBJECT_CONSTRUCT('pattern', IFF(ca.ACCOUNT_ID IS NOT NULL AND f.ACCOUNT_ID IS NOT NULL, 'CYCLE+FAN_IN',
                                       IFF(ca.ACCOUNT_ID IS NOT NULL, 'CYCLE', 'FAN_IN')),
                        'cycles', ca.N_CYCLES, 'ring_partners', cp.PARTNERS,
                        'fan_in_senders', f.N_SENDERS, 'fan_in_amount', f.AMT_IN,
                        'fan_out_amount', f.AMT_OUT, 'fan_out_to', f.OUT_TO) AS DETAIL
FROM accts x
CROSS JOIN p
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = x.ACCOUNT_ID
LEFT JOIN cyc_acct ca ON ca.ACCOUNT_ID = x.ACCOUNT_ID
LEFT JOIN cyc_partners cp ON cp.ACCOUNT_ID = x.ACCOUNT_ID
LEFT JOIN cyc_agg cg ON cg.ACCOUNT_ID = x.ACCOUNT_ID
LEFT JOIN fan f ON f.ACCOUNT_ID = x.ACCOUNT_ID;
