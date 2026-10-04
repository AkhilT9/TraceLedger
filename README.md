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
| 2. Signal engine (rules, sanctions fuzzy match, network, risk score) | ⏳ next |
| 3. Intelligence (semantic view, Cortex Search, Agent) | ⏳ |
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
```

## Layer 1 – Data foundation

### Dataset (as of 30-Sep-2026, 12 months of activity, INR)

| Table | Rows | Notes |
|---|---|---|
| `CORE.CUSTOMERS` | 500 | KYC tier, PEP flag, declared income, PAN/phone (PII) |
| `CORE.ACCOUNTS` | 629 | savings / current, branch, status, balance |
| `CORE.TRANSACTIONS` | 62,824 | cash, UPI, IMPS, NEFT, RTGS, SWIFT, card |
| `CORE.BRANCHES` | 16 | 4 regions, high-risk market areas flagged |
| `CORE.COUNTRY_RISK` | 20 | FATF call-for-action, increased monitoring, tax havens |
| `CORE.SANCTIONS_LIST` | 18 | synthetic OFAC/UN/EU-style names and aliases |
| `CORE.LOANS` | 140 | DPD, SMA/NPA classification, collateral |
| `DOCS.ANALYST_NOTES` | 216 | call, branch-visit and KYC notes |
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

**Demo hero, ACC-1042 (Rajesh Bhandari, Mumbai Zaveri Bazaar):** six cash deposits of ₹9.1L–9.9L across four branches in four days, then an RTGS of ₹51.4L to *Red Sea Logistics FZE* (UAE). That entity is a near-match to a sanctioned name, the customer's own name is close to a listed person, and there is adverse media about him.

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
