-- =============================================================================
-- TraceLedger | Layer 3 | 09_docs_ai_search.sql
-- Unstructured data -> AI -> search:
--   1. AI_PARSE_DOCUMENT reads the policy PDFs page by page
--   2. Pages are split into clause-level chunks that keep doc / section / clause / page
--   3. Cortex AI tags analyst notes and adverse media (sentiment + AI_CLASSIFY)
--   4. Three Cortex Search services: policies, analyst notes, adverse media
-- Takes ~2-4 minutes (the AI functions run once per document / note / article).
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA DOCS;

-- -----------------------------------------------------------------------------
-- Document register (title / version shown in every citation)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE DOC_REGISTRY (
  DOC_ID          VARCHAR(20) PRIMARY KEY,
  DOC_TITLE       VARCHAR(200),
  DOC_VERSION     VARCHAR(10),
  EFFECTIVE_DATE  DATE,
  OWNER           VARCHAR(60)
) COMMENT = 'Governed policy documents indexed for the copilot';

INSERT INTO DOC_REGISTRY VALUES
 ('TL-AML-POL-001',  'AML & CFT Policy',                                '4.3', '2026-10-01', 'Principal Officer, Compliance'),
 ('TL-REG-GUI-002',  'Regulatory Guidance Summary - FATF, RBI KYC, PMLA','2.0', '2026-03-15', 'Compliance Advisory'),
 ('TL-RSK-NOTE-003', 'Basel III, Credit Risk and Liquidity Note',       '1.3', '2026-01-10', 'Chief Risk Officer');

-- -----------------------------------------------------------------------------
-- 1. Parse every PDF on the stage, one row per page
-- -----------------------------------------------------------------------------
ALTER STAGE POLICY_STAGE REFRESH;

CREATE OR REPLACE TABLE POLICY_PAGES AS
WITH parsed AS (
  SELECT RELATIVE_PATH AS FILE_NAME,
         AI_PARSE_DOCUMENT(
           TO_FILE('@TRACELEDGER.DOCS.POLICY_STAGE', RELATIVE_PATH),
           {'mode': 'LAYOUT', 'page_split': true}
         ) AS PARSED
  FROM DIRECTORY(@TRACELEDGER.DOCS.POLICY_STAGE)
  WHERE RELATIVE_PATH ILIKE '%.pdf'
)
SELECT FILE_NAME,
       SPLIT_PART(FILE_NAME, '_', 1)       AS DOC_ID,
       pg.value:index::INT + 1             AS PAGE_NO,
       pg.value:content::STRING            AS PAGE_TEXT
FROM parsed, LATERAL FLATTEN(input => parsed.PARSED:pages) pg;

SELECT DOC_ID, COUNT(*) AS PAGES, SUM(LENGTH(PAGE_TEXT)) AS CHARS FROM POLICY_PAGES GROUP BY DOC_ID ORDER BY DOC_ID;

-- -----------------------------------------------------------------------------
-- 2. Clause-level chunks with section / clause / page for citations
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE POLICY_CHUNKS AS
WITH paras AS (
  -- one paragraph per clause in these documents
  SELECT p.DOC_ID, p.FILE_NAME, p.PAGE_NO, s.INDEX AS PARA_NO, TRIM(s.VALUE) AS PARA
  FROM POLICY_PAGES p, LATERAL SPLIT_TO_TABLE(p.PAGE_TEXT, '\n\n') s
  WHERE TRIM(s.VALUE) <> ''
),
pieces AS (
  -- long paragraphs (or pages without blank lines) are split further
  SELECT pa.DOC_ID, pa.FILE_NAME, pa.PAGE_NO, pa.PARA_NO, c.INDEX AS SUB_NO, TRIM(c.VALUE::STRING) AS PIECE
  FROM paras pa,
       LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(pa.PARA, 'markdown', 900, 0)) c
),
tagged AS (
  SELECT pieces.*,
         -- "## 4. Transaction Monitoring and Red Flags" -> section 4
         REGEXP_SUBSTR(PIECE, '^#*\\s*([0-9]+)\\.\\s+[A-Z]', 1, 1, 'e', 1)                AS HEAD_NO,
         REGEXP_SUBSTR(PIECE, '^#*\\s*[0-9]+\\.\\s+([^\\n]+)', 1, 1, 'e', 1)              AS HEAD_TITLE,
         -- "4.2 Structuring (Rule ID: TM-STR). ..." -> clause 4.2 (first clause starting a line)
         REGEXP_SUBSTR(PIECE, '(^|\\n)[*# ]*([0-9]+\\.[0-9]+)\\s', 1, 1, 'em', 2)     AS CLAUSE_START
  FROM pieces
),
ctx AS (
  SELECT tagged.*,
         LAST_VALUE(HEAD_NO IGNORE NULLS) OVER (PARTITION BY DOC_ID ORDER BY PAGE_NO, PARA_NO, SUB_NO
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                            AS SECTION_NO,
         LAST_VALUE(HEAD_TITLE IGNORE NULLS) OVER (PARTITION BY DOC_ID ORDER BY PAGE_NO, PARA_NO, SUB_NO
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                            AS SECTION_TITLE,
         LAST_VALUE(CLAUSE_START IGNORE NULLS) OVER (PARTITION BY DOC_ID ORDER BY PAGE_NO, PARA_NO, SUB_NO
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                            AS LAST_CLAUSE
  FROM tagged
),
final AS (
  SELECT ctx.*,
         -- a clause applies until the next clause or section starts
         IFF(LAST_CLAUSE IS NOT NULL AND SPLIT_PART(LAST_CLAUSE, '.', 1) = SECTION_NO, LAST_CLAUSE, NULL) AS CLAUSE_NO
  FROM ctx
)
SELECT f.DOC_ID || '-P' || f.PAGE_NO || '-' || LPAD(f.PARA_NO, 3, '0') || '-' || f.SUB_NO   AS CHUNK_ID,
       f.DOC_ID,
       r.DOC_TITLE,
       r.DOC_VERSION,
       f.FILE_NAME,
       f.PAGE_NO,
       f.SECTION_NO,
       f.SECTION_TITLE,
       f.CLAUSE_NO,
       f.DOC_ID || ' v' || r.DOC_VERSION
         || COALESCE(' section ' || COALESCE(f.CLAUSE_NO, f.SECTION_NO), '')
         || ', page ' || f.PAGE_NO                                                       AS CITATION,
       r.DOC_TITLE || ' | ' || COALESCE('Section ' || f.SECTION_NO || ' ' || f.SECTION_TITLE || ' | ', '')
         || f.PIECE                                                                      AS CHUNK_TEXT
FROM final f
JOIN DOC_REGISTRY r ON r.DOC_ID = f.DOC_ID
WHERE NOT (f.HEAD_NO IS NOT NULL AND LENGTH(f.PIECE) < 120)   -- a bare heading is context, not a chunk
  AND LENGTH(f.PIECE) > 40
  AND NOT REGEXP_LIKE(f.PIECE, '^(TraceLedger Bank \\||Page [0-9]+).*', 's');

SELECT DOC_ID, COUNT(*) AS CHUNKS, COUNT(CLAUSE_NO) AS WITH_CLAUSE FROM POLICY_CHUNKS GROUP BY DOC_ID ORDER BY DOC_ID;
SELECT CITATION, LEFT(CHUNK_TEXT, 160) AS PREVIEW FROM POLICY_CHUNKS WHERE CLAUSE_NO = '4.2';

-- -----------------------------------------------------------------------------
-- 3. AI enrichment of analyst notes and adverse media
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ANALYST_NOTES_ENRICHED AS
WITH ai AS (
  SELECT n.*,
         SNOWFLAKE.CORTEX.SENTIMENT(n.NOTE_TEXT) AS SENTIMENT_SCORE,
         AI_CLASSIFY(n.NOTE_TEXT, [
           'Evasive or no source of funds',
           'Possible money mule or third-party use of account',
           'Sanctions, PEP or corruption concern',
           'Customer cooperative, documents provided',
           'Routine service request'
         ]) AS CLS
  FROM ANALYST_NOTES n
)
SELECT NOTE_ID, CUSTOMER_ID, NOTE_DATE, AUTHOR, NOTE_TYPE, NOTE_TEXT,
       ROUND(SENTIMENT_SCORE, 3)                              AS SENTIMENT_SCORE,
       COALESCE(CLS:labels[0]::STRING, CLS:label::STRING)     AS RISK_TAG,
       IFF(COALESCE(CLS:labels[0]::STRING, CLS:label::STRING)
             IN ('Customer cooperative, documents provided', 'Routine service request'), FALSE, TRUE) AS IS_RED_FLAG
FROM ai;

CREATE OR REPLACE TABLE ADVERSE_MEDIA_ENRICHED AS
WITH ai AS (
  SELECT m.*,
         SNOWFLAKE.CORTEX.SENTIMENT(m.HEADLINE || '. ' || m.BODY) AS SENTIMENT_SCORE,
         AI_CLASSIFY(m.HEADLINE || '. ' || m.BODY, [
           'Money laundering or hawala',
           'Fraud or cyber crime',
           'Tax evasion or fake invoicing',
           'Bribery or corruption',
           'Sanctions designation',
           'Positive or neutral business news'
         ]) AS CLS
  FROM ADVERSE_MEDIA m
)
SELECT ARTICLE_ID, PUBLISHED_DATE, SOURCE, HEADLINE, BODY, MENTIONED_NAME,
       ROUND(SENTIMENT_SCORE, 3)                              AS SENTIMENT_SCORE,
       COALESCE(CLS:labels[0]::STRING, CLS:label::STRING)     AS AI_CATEGORY,
       IFF(COALESCE(CLS:labels[0]::STRING, CLS:label::STRING) = 'Positive or neutral business news',
           FALSE, TRUE)                                       AS IS_ADVERSE,
       HEADLINE || '. ' || BODY                               AS ARTICLE_TEXT
FROM ai;

SELECT RISK_TAG, COUNT(*) AS NOTES, ROUND(AVG(SENTIMENT_SCORE), 2) AS AVG_SENTIMENT
FROM ANALYST_NOTES_ENRICHED GROUP BY RISK_TAG ORDER BY NOTES DESC;

SELECT AI_CATEGORY, IS_ADVERSE, COUNT(*) AS ARTICLES
FROM ADVERSE_MEDIA_ENRICHED GROUP BY AI_CATEGORY, IS_ADVERSE ORDER BY ARTICLES DESC;

-- -----------------------------------------------------------------------------
-- 4. Cortex Search services (hybrid vector + keyword search)
-- -----------------------------------------------------------------------------
USE SCHEMA APP;

CREATE OR REPLACE CORTEX SEARCH SERVICE POLICY_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOC_ID, SECTION_NO, CLAUSE_NO
  WAREHOUSE = TRACELEDGER_WH
  TARGET_LAG = '1 day'
  COMMENT = 'AML policy, regulatory guidance and Basel/liquidity note, chunked by clause'
  AS (
    SELECT CHUNK_ID, DOC_ID, DOC_TITLE, DOC_VERSION, SECTION_NO, SECTION_TITLE, CLAUSE_NO, PAGE_NO,
           CITATION, CHUNK_TEXT
    FROM TRACELEDGER.DOCS.POLICY_CHUNKS
  );

CREATE OR REPLACE CORTEX SEARCH SERVICE NOTES_SEARCH
  ON NOTE_TEXT
  ATTRIBUTES CUSTOMER_ID, NOTE_TYPE, RISK_TAG
  WAREHOUSE = TRACELEDGER_WH
  TARGET_LAG = '1 hour'
  COMMENT = 'Analyst, call and KYC-review notes with AI risk tags'
  AS (
    SELECT NOTE_ID, CUSTOMER_ID, NOTE_DATE::STRING AS NOTE_DATE, AUTHOR, NOTE_TYPE, RISK_TAG,
           SENTIMENT_SCORE, NOTE_TEXT
    FROM TRACELEDGER.DOCS.ANALYST_NOTES_ENRICHED
  );

CREATE OR REPLACE CORTEX SEARCH SERVICE MEDIA_SEARCH
  ON ARTICLE_TEXT
  ATTRIBUTES MENTIONED_NAME, AI_CATEGORY
  WAREHOUSE = TRACELEDGER_WH
  TARGET_LAG = '1 day'
  COMMENT = 'Adverse media / news screening with AI categories'
  AS (
    SELECT ARTICLE_ID, PUBLISHED_DATE::STRING AS PUBLISHED_DATE, SOURCE, HEADLINE, MENTIONED_NAME,
           AI_CATEGORY, SENTIMENT_SCORE, ARTICLE_TEXT
    FROM TRACELEDGER.DOCS.ADVERSE_MEDIA_ENRICHED
  );

SHOW CORTEX SEARCH SERVICES IN SCHEMA TRACELEDGER.APP;

-- -----------------------------------------------------------------------------
-- 5. Try it: semantic search over the policy, then a cited RAG answer
-- -----------------------------------------------------------------------------
SELECT r.value:CITATION::STRING AS CITATION,
       LEFT(r.value:CHUNK_TEXT::STRING, 250) AS TEXT
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
       'TRACELEDGER.APP.POLICY_SEARCH',
       '{"query": "many cash deposits just under the reporting threshold within a week", "columns": ["CITATION", "CHUNK_TEXT"], "limit": 3}'
     ))['results'])) r;

SELECT AI_COMPLETE(
  'mistral-large2',
  'You are an AML compliance assistant. Using ONLY the policy extracts below, explain what structuring is, the exact '
  || 'alert threshold, and the deadline for filing an STR. Cite each fact as [citation]. If the extracts do not '
  || 'contain the answer, say "insufficient evidence".' || CHR(10) || CHR(10)
  || (SELECT LISTAGG('[' || r.value:CITATION::STRING || '] ' || r.value:CHUNK_TEXT::STRING, CHR(10) || CHR(10))
      FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
             'TRACELEDGER.APP.POLICY_SEARCH',
             '{"query": "structuring threshold and STR filing timeline", "columns": ["CITATION", "CHUNK_TEXT"], "limit": 5}'
           ))['results'])) r)
) AS CITED_ANSWER;
