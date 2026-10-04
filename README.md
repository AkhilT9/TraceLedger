# TraceLedger – AML & Fraud Investigation Copilot (Snowflake)

A compliance analyst asks *"Why was ACC-1042 flagged, and does it need an STR?"* TraceLedger shows the risky transactions, cites the exact policy clause they breach, and drafts an audit-ready Suspicious Transaction Report. Everything is built on Snowflake: SQL rules, Semantic View + Cortex Analyst, Cortex Search, Cortex Agent and Streamlit in Snowflake.

```
 DATA  ─▶  SIGNALS  ─▶  INTELLIGENCE (Analyst + Search + Agent)  ─▶  APP & REPORTS
   ▲                                                                     │
   └──────────── Governance: roles, masking, audit log ◀────────────────┘
```

## Build status

| Layer | Status |
|---|---|
| 1. Data foundation (synthetic data, policy docs, tables, load) | ✅ done |
| 2. Signal engine (rules, sanctions fuzzy match, network, risk score) | ✅ done |
| 3. Intelligence (semantic view, Cortex Search, Agent) | ⏳ next |
| 4. Streamlit app | ⏳ |
| 5. Governance (roles, masking, row access, audit) | ⏳ |
| 6. Polish (eval set, demo) | ⏳ |

## Repository layout

```
data_gen/generate_data.py      synthetic data generator (deterministic, stdlib only)
data_gen/build_policy_pdfs.py  renders policy markdown -> PDF (needs reportlab)
data/*.csv                     generated data, ready to upload
docs/policies/*.md             AML policy, regulatory guidance, Basel/liquidity note
docs/policies/pdf/*.pdf        the same documents as PDFs, for AI_PARSE_DOCUMENT
sql/00_setup.sql               warehouse, database, schemas, stages
sql/01_tables.sql              table DDL
sql/02_load.sql                COPY INTO from stage
sql/03_validate.sql            row counts and first look at the fraud patterns
sql/04_signals_rules.sql       rule catalog, tunable parameters, 8 transaction-monitoring rules, mule-network detection
sql/05_signals_screening.sql   sanctions fuzzy screening, PEP rule, adverse-media linking
sql/06_signals_alerts.sql      ALERTS and RISK_SCORES dynamic tables (auto-refresh ~1 min)
sql/07_validate_signals.sql    detection rate vs answer key, top risk scores, ACC-1042 explanation
sql/08_live_alert_demo.sql     insert suspicious transactions live and watch the alert appear
```

## Layer 1 – Data foundation

### Dataset (as of 30-Sep-2026, 12 months of activity, INR)

| Table | Rows | Notes |
|---|---|---|
| `CORE.CUSTOMERS` | 500 | KYC tier, PEP flag, declared income, PAN/phone (PII) |
| `CORE.ACCOUNTS` | 629 | savings / current, branch, status, balance |
| `CORE.TRANSACTIONS` | 61,021 | cash, UPI, IMPS, NEFT, RTGS, SWIFT, card |
| `CORE.BRANCHES` | 16 | 4 regions, high-risk market areas flagged |
| `CORE.COUNTRY_RISK` | 20 | FATF call-for-action, increased monitoring, tax havens |
| `CORE.SANCTIONS_LIST` | 18 | synthetic OFAC/UN/EU-style names and aliases |
| `CORE.LOANS` | 140 | DPD, SMA/NPA classification, collateral |
| `DOCS.ANALYST_NOTES` | 229 | call, branch-visit and KYC notes |
| `DOCS.ADVERSE_MEDIA` | 37 | fake news snippets (negative and benign) |
| `CORE.GROUND_TRUTH` | 54 | answer key of injected patterns (evaluation only) |

### Injected typologies → policy clause → rule ID

| Typology | Policy (TL-AML-POL-001) | Rule ID | Accounts |
|---|---|---|---|
| Structuring (cash 9.0L–9.95L, ≥3 in 7 days) | §4.2 | TM-STR | 6 (incl. **ACC-1042**) |
| Velocity spike (50–80 UPI txns in 3 days) | §4.3 | TM-VEL | 5 |
| Dormant reactivation | §4.4 | TM-DOR | 5 |
| High-risk geography / round-tripping | §4.5 | TM-GEO | 4 |
| Income mismatch (students/homemakers) | §4.6 | TM-INC | 5 |
| Round amounts (exact lakh multiples) | §4.7 | TM-RND | 4 |
| Rapid in-out / pass-through | §4.8 | TM-RIO | 4 |
| Mule rings (A→B→C→D→A) + fan-in hub | §4.9 | TM-NET | 9 + 1 hub |
| Sanctions near-match | §5.2 | SCR-SAN | 6 |
| PEP with contractor credits | §3.4 | SCR-PEP | 3 |
| False-positive controls (cash-heavy jewellers) | §7.3 | n/a | 2 |

**Demo hero, ACC-1042 (Rajesh Bhandari, Mumbai Zaveri Bazaar):** nine cash deposits of ₹9.2L–9.8L in two bursts (late Aug and late Sep 2026) across four branches. Each burst is followed by an RTGS to *Red Sea Logistics FZE* (UAE), ₹85L in total. That company is on the watchlist, the customer's own name is close to a listed person, and there is adverse media about him.

Regenerate the data at any time with `python data_gen/generate_data.py`. It always produces the same output.

### How to load it into Snowflake (Snowsight, about 10 minutes)

1. **Get the files on your laptop.** On GitHub, open this repo, switch to the working branch, then **Code → Download ZIP** and unzip it. You can also `git pull` the branch in your IDE.
2. **Open a SQL editor.** In Snowsight, go to **Projects → Workspaces** (or **Worksheets**) and click **+** to create a SQL file.
3. **Run `sql/00_setup.sql`.** Paste the file contents and click **Run all** (the ▶ dropdown, or Ctrl/Cmd+Shift+Enter). This creates the `TRACELEDGER_WH` warehouse, the `TRACELEDGER` database, the `CORE`/`DOCS`/`SIGNALS`/`APP` schemas and two stages.
4. **Run `sql/01_tables.sql`** the same way.
5. **Upload the CSVs.** Go to **Data → Databases → TRACELEDGER → CORE → Stages → DATA_STAGE**, click **+ Files** (top right), select all 10 files from `data/`, then click **Upload**.
6. **Upload the PDFs.** Go to **TRACELEDGER → DOCS → Stages → POLICY_STAGE**, click **+ Files**, and select the 3 PDFs from `docs/policies/pdf/`.
7. **Run `sql/02_load.sql`.** Every `COPY INTO` should show `LOADED`, and the last query should list 3 PDFs.
8. **Run `sql/03_validate.sql`.** Row counts should match the table above, and query 2 should show the ACC-1042 deposits.

Cost: an XS warehouse with `AUTO_SUSPEND = 60`. The whole of Layer 1 uses only a few cents of credits.

## Layer 2 – Signal engine (explainable, no black box)

Everything lives in the `TRACELEDGER.SIGNALS` schema.

| Object | What it is |
|---|---|
| `RULE_CATALOG` | Each rule's ID, name, typology, policy clause and score weight |
| `RULE_PARAMS` / `V_PARAMS` | Every threshold as a row. Change one and the alerts recompute (the What-If simulator uses this) |
| `RULE_TM_*`, `RULE_SCR_*`, `RULE_ADV_MED` | One view per rule. Each returns the account, time window, amount, **evidence transaction IDs**, a plain-English **reason** and a JSON detail |
| `V_TRANSFER_CYCLES` | Recursive SQL that finds money returning to its origin through 2+ intermediaries within 7 days (mule rings) |
| `V_NETWORK_EDGES` | Account-to-account and large external flows for the network graph |
| `V_SCREENING_CUSTOMERS` / `V_SCREENING_COUNTERPARTIES` | Fuzzy watchlist matches (Jaro-Winkler + edit distance) |
| `V_CTR_REPORT` | Monthly Cash Transaction Report candidates (Policy 4.1) |
| `ALERTS` (dynamic table) | One row per rule per account, with a stable `ALERT_ID`, weight and `POLICY_REF` |
| `RISK_SCORES` (dynamic table) | One row per customer: score 0–100, band and an explanation such as `Score 100 = SCR-SAN 50 + TM-STR 35 + TM-INC 20 + ADV-MED 10` |
| `V_ACCOUNT_RISK` | Per-account roll-up for the risk dashboard |

**Detection results** (from `07_validate_signals.sql`):
- Every planted typology is caught by the rule written for it: 100% recall across 11 typologies and 52 customers.
- No clean customer scores MEDIUM or HIGH. 448 of the 466 LOW customers are clean.
- The only alerts on clean customers are 2 adverse-media hits on people who share a name with someone in the news. These are realistic false positives for the "close as false positive" demo.

**Live alert:** run `08_live_alert_demo.sql` step by step. Three sub-threshold cash deposits and a wire to a watchlisted UAE company take ACC-1038 from score 0 to 100 within a minute, with no code change.

### How to run Layer 2

The data generator was improved (more realistic spending amounts and time-ordered mule-ring hops), and the AML policy was updated to v4.3. Reload once:

1. In Snowsight, run this to clear the stages:
   ```sql
   REMOVE @TRACELEDGER.CORE.DATA_STAGE;
   REMOVE @TRACELEDGER.DOCS.POLICY_STAGE;
   ```
2. Upload the 10 CSVs from `data/` to `DATA_STAGE` again, and the 3 PDFs from `docs/policies/pdf/` to `POLICY_STAGE`.
3. **Run All** on `01_tables.sql`, then `02_load.sql`, then `03_validate.sql`. Transactions should be **61,021**.
4. **Run All** on `04_signals_rules.sql`, `05_signals_screening.sql` and `06_signals_alerts.sql`, in that order.
5. **Run All** on `07_validate_signals.sql` to see the results.
6. Optional: open `08_live_alert_demo.sql` and run it **one statement at a time** to watch a live alert appear.
