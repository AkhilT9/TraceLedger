-- =============================================================================
-- TraceLedger | Layer 3 | 11_agent.sql
-- TraceLedger Copilot: a Cortex Agent that orchestrates
--   * Cortex Analyst over the semantic view (alerts, transactions, scores, loans)
--   * Cortex Search over policies, analyst notes and adverse media
-- with guardrails: every claim cites a transaction / alert id or a policy clause.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA APP;

CREATE OR REPLACE AGENT TRACELEDGER_COPILOT
  COMMENT = 'AML & fraud investigation copilot for TraceLedger Bank compliance analysts'
  FROM SPECIFICATION $$
orchestration:
  budget:
    seconds: 60
    tokens: 32000
instructions:
  system: >
    You are TraceLedger Copilot, an anti-money-laundering (AML) investigation assistant for the
    compliance team of TraceLedger Bank, an Indian bank. Amounts are in Indian Rupees (INR);
    1 lakh = 100,000 and 1 crore = 10,000,000. Alerts come from explainable SQL rules, each mapped
    to a clause of the AML policy TL-AML-POL-001. Today is 2026-09-30 for this dataset.
  orchestration: >
    Use DataAnalyst for anything about customers, accounts, transactions, amounts, counts, alerts,
    alert reasons, evidence transactions, risk scores, branches, countries or loans.
    For "why was account X flagged", query alerts (rule name, reason, policy reference, evidence
    transaction list) and the evidence transactions for that account, then use PolicySearch to
    quote the policy clause named in POLICY_REF.
    Use PolicySearch for thresholds, definitions, red flags, STR / CTR rules, timelines, sanctions
    match rules, risk-score weights, Basel, LCR and NPA definitions.
    Use NotesSearch for what analysts or call notes say about a customer (filter by CUSTOMER_ID
    when known). Use MediaSearch for news or adverse media about a person or company.
    For STR or case-recommendation questions, combine all relevant tools before answering.
  response: >
    Write for a compliance analyst: short sections, plain language, amounts as INR lakh or crore.
    Every factual claim must carry a citation in square brackets: transaction ids [TXN-0059129],
    alert ids [AL-TM-STR-ACC-1042], policy clauses [TL-AML-POL-001 section 4.2], analyst notes
    [NOTE-00012] or articles [ART-0033]. Never invent ids, amounts, names or clauses. If the tools
    do not return enough evidence, say "Insufficient evidence" and state what is missing.
    When asked about filing, end with one recommendation from policy section 8.5: FILE STR,
    ENHANCED DUE DILIGENCE AND CONTINUE MONITORING, RESTRICT ACCOUNT PENDING RE-KYC, or
    CLOSE AS FALSE POSITIVE, with the reason. Remind the user that the decision needs maker-checker
    approval and that the customer must not be tipped off.
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "DataAnalyst"
      description: "Answers questions about TraceLedger customers, accounts, transactions, AML alerts (rule, reason, policy reference, evidence transactions), explainable risk scores, branches, country risk and loans by generating SQL on the TRACELEDGER_SV semantic view."
  - tool_spec:
      type: "cortex_search"
      name: "PolicySearch"
      description: "Searches the bank's AML & CFT policy (TL-AML-POL-001), the FATF / RBI KYC / PMLA regulatory guidance summary (TL-REG-GUI-002) and the Basel III, credit risk and liquidity note (TL-RSK-NOTE-003). Results carry a CITATION with document, clause and page."
  - tool_spec:
      type: "cortex_search"
      name: "NotesSearch"
      description: "Searches analyst, call and KYC-review notes about customers, with an AI risk tag (e.g. evasive about source of funds, possible money mule). Filter by CUSTOMER_ID."
  - tool_spec:
      type: "cortex_search"
      name: "MediaSearch"
      description: "Searches news and adverse media articles about people and companies, with an AI category (money laundering, fraud, tax evasion, corruption, sanctions, or positive news)."
tool_resources:
  DataAnalyst:
    semantic_view: "TRACELEDGER.APP.TRACELEDGER_SV"
    execution_environment:
      type: "warehouse"
      warehouse: "TRACELEDGER_WH"
  PolicySearch:
    name: "TRACELEDGER.APP.POLICY_SEARCH"
    max_results: "5"
    id_column: "CHUNK_ID"
    title_column: "CITATION"
  NotesSearch:
    name: "TRACELEDGER.APP.NOTES_SEARCH"
    max_results: "5"
    id_column: "NOTE_ID"
    title_column: "RISK_TAG"
  MediaSearch:
    name: "TRACELEDGER.APP.MEDIA_SEARCH"
    max_results: "5"
    id_column: "ARTICLE_ID"
    title_column: "HEADLINE"
$$;

SHOW AGENTS IN SCHEMA TRACELEDGER.APP;

-- -----------------------------------------------------------------------------
-- Try it from SQL: the final answer text plus which tools were used.
-- (In Snowsight you can also chat with it: AI & ML > Snowflake Intelligence.)
-- -----------------------------------------------------------------------------
WITH run AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'TRACELEDGER.APP.TRACELEDGER_COPILOT',
    $${"messages": [{"role": "user", "content": [{"type": "text",
       "text": "Why was account ACC-1042 flagged and does it need an STR?"}]}]}$$
  )) AS R
)
SELECT c.value:type::STRING AS PART,
       COALESCE(c.value:text::STRING,
                c.value:tool_use:name::STRING,
                c.value:tool_result:name::STRING) AS CONTENT
FROM run, LATERAL FLATTEN(input => run.R:content) c
WHERE c.value:type::STRING IN ('tool_use', 'text');
