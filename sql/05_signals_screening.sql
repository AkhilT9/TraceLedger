-- =============================================================================
-- TraceLedger | Layer 2 | 05_signals_screening.sql
-- Sanctions / watchlist fuzzy screening (customers and counterparties),
-- PEP review rule and adverse-media linking.
-- Names are normalised (upper case, punctuation removed). MATCH_SCORE (0-100)
-- is the average of JAROWINKLER_SIMILARITY and the edit-distance similarity.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA SIGNALS;

-- Every listed name and alias, one row each.
CREATE OR REPLACE VIEW V_WATCHLIST_NAMES AS
SELECT s.SANCTION_ID, s.LISTED_NAME, s.ENTITY_TYPE, s.COUNTRY, s.PROGRAM, s.LIST_SOURCE,
       s.DATE_OF_BIRTH, s.LISTED_NAME AS NAME_VARIANT, 'PRIMARY' AS NAME_TYPE,
       TRIM(REGEXP_REPLACE(UPPER(s.LISTED_NAME), '[^A-Z]+', ' ')) AS NORM_NAME
FROM CORE.SANCTIONS_LIST s
UNION ALL
SELECT s.SANCTION_ID, s.LISTED_NAME, s.ENTITY_TYPE, s.COUNTRY, s.PROGRAM, s.LIST_SOURCE,
       s.DATE_OF_BIRTH, TRIM(f.VALUE) AS NAME_VARIANT, 'ALIAS' AS NAME_TYPE,
       TRIM(REGEXP_REPLACE(UPPER(TRIM(f.VALUE)), '[^A-Z]+', ' ')) AS NORM_NAME
FROM CORE.SANCTIONS_LIST s, LATERAL SPLIT_TO_TABLE(s.ALIASES, ';') f
WHERE TRIM(f.VALUE) <> '';

-- Best watchlist match per customer (only matches at or above the near-match score).
CREATE OR REPLACE VIEW V_SCREENING_CUSTOMERS AS
WITH p AS (SELECT * FROM V_PARAMS),
c AS (
  SELECT CUSTOMER_ID, FULL_NAME, CUSTOMER_TYPE, DATE_OF_BIRTH, NATIONALITY,
         TRIM(REGEXP_REPLACE(UPPER(FULL_NAME), '[^A-Z]+', ' ')) AS NORM_NAME
  FROM CORE.CUSTOMERS
),
m AS (
  SELECT c.CUSTOMER_ID, c.FULL_NAME, c.CUSTOMER_TYPE, c.DATE_OF_BIRTH AS CUSTOMER_DOB, c.NATIONALITY,
         w.SANCTION_ID, w.LISTED_NAME, w.NAME_VARIANT, w.NAME_TYPE, w.PROGRAM, w.LIST_SOURCE,
         w.COUNTRY AS LISTED_COUNTRY, w.DATE_OF_BIRTH AS LISTED_DOB,
         JAROWINKLER_SIMILARITY(c.NORM_NAME, w.NORM_NAME) AS JW_SCORE,
         EDITDISTANCE(c.NORM_NAME, w.NORM_NAME) AS EDIT_DISTANCE,
         -- blended score: Jaro-Winkler alone over-rewards shared suffixes ("... Logistics")
         ROUND((JAROWINKLER_SIMILARITY(c.NORM_NAME, w.NORM_NAME)
                + 100 * (1 - EDITDISTANCE(c.NORM_NAME, w.NORM_NAME)
                             / GREATEST(LENGTH(c.NORM_NAME), LENGTH(w.NORM_NAME)))) / 2) AS MATCH_SCORE
  FROM c
  JOIN V_WATCHLIST_NAMES w ON w.ENTITY_TYPE = c.CUSTOMER_TYPE
)
SELECT m.*,
       COALESCE(m.CUSTOMER_DOB = m.LISTED_DOB, FALSE)  AS DOB_MATCH,
       COALESCE(m.NATIONALITY = m.LISTED_COUNTRY, FALSE) AS COUNTRY_MATCH,
       IFF(m.MATCH_SCORE >= p.SAN_TRUE_MATCH OR COALESCE(m.CUSTOMER_DOB = m.LISTED_DOB, FALSE),
           'POTENTIAL_TRUE_MATCH', 'NEAR_MATCH') AS MATCH_TYPE
FROM m CROSS JOIN p
WHERE m.MATCH_SCORE >= p.SAN_NEAR_MATCH
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.CUSTOMER_ID ORDER BY m.MATCH_SCORE DESC, m.EDIT_DISTANCE, m.SANCTION_ID) = 1;

-- Best watchlist match per external counterparty name, with the transactions that touched it.
CREATE OR REPLACE VIEW V_SCREENING_COUNTERPARTIES AS
WITH p AS (SELECT * FROM V_PARAMS),
cp AS (
  SELECT DISTINCT COUNTERPARTY_NAME,
         TRIM(REGEXP_REPLACE(UPPER(COUNTERPARTY_NAME), '[^A-Z]+', ' ')) AS NORM_NAME
  FROM CORE.TRANSACTIONS
  WHERE COUNTERPARTY_ACCOUNT_ID IS NULL
    AND COUNTERPARTY_NAME IS NOT NULL
    AND CHANNEL IN ('SWIFT', 'RTGS', 'NEFT', 'IMPS')
),
m AS (
  SELECT cp.COUNTERPARTY_NAME, w.SANCTION_ID, w.LISTED_NAME, w.NAME_VARIANT, w.PROGRAM, w.LIST_SOURCE,
         w.COUNTRY AS LISTED_COUNTRY,
         JAROWINKLER_SIMILARITY(cp.NORM_NAME, w.NORM_NAME) AS JW_SCORE,
         EDITDISTANCE(cp.NORM_NAME, w.NORM_NAME) AS EDIT_DISTANCE,
         ROUND((JAROWINKLER_SIMILARITY(cp.NORM_NAME, w.NORM_NAME)
                + 100 * (1 - EDITDISTANCE(cp.NORM_NAME, w.NORM_NAME)
                             / GREATEST(LENGTH(cp.NORM_NAME), LENGTH(w.NORM_NAME)))) / 2) AS MATCH_SCORE
  FROM cp CROSS JOIN V_WATCHLIST_NAMES w
),
best AS (
  SELECT m.*, IFF(m.MATCH_SCORE >= p.SAN_TRUE_MATCH, 'POTENTIAL_TRUE_MATCH', 'NEAR_MATCH') AS MATCH_TYPE
  FROM m CROSS JOIN p
  WHERE m.MATCH_SCORE >= p.SAN_NEAR_MATCH
  QUALIFY ROW_NUMBER() OVER (PARTITION BY m.COUNTERPARTY_NAME ORDER BY m.MATCH_SCORE DESC, m.EDIT_DISTANCE) = 1
)
SELECT t.TXN_ID, t.ACCOUNT_ID, a.CUSTOMER_ID, t.TXN_TS, t.DIRECTION, t.AMOUNT, t.CHANNEL,
       t.COUNTERPARTY_COUNTRY, b.*
FROM best b
JOIN CORE.TRANSACTIONS t ON t.COUNTERPARTY_NAME = b.COUNTERPARTY_NAME AND t.COUNTERPARTY_ACCOUNT_ID IS NULL
JOIN CORE.ACCOUNTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID;

-- =============================================================================
-- SCR-SAN | Sanctions / watchlist match (Policy 5.2 and 5.4)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_SCR_SAN AS
WITH hits AS (
  -- customer itself resembles a listed party -> flagged on the customer's main account
  SELECT pa.ACCOUNT_ID, s.CUSTOMER_ID, 'CUSTOMER' AS HIT_ON, s.FULL_NAME AS SCREENED_NAME,
         s.LISTED_NAME, s.PROGRAM, s.MATCH_SCORE, s.MATCH_TYPE, s.DOB_MATCH,
         NULL AS TXN_ID, NULL::TIMESTAMP_NTZ AS TXN_TS, NULL::NUMBER(18,2) AS AMOUNT
  FROM V_SCREENING_CUSTOMERS s
  JOIN V_PRIMARY_ACCOUNT pa ON pa.CUSTOMER_ID = s.CUSTOMER_ID
  UNION ALL
  -- account paid / was paid by a party that resembles a listed party
  SELECT k.ACCOUNT_ID, k.CUSTOMER_ID, 'COUNTERPARTY', k.COUNTERPARTY_NAME,
         k.LISTED_NAME, k.PROGRAM, k.MATCH_SCORE, k.MATCH_TYPE, NULL,
         k.TXN_ID, k.TXN_TS, k.AMOUNT
  FROM V_SCREENING_COUNTERPARTIES k
),
agg AS (
  SELECT ACCOUNT_ID, ANY_VALUE(CUSTOMER_ID) AS CUSTOMER_ID,
         MAX(MATCH_SCORE) AS BEST_SCORE,
         MAX(IFF(MATCH_TYPE = 'POTENTIAL_TRUE_MATCH', 1, 0)) AS ANY_TRUE,
         MIN(TXN_TS) AS WS, MAX(TXN_TS) AS WE,
         SUM(COALESCE(AMOUNT, 0)) AS AMT,
         COUNT(TXN_ID) AS N_TXNS,
         ARRAY_AGG(TXN_ID) WITHIN GROUP (ORDER BY TXN_TS) AS TXNS,
         LISTAGG(DISTINCT HIT_ON || ' "' || SCREENED_NAME || '" resembles listed "' || LISTED_NAME
                 || '" (' || PROGRAM || ', score ' || MATCH_SCORE || ')', '; ')
           WITHIN GROUP (ORDER BY HIT_ON || ' "' || SCREENED_NAME || '" resembles listed "' || LISTED_NAME
                 || '" (' || PROGRAM || ', score ' || MATCH_SCORE || ')') AS MATCHES,
         ARRAY_AGG(DISTINCT HIT_ON) AS HIT_TYPES
  FROM hits
  GROUP BY ACCOUNT_ID
)
SELECT 'SCR-SAN'                                  AS RULE_ID,
       x.CUSTOMER_ID,
       x.ACCOUNT_ID,
       COALESCE(x.WS, c.KYC_LAST_REVIEWED::TIMESTAMP_NTZ)::TIMESTAMP_NTZ AS WINDOW_START,
       COALESCE(x.WE, c.KYC_LAST_REVIEWED::TIMESTAMP_NTZ)::TIMESTAMP_NTZ AS WINDOW_END,
       x.AMT::NUMBER(18,2)                        AS AMOUNT_INR,
       x.N_TXNS::INT                              AS TXN_COUNT,
       x.TXNS                                     AS EVIDENCE_TXN_IDS,
       IFF(x.ANY_TRUE = 1, 'Potential true match: ', 'Near match: ') || x.MATCHES || '.'
         || IFF(x.N_TXNS > 0, ' ' || x.N_TXNS || ' transaction(s) worth INR ' || ROUND(x.AMT / 100000, 2)
                || ' lakh with the matched counterparty.', '')
                                                  AS REASON,
       OBJECT_CONSTRUCT('match_type', IFF(x.ANY_TRUE = 1, 'POTENTIAL_TRUE_MATCH', 'NEAR_MATCH'),
                        'best_score', x.BEST_SCORE, 'hit_on', x.HIT_TYPES) AS DETAIL
FROM agg x
JOIN CORE.CUSTOMERS c ON c.CUSTOMER_ID = x.CUSTOMER_ID;

-- =============================================================================
-- SCR-PEP | PEP receiving large third-party credits (Policy 3.4)
-- =============================================================================
CREATE OR REPLACE VIEW RULE_SCR_PEP AS
WITH p AS (SELECT * FROM V_PARAMS),
cr AS (
  SELECT c.CUSTOMER_ID, t.ACCOUNT_ID, t.TXN_ID, t.TXN_TS, t.AMOUNT, t.COUNTERPARTY_NAME
  FROM CORE.CUSTOMERS c
  JOIN CORE.ACCOUNTS a ON a.CUSTOMER_ID = c.CUSTOMER_ID
  JOIN CORE.TRANSACTIONS t ON t.ACCOUNT_ID = a.ACCOUNT_ID
  CROSS JOIN p
  WHERE c.PEP_FLAG
    AND t.DIRECTION = 'CREDIT'
    AND t.AMOUNT >= p.PEP_MIN_CREDIT
    AND t.COUNTERPARTY_NAME IS NOT NULL
    AND COALESCE(t.DESCRIPTION, '') <> 'Salary credit'
)
SELECT 'SCR-PEP'                                  AS RULE_ID,
       CUSTOMER_ID,
       ACCOUNT_ID,
       MIN(TXN_TS)::TIMESTAMP_NTZ                 AS WINDOW_START,
       MAX(TXN_TS)::TIMESTAMP_NTZ                 AS WINDOW_END,
       SUM(AMOUNT)::NUMBER(18,2)                  AS AMOUNT_INR,
       COUNT(*)::INT                              AS TXN_COUNT,
       ARRAY_AGG(TXN_ID) WITHIN GROUP (ORDER BY TXN_TS) AS EVIDENCE_TXN_IDS,
       'Politically exposed person received ' || COUNT(*) || ' third-party credit(s) of INR 10 lakh or more (total INR '
         || ROUND(SUM(AMOUNT) / 100000, 2) || ' lakh) from '
         || LISTAGG(DISTINCT COUNTERPARTY_NAME, ', ') WITHIN GROUP (ORDER BY COUNTERPARTY_NAME)
         || '. Source of funds must be verified (EDD).'
                                                  AS REASON,
       OBJECT_CONSTRUCT('payers', LISTAGG(DISTINCT COUNTERPARTY_NAME, ', ') WITHIN GROUP (ORDER BY COUNTERPARTY_NAME))
                                                  AS DETAIL
FROM cr
GROUP BY CUSTOMER_ID, ACCOUNT_ID;

-- =============================================================================
-- ADV-MED | Adverse media linked to the customer (Policy 4.10)
-- Layer 3 enriches the articles with Cortex AI_SENTIMENT / AI_CLASSIFY; here
-- the article's negative tag and a strict name match are used.
-- =============================================================================
CREATE OR REPLACE VIEW V_ADVERSE_MEDIA_MATCHES AS
WITH p AS (SELECT * FROM V_PARAMS),
pairs AS (
  SELECT c.CUSTOMER_ID, m.ARTICLE_ID, m.PUBLISHED_DATE, m.SOURCE, m.HEADLINE, m.MENTIONED_NAME,
         TRIM(REGEXP_REPLACE(UPPER(c.FULL_NAME), '[^A-Z]+', ' '))      AS A,
         TRIM(REGEXP_REPLACE(UPPER(m.MENTIONED_NAME), '[^A-Z]+', ' ')) AS B
  FROM CORE.CUSTOMERS c
  JOIN DOCS.ADVERSE_MEDIA m ON m.SENTIMENT_HINT = 'NEGATIVE'
),
scored AS (
  SELECT pairs.*,
         ROUND((JAROWINKLER_SIMILARITY(A, B)
                + 100 * (1 - EDITDISTANCE(A, B) / GREATEST(LENGTH(A), LENGTH(B)))) / 2) AS NAME_SCORE
  FROM pairs
)
SELECT s.CUSTOMER_ID, s.ARTICLE_ID, s.PUBLISHED_DATE, s.SOURCE, s.HEADLINE, s.MENTIONED_NAME, s.NAME_SCORE
FROM scored s CROSS JOIN p
WHERE s.NAME_SCORE >= p.ADV_NAME_MATCH;

CREATE OR REPLACE VIEW RULE_ADV_MED AS
SELECT 'ADV-MED'                                  AS RULE_ID,
       m.CUSTOMER_ID,
       pa.ACCOUNT_ID,
       MIN(m.PUBLISHED_DATE)::TIMESTAMP_NTZ       AS WINDOW_START,
       MAX(m.PUBLISHED_DATE)::TIMESTAMP_NTZ       AS WINDOW_END,
       0::NUMBER(18,2)                            AS AMOUNT_INR,
       0::INT                                     AS TXN_COUNT,
       ARRAY_CONSTRUCT()                          AS EVIDENCE_TXN_IDS,
       COUNT(*) || ' negative news article(s): '
         || LISTAGG('"' || m.HEADLINE || '" (' || m.SOURCE || ', ' || m.PUBLISHED_DATE || ', ' || m.ARTICLE_ID || ')', '; ')
              WITHIN GROUP (ORDER BY m.PUBLISHED_DATE DESC)
         || '.'                                   AS REASON,
       OBJECT_CONSTRUCT('article_ids', ARRAY_AGG(m.ARTICLE_ID) WITHIN GROUP (ORDER BY m.PUBLISHED_DATE DESC),
                        'best_name_score', MAX(m.NAME_SCORE)) AS DETAIL
FROM V_ADVERSE_MEDIA_MATCHES m
JOIN V_PRIMARY_ACCOUNT pa ON pa.CUSTOMER_ID = m.CUSTOMER_ID
GROUP BY m.CUSTOMER_ID, pa.ACCOUNT_ID;
