"""
TraceLedger - AML & Fraud Investigation Copilot (Streamlit in Snowflake)

Pages
  1. Command Center       KPIs, alerts by rule / typology, top risk customers, live alert feed
  2. Customer 360         profile, explainable score, alerts + evidence, screening, notes, network graph
  3. Investigation Copilot  chat with the Cortex Agent (Analyst + Search), with SQL and sources shown
  4. Case Management      alert -> case workflow with history and assignment
  5. Report Generator     STR draft, closure memo (maker-checker), CTR report, regulatory summary
  6. What-If Simulator    tune the structuring rule, liquidity stress of top depositors
  7. Audit Trail          every question, SQL, source, report and decision
"""

import datetime as dt
import html
import json
import re

import altair as alt
import pandas as pd
import streamlit as st
st.set_page_config(page_title="TraceLedger", page_icon="🔎", layout="wide")


@st.cache_resource
def get_session():
    """Works in both Streamlit-in-Snowflake runtimes (warehouse and container/Workspaces)."""
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        return st.connection("snowflake").session()


session = get_session()

AGENT = "TRACELEDGER.APP.TRACELEDGER_COPILOT"
LLM = "mistral-large3"
PERSONAS = {
    "ANALYST": "Analyst (maker)",
    "COMPLIANCE_HEAD": "Compliance Head (checker)",
    "AUDITOR": "Auditor (read-only)",
}
CASE_STATUSES = ["OPEN", "UNDER_REVIEW", "ESCALATED", "STR_FILED", "CLOSED_FALSE_POSITIVE", "CLOSED_NO_ACTION"]
NEXT_STATUS = {
    "OPEN": ["UNDER_REVIEW", "CLOSED_NO_ACTION"],
    "UNDER_REVIEW": ["ESCALATED", "CLOSED_NO_ACTION"],
    "ESCALATED": ["UNDER_REVIEW"],
    "STR_FILED": [],
    "CLOSED_FALSE_POSITIVE": [],
    "CLOSED_NO_ACTION": ["UNDER_REVIEW"],
}
BAND_COLOR = {"HIGH": "#e45756", "MEDIUM": "#f2a541", "LOW": "#8fbf6f"}
ID_PATTERN = r"(TXN-\d{7}|TXN-LIVE-\d{2}|AL-[A-Z]{2,3}-[A-Z]{3}-ACC-\d{4}|NOTE-\d{5}|ART-\d{4})"


# -----------------------------------------------------------------------------
# Data helpers
# -----------------------------------------------------------------------------
def rerun():
    (st.rerun if hasattr(st, "rerun") else st.experimental_rerun)()


@st.cache_data(ttl=120, show_spinner=False)
def q(sql, params=None):
    return session.sql(sql, params=list(params) if params else None).to_pandas()


def run(sql, params=None):
    session.sql(sql, params=list(params) if params else None).collect()
    st.cache_data.clear()


def scalar(sql, params=None):
    return session.sql(sql, params=list(params) if params else None).collect()[0][0]


def show_df(df, height=None):
    kwargs = {"use_container_width": True}
    if height:
        kwargs["height"] = height
    try:
        st.dataframe(df, hide_index=True, **kwargs)
    except TypeError:
        st.dataframe(df, **kwargs)


def inr(x):
    try:
        x = float(x)
    except (TypeError, ValueError):
        return "-"
    if abs(x) >= 1e7:
        return f"₹{x / 1e7:,.2f} Cr"
    if abs(x) >= 1e5:
        return f"₹{x / 1e5:,.2f} L"
    return f"₹{x:,.0f}"


def placeholders(values):
    return ", ".join(["?"] * len(values))


@st.cache_data(show_spinner=False)
def current_user():
    try:
        viewer = getattr(st, "user", None) or getattr(st, "experimental_user", None)
        name = viewer.get("user_name") if viewer is not None else None
        if name:
            return str(name)
    except Exception:
        pass
    return str(session.sql("SELECT CURRENT_USER()").collect()[0][0])


def persona():
    return st.session_state.get("persona", "ANALYST")


def read_only():
    return persona() == "AUDITOR"


def audit(page, action, object_id=None, question=None, generated_sql=None, sources=None, details=None):
    try:
        session.sql(
            "INSERT INTO TRACELEDGER.APP.AUDIT_LOG (EVENT_ID, EVENT_TS, USER_NAME, ROLE_NAME, PERSONA, PAGE, ACTION, "
            "OBJECT_ID, QUESTION, GENERATED_SQL, SOURCES, DETAILS) "
            "SELECT TRACELEDGER.APP.EVENT_SEQ.NEXTVAL, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, ?, CURRENT_ROLE(), ?, ?, ?, "
            "?, ?, ?, ?, PARSE_JSON(?)",
            params=[current_user(), persona(), page, action, object_id, question, generated_sql, sources,
                    json.dumps(details or {}, default=str)],
        ).collect()
    except Exception as e:  # auditing must never break the app, but say so
        st.warning(f"Audit log write failed: {e}")


def llm(prompt):
    return scalar(f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{LLM}', ?)", (prompt,))


def customer_options():
    return q(
        "SELECT r.CUSTOMER_ID, c.FULL_NAME, r.PRIMARY_ACCOUNT_ID, r.RISK_SCORE, r.RISK_BAND "
        "FROM TRACELEDGER.SIGNALS.RISK_SCORES r JOIN TRACELEDGER.CORE.CUSTOMERS c ON c.CUSTOMER_ID = r.CUSTOMER_ID "
        "ORDER BY r.RAW_SCORE DESC, r.CUSTOMER_ID"
    )


def pick_customer(key, label="Customer"):
    opts = customer_options()
    labels = [f"{r.CUSTOMER_ID} · {r.FULL_NAME} · {r.PRIMARY_ACCOUNT_ID} · score {r.RISK_SCORE} ({r.RISK_BAND})"
              for r in opts.itertuples()]
    focus = st.session_state.get("focus_customer", "CUST-0001")
    ids = list(opts["CUSTOMER_ID"])
    idx = ids.index(focus) if focus in ids else 0
    choice = st.selectbox(label, labels, index=idx, key=key)
    cid = choice.split(" · ")[0]
    st.session_state["focus_customer"] = cid
    return cid


def go(page, **state):
    """Navigate to another page (applied before the sidebar radio is drawn on the next run)."""
    st.session_state.update(state)
    if "focus_customer" in state:  # let customer pickers re-initialise on the new focus
        for key in ("c360_customer", "case_customer"):
            st.session_state.pop(key, None)
    st.session_state["nav_target"] = page
    rerun()


# -----------------------------------------------------------------------------
# Sidebar
# -----------------------------------------------------------------------------
PAGES = ["Command Center", "Customer 360", "Investigation Copilot", "Case Management",
         "Report Generator", "What-If Simulator", "Audit Trail"]

with st.sidebar:
    st.markdown("## 🔎 TraceLedger")
    st.caption("AML & Fraud Investigation Copilot")
    st.selectbox("Acting as", list(PERSONAS), format_func=PERSONAS.get, key="persona")
    st.caption(f"User **{current_user()}**")
    if "nav_target" in st.session_state:
        st.session_state["page"] = st.session_state.pop("nav_target")
    if "page" not in st.session_state:
        st.session_state["page"] = PAGES[0]
    st.radio("Go to", PAGES, key="page")
    st.divider()
    if st.button("↻ Refresh data"):
        st.cache_data.clear()
        rerun()
    st.caption("Alerts and scores refresh automatically within ~1 minute of new transactions (Dynamic Tables).")


# -----------------------------------------------------------------------------
# 1. Command Center
# -----------------------------------------------------------------------------
def page_command_center():
    st.title("Command Center")
    k = q("""
        SELECT (SELECT COUNT(*) FROM TRACELEDGER.SIGNALS.ALERTS)                                     AS ALERTS,
               (SELECT COUNT(DISTINCT ACCOUNT_ID) FROM TRACELEDGER.SIGNALS.ALERTS)                   AS ACCOUNTS,
               (SELECT COUNT(*) FROM TRACELEDGER.SIGNALS.RISK_SCORES WHERE RISK_BAND = 'HIGH')       AS HIGH,
               (SELECT COUNT(*) FROM TRACELEDGER.SIGNALS.RISK_SCORES WHERE RISK_BAND = 'MEDIUM')     AS MEDIUM,
               (SELECT COUNT(*) FROM TRACELEDGER.APP.CASES
                 WHERE STATUS IN ('OPEN', 'UNDER_REVIEW', 'ESCALATED'))                              AS OPEN_CASES,
               (SELECT COUNT(*) FROM TRACELEDGER.APP.CASE_FINDINGS
                 WHERE REPORT_TYPE = 'STR' AND STATUS = 'DRAFT')                                     AS STR_PENDING,
               (SELECT COUNT(*) FROM TRACELEDGER.APP.CASE_FINDINGS
                 WHERE REPORT_TYPE = 'STR' AND STATUS = 'APPROVED')                                  AS STR_FILED,
               (SELECT COALESCE(SUM(AMOUNT_INR), 0) FROM TRACELEDGER.SIGNALS.ALERTS)                 AS FLAGGED
    """).iloc[0]
    cols = st.columns(7)
    cols[0].metric("Alerts", int(k.ALERTS), f"{int(k.ACCOUNTS)} accounts", delta_color="off")
    cols[1].metric("High-risk customers", int(k.HIGH))
    cols[2].metric("Medium-risk customers", int(k.MEDIUM))
    cols[3].metric("Open cases", int(k.OPEN_CASES))
    cols[4].metric("STRs awaiting approval", int(k.STR_PENDING))
    cols[5].metric("STRs filed", int(k.STR_FILED))
    cols[6].metric("Value flagged", inr(k.FLAGGED))

    left, right = st.columns([3, 2])
    with left:
        st.subheader("Alerts by rule")
        by_rule = q("""
            SELECT RULE_ID || ' · ' || RULE_NAME AS RULE, TYPOLOGY, COUNT(*) AS ALERTS, ANY_VALUE(POLICY_REF) AS POLICY
            FROM TRACELEDGER.SIGNALS.ALERTS GROUP BY 1, 2 ORDER BY 3 DESC
        """)
        st.altair_chart(
            alt.Chart(by_rule).mark_bar().encode(
                x=alt.X("ALERTS:Q", title="Alerts"),
                y=alt.Y("RULE:N", sort="-x", title=None),
                color=alt.Color("TYPOLOGY:N", legend=alt.Legend(orient="bottom")),
                tooltip=["RULE", "TYPOLOGY", "ALERTS", "POLICY"],
            ).properties(height=320),
            use_container_width=True,
        )
    with right:
        st.subheader("Alert trend by typology")
        trend = q("""
            SELECT DATE_TRUNC('month', ALERT_DATE)::DATE AS MONTH, TYPOLOGY, COUNT(*) AS ALERTS
            FROM TRACELEDGER.SIGNALS.ALERTS
            WHERE ALERT_DATE > (SELECT DATEADD(month, -12, MAX(TXN_TS))::DATE FROM TRACELEDGER.CORE.TRANSACTIONS)
            GROUP BY 1, 2 ORDER BY 1
        """)
        st.altair_chart(
            alt.Chart(trend).mark_bar().encode(
                x=alt.X("yearmonth(MONTH):T", title=None),
                y=alt.Y("ALERTS:Q", title="Alerts"),
                color=alt.Color("TYPOLOGY:N", legend=None),
                tooltip=["MONTH", "TYPOLOGY", "ALERTS"],
            ).properties(height=320),
            use_container_width=True,
        )

    st.subheader("Flagged customers (explainable score)")
    regions = st.multiselect("Region", ["NORTH", "SOUTH", "EAST", "WEST"], default=["NORTH", "SOUTH", "EAST", "WEST"])
    if regions:
        top = q(f"""
            SELECT r.CUSTOMER_ID, c.FULL_NAME AS NAME, r.PRIMARY_ACCOUNT_ID AS ACCOUNT, r.REGION, r.RISK_SCORE AS SCORE,
                   r.RISK_BAND AS BAND, r.N_ALERTS AS ALERTS, r.SCORE_EXPLANATION AS WHY, r.LAST_ALERT_DATE
            FROM TRACELEDGER.SIGNALS.RISK_SCORES r
            JOIN TRACELEDGER.CORE.CUSTOMERS c ON c.CUSTOMER_ID = r.CUSTOMER_ID
            WHERE r.RISK_SCORE > 0 AND r.REGION IN ({placeholders(regions)})
            ORDER BY r.RAW_SCORE DESC, r.CUSTOMER_ID LIMIT 50
        """, tuple(regions))
        show_df(top, height=360)
        c1, c2 = st.columns([3, 1])
        pick = c1.selectbox("Open a customer", list(top["CUSTOMER_ID"]) or ["-"], key="cc_pick")
        c2.write("")
        if c2.button("Open Customer 360", disabled=top.empty):
            go("Customer 360", focus_customer=pick)

    st.subheader("Latest alerts")
    feed = q("""
        SELECT ALERT_ID, ALERT_DATE, ACCOUNT_ID, RULE_NAME, WEIGHT, POLICY_REF, REASON
        FROM TRACELEDGER.SIGNALS.ALERTS ORDER BY WINDOW_END DESC LIMIT 10
    """)
    show_df(feed)


# -----------------------------------------------------------------------------
# 2. Customer 360
# -----------------------------------------------------------------------------
def network_dot(focus_accounts):
    if not focus_accounts:
        return None
    ph = placeholders(focus_accounts)
    e1 = q(f"""
        SELECT SRC_NODE, DST_NODE, EDGE_TYPE, N_TXNS, TOTAL_INR FROM TRACELEDGER.SIGNALS.V_NETWORK_EDGES
        WHERE SRC_NODE IN ({ph}) OR DST_NODE IN ({ph})
    """, tuple(focus_accounts) * 2)
    neighbours = sorted({n for n in pd.concat([e1.SRC_NODE, e1.DST_NODE]) if n.startswith("ACC-")} - set(focus_accounts))
    edges = e1
    if neighbours:
        ph2 = placeholders(neighbours)
        e2 = q(f"""
            SELECT SRC_NODE, DST_NODE, EDGE_TYPE, N_TXNS, TOTAL_INR FROM TRACELEDGER.SIGNALS.V_NETWORK_EDGES
            WHERE EDGE_TYPE = 'INTERNAL' AND SRC_NODE IN ({ph2}) AND DST_NODE IN ({ph2})
        """, tuple(neighbours) * 2)
        edges = pd.concat([e1, e2]).drop_duplicates(subset=["SRC_NODE", "DST_NODE", "EDGE_TYPE"])
    if edges.empty:
        return None
    nodes = sorted(set(edges.SRC_NODE) | set(edges.DST_NODE))
    accts = [n for n in nodes if n.startswith("ACC-")]
    scores = q(f"""
        SELECT ACCOUNT_ID, ACCOUNT_SCORE, RULES_FIRED FROM TRACELEDGER.SIGNALS.V_ACCOUNT_RISK
        WHERE ACCOUNT_ID IN ({placeholders(accts)})
    """, tuple(accts)) if accts else pd.DataFrame(columns=["ACCOUNT_ID", "ACCOUNT_SCORE", "RULES_FIRED"])
    score = dict(zip(scores.ACCOUNT_ID, scores.ACCOUNT_SCORE))
    lines = ["digraph G {", 'rankdir=LR; bgcolor="transparent";',
             'node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=10];',
             'edge [fontname="Helvetica", fontsize=9, color="#888888"];']
    for n in nodes:
        if n.startswith("ACC-"):
            s = score.get(n, 0) or 0
            band = "HIGH" if s >= 70 else "MEDIUM" if s >= 40 else "LOW"
            color = BAND_COLOR[band] if s else "#dddddd"
            pen = ', penwidth=3, color="#222222"' if n in focus_accounts else ""
            lines.append(f'"{n}" [label="{n}\\nscore {int(s)}", fillcolor="{color}"{pen}];')
        else:
            label = n.replace("EXT: ", "").replace('"', "'")
            lines.append(f'"{n}" [label="{label}", shape=ellipse, fillcolor="#cfe3f7"];')
    for e in edges.itertuples():
        lines.append(f'"{e.SRC_NODE}" -> "{e.DST_NODE}" [label="{inr(e.TOTAL_INR)} ({int(e.N_TXNS)})"];')
    lines.append("}")
    return "\n".join(lines)


def page_customer_360():
    st.title("Customer 360")
    c1, c2 = st.columns([4, 1])
    with c1:
        cid = pick_customer("c360_customer")
    with c2:
        acc = st.text_input("…or jump to account", placeholder="ACC-1042")
        if acc:
            hit = q("SELECT CUSTOMER_ID FROM TRACELEDGER.CORE.ACCOUNTS WHERE ACCOUNT_ID = ?", (acc.strip().upper(),))
            if not hit.empty and hit.CUSTOMER_ID[0] != cid:
                go("Customer 360", focus_customer=hit.CUSTOMER_ID[0])
            elif hit.empty:
                st.caption("Account not found")

    prof = q("""
        SELECT c.*, r.RISK_SCORE, r.RISK_BAND, r.SCORE_EXPLANATION, r.PRIMARY_ACCOUNT_ID, r.N_ALERTS
        FROM TRACELEDGER.CORE.CUSTOMERS c
        JOIN TRACELEDGER.SIGNALS.RISK_SCORES r ON r.CUSTOMER_ID = c.CUSTOMER_ID
        WHERE c.CUSTOMER_ID = ?
    """, (cid,)).iloc[0]
    if st.session_state.get("last_viewed") != cid:
        audit("Customer 360", "VIEW_CUSTOMER", object_id=cid)
        st.session_state["last_viewed"] = cid

    top = st.columns([2, 1, 1, 1, 1])
    top[0].markdown(f"### {prof.FULL_NAME}\n{prof.CUSTOMER_TYPE.title()} · {prof.OCCUPATION} · {prof.CITY}, {prof.REGION}")
    top[1].metric("Risk score", int(prof.RISK_SCORE), prof.RISK_BAND,
                  delta_color="inverse" if prof.RISK_BAND != "LOW" else "off")
    top[2].metric("Declared income", inr(prof.DECLARED_ANNUAL_INCOME))
    top[3].metric("KYC tier", prof.KYC_RISK_TIER)
    top[4].metric("PEP", "Yes" if prof.PEP_FLAG else "No")
    st.info(f"**Why this score:** {prof.SCORE_EXPLANATION}")

    b1, b2, _ = st.columns([1, 1, 3])
    if b1.button("📁 Open a case", disabled=read_only() or int(prof.N_ALERTS) == 0):
        go("Case Management", focus_customer=cid, case_prefill=cid)
    if b2.button("💬 Ask the copilot"):
        go("Investigation Copilot", focus_customer=cid,
           prefill=f"Why was customer {cid} ({prof.PRIMARY_ACCOUNT_ID}) flagged and does it need an STR?")

    tabs = st.tabs(["Alerts & evidence", "Transactions", "Network", "Screening & media", "Notes", "Accounts & loans"])

    with tabs[0]:
        alerts = q("""
            SELECT ALERT_ID, RULE_NAME, WEIGHT, POLICY_REF, ALERT_DATE, AMOUNT_INR, REASON
            FROM TRACELEDGER.SIGNALS.V_ALERTS_FLAT WHERE CUSTOMER_ID = ? ORDER BY WEIGHT DESC
        """, (cid,))
        if alerts.empty:
            st.success("No alerts for this customer.")
        else:
            for a in alerts.itertuples():
                with st.expander(f"**{a.RULE_NAME}** · +{a.WEIGHT} pts · {a.POLICY_REF}", expanded=a.Index < 2):
                    st.write(a.REASON)
                    ev = q("""
                        SELECT TXN_ID, TXN_TS, DIRECTION, AMOUNT, CHANNEL, COUNTERPARTY_NAME, COUNTERPARTY_COUNTRY, DESCRIPTION
                        FROM TRACELEDGER.SIGNALS.V_ALERT_EVIDENCE WHERE ALERT_ID = ? ORDER BY TXN_TS
                    """, (a.ALERT_ID,))
                    if not ev.empty:
                        show_df(ev)

    with tabs[1]:
        tx = q("""
            SELECT t.TXN_TS::DATE AS DAY, t.DIRECTION, SUM(t.AMOUNT)::FLOAT AS AMOUNT
            FROM TRACELEDGER.CORE.TRANSACTIONS t
            JOIN TRACELEDGER.CORE.ACCOUNTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID
            WHERE a.CUSTOMER_ID = ? GROUP BY 1, 2 ORDER BY 1
        """, (cid,))
        if not tx.empty:
            st.altair_chart(
                alt.Chart(tx).mark_bar().encode(
                    x=alt.X("DAY:T", title=None), y=alt.Y("AMOUNT:Q", title="INR per day"),
                    color=alt.Color("DIRECTION:N", scale=alt.Scale(domain=["CREDIT", "DEBIT"],
                                                                   range=["#4c78a8", "#e45756"])),
                    tooltip=["DAY", "DIRECTION", alt.Tooltip("AMOUNT:Q", format=",.0f")],
                ).properties(height=260),
                use_container_width=True,
            )
        recent = q("""
            SELECT t.TXN_ID, t.ACCOUNT_ID, t.TXN_TS, t.DIRECTION, t.AMOUNT, t.CHANNEL, t.COUNTERPARTY_NAME,
                   t.COUNTERPARTY_COUNTRY, t.DESCRIPTION
            FROM TRACELEDGER.CORE.TRANSACTIONS t
            JOIN TRACELEDGER.CORE.ACCOUNTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID
            WHERE a.CUSTOMER_ID = ? ORDER BY t.TXN_TS DESC LIMIT 200
        """, (cid,))
        show_df(recent, height=320)

    with tabs[2]:
        accts = list(q("SELECT ACCOUNT_ID FROM TRACELEDGER.CORE.ACCOUNTS WHERE CUSTOMER_ID = ?", (cid,)).ACCOUNT_ID)
        dot = network_dot(accts)
        if dot:
            st.caption("Money flows between accounts (internal transfers) and large external wires. "
                       "Colour = account risk score; bold border = this customer.")
            st.graphviz_chart(dot, use_container_width=True)
        else:
            st.info("No internal transfers or large external wires for this customer.")

    with tabs[3]:
        sc = q("""
            SELECT FULL_NAME, LISTED_NAME, NAME_VARIANT, PROGRAM, LIST_SOURCE, JW_SCORE, EDIT_DISTANCE, MATCH_SCORE,
                   MATCH_TYPE, DOB_MATCH, COUNTRY_MATCH
            FROM TRACELEDGER.SIGNALS.V_SCREENING_CUSTOMERS WHERE CUSTOMER_ID = ?
        """, (cid,))
        st.markdown("**Sanctions screening: customer name**")
        show_df(sc) if not sc.empty else st.caption("No watchlist match at or above the near-match score.")
        cp = q("""
            SELECT s.TXN_ID, s.TXN_TS, s.ACCOUNT_ID, s.AMOUNT, s.COUNTERPARTY_NAME, s.LISTED_NAME, s.PROGRAM,
                   s.MATCH_SCORE, s.MATCH_TYPE
            FROM TRACELEDGER.SIGNALS.V_SCREENING_COUNTERPARTIES s WHERE s.CUSTOMER_ID = ? ORDER BY s.TXN_TS
        """, (cid,))
        st.markdown("**Sanctions screening: counterparties paid / received from**")
        show_df(cp) if not cp.empty else st.caption("No counterparty matches.")
        media = q("""
            SELECT m.ARTICLE_ID, m.PUBLISHED_DATE, m.SOURCE, m.HEADLINE, e.AI_CATEGORY, e.SENTIMENT_SCORE, m.NAME_SCORE
            FROM TRACELEDGER.SIGNALS.V_ADVERSE_MEDIA_MATCHES m
            JOIN TRACELEDGER.DOCS.ADVERSE_MEDIA_ENRICHED e ON e.ARTICLE_ID = m.ARTICLE_ID
            WHERE m.CUSTOMER_ID = ? ORDER BY m.PUBLISHED_DATE DESC
        """, (cid,))
        st.markdown("**Adverse media** (AI category and sentiment from Cortex)")
        show_df(media) if not media.empty else st.caption("No negative news linked to this customer.")

    with tabs[4]:
        notes = q("""
            SELECT NOTE_ID, NOTE_DATE, AUTHOR, NOTE_TYPE, RISK_TAG, SENTIMENT_SCORE, NOTE_TEXT
            FROM TRACELEDGER.DOCS.ANALYST_NOTES_ENRICHED WHERE CUSTOMER_ID = ? ORDER BY NOTE_DATE DESC
        """, (cid,))
        if notes.empty:
            st.caption("No notes.")
        for n in notes.itertuples():
            flag = "🔴" if n.RISK_TAG not in ("Customer cooperative, documents provided", "Routine service request") else "🟢"
            st.markdown(f"{flag} **{n.RISK_TAG}** · {n.NOTE_DATE} · {n.NOTE_TYPE} · {n.AUTHOR} · "
                        f"sentiment {n.SENTIMENT_SCORE:+.2f} · `{n.NOTE_ID}`\n\n> {n.NOTE_TEXT}")

    with tabs[5]:
        show_df(q("""
            SELECT a.ACCOUNT_ID, a.ACCOUNT_TYPE, a.STATUS, a.OPEN_DATE, b.BRANCH_NAME, b.HIGH_RISK_AREA, a.CURRENT_BALANCE
            FROM TRACELEDGER.CORE.ACCOUNTS a JOIN TRACELEDGER.CORE.BRANCHES b ON b.BRANCH_ID = a.BRANCH_ID
            WHERE a.CUSTOMER_ID = ?
        """, (cid,)))
        loans = q("""
            SELECT LOAN_ID, PRODUCT, SANCTIONED_AMOUNT, OUTSTANDING_AMOUNT, DPD, ASSET_CLASSIFICATION, COLLATERAL_TYPE,
                   COLLATERAL_VALUE FROM TRACELEDGER.CORE.LOANS WHERE CUSTOMER_ID = ?
        """, (cid,))
        if not loans.empty:
            st.markdown("**Loans**: AML red flags on a borrower are also a credit-risk signal (TL-RSK-NOTE-003 section 2.4)")
            show_df(loans)


# -----------------------------------------------------------------------------
# 3. Investigation Copilot (Cortex Agent)
# -----------------------------------------------------------------------------
def call_agent(history):
    messages = [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]} for m in history[-8:]]
    body = json.dumps({"messages": messages}).replace("$$", "$ $")
    raw = session.sql(f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{AGENT}', $${body}$$) AS R").collect()[0][0]
    resp = json.loads(raw) if isinstance(raw, str) else raw
    texts, tools, sqls, tables, sources = [], [], [], [], []
    for part in resp.get("content", []):
        kind = part.get("type")
        if kind == "text":
            texts.append(part.get("text", ""))
        elif kind == "tool_use":
            tools.append(part.get("tool_use", {}).get("name", ""))
        elif kind == "tool_result":
            tr = part.get("tool_result", {})
            for c in tr.get("content", []):
                j = c.get("json") or {}
                if j.get("sql"):
                    sqls.append(j["sql"])
                rs = j.get("result_set") or {}
                if rs.get("data"):
                    cols = [col.get("name") for col in rs.get("resultSetMetaData", {}).get("rowType", [])]
                    try:
                        tables.append(pd.DataFrame(rs["data"], columns=cols or None))
                    except ValueError:
                        tables.append(pd.DataFrame(rs["data"]))
                for hit in j.get("searchResults") or j.get("search_results") or []:
                    sources.append({"tool": tr.get("name", ""), **{k: v for k, v in hit.items() if not isinstance(v, (dict, list))}})
    answer = texts[-1] if texts else "The copilot returned no answer."
    return {"answer": answer, "steps": texts[:-1], "tools": tools, "sqls": sqls, "tables": tables,
            "sources": sources, "cited": sorted(set(re.findall(ID_PATTERN, answer)))}


def render_details(d):
    with st.expander(f"How this answer was built · tools: {', '.join(dict.fromkeys(d['tools'])) or 'none'}"):
        for s in d["steps"]:
            st.caption(s)
        for i, sql in enumerate(d["sqls"]):
            st.markdown(f"**Generated SQL {i + 1}** (Cortex Analyst on the semantic view)")
            st.code(sql, language="sql")
        for t in d["tables"]:
            show_df(t)
        if d["sources"]:
            st.markdown("**Retrieved documents** (Cortex Search)")
            show_df(pd.DataFrame(d["sources"]))
        if d["cited"]:
            st.markdown("**Ids cited in the answer:** " + ", ".join(f"`{c}`" for c in d["cited"]))


def page_copilot():
    st.title("Investigation Copilot")
    st.caption("Cortex Agent orchestrating Cortex Analyst (semantic view) and Cortex Search (policies, notes, news). "
               "Every claim must cite a transaction, alert, policy clause, note or article; otherwise it answers "
               "'Insufficient evidence'.")
    chat = st.session_state.setdefault("chat", [])
    if st.button("New conversation", disabled=not chat):
        st.session_state["chat"] = []
        rerun()

    if not chat:
        st.markdown("**Try:**")
        examples = [
            "Why was account ACC-1042 flagged and does it need an STR?",
            "Show the transactions behind the structuring alert for ACC-1042",
            "Which 10 customers have the highest risk score and why?",
            "Which accounts are part of mule rings and how much moved through them?",
            "What does our policy say about structuring and the STR filing deadline?",
            "What do the analyst notes say about CUST-0001?",
        ]
        cols = st.columns(2)
        for i, ex in enumerate(examples):
            if cols[i % 2].button(ex, key=f"ex{i}"):
                st.session_state["prefill"] = ex
                rerun()

    for m in chat:
        with st.chat_message(m["role"]):
            st.markdown(m["text"])
            if m.get("details"):
                render_details(m["details"])

    question = st.chat_input("Ask about a customer, account, alert, policy or trend…")
    if not question and st.session_state.get("prefill"):
        question = st.session_state.pop("prefill")
    if question:
        chat.append({"role": "user", "text": question})
        with st.chat_message("user"):
            st.markdown(question)
        with st.chat_message("assistant"):
            with st.spinner("Investigating: querying data and searching policies…"):
                try:
                    d = call_agent(chat)
                except Exception as e:
                    d = {"answer": f"The copilot call failed: {e}", "steps": [], "tools": [], "sqls": [],
                         "tables": [], "sources": [], "cited": []}
            st.markdown(d["answer"])
            render_details(d)
        chat.append({"role": "assistant", "text": d["answer"], "details": d})
        audit("Investigation Copilot", "ASK_COPILOT", question=question,
              generated_sql="\n;\n".join(d["sqls"]) or None,
              sources=", ".join(d["cited"] + list(dict.fromkeys(d["tools"]))) or None,
              details={"tools": d["tools"], "n_sources": len(d["sources"])})


# -----------------------------------------------------------------------------
# 4. Case Management
# -----------------------------------------------------------------------------
def create_case(cid, alert_ids, priority, assignee, note):
    n = scalar("SELECT TRACELEDGER.APP.CASE_SEQ.NEXTVAL")
    case_id = f"CASE-{int(n):05d}"
    run("""
        INSERT INTO TRACELEDGER.APP.CASES (CASE_ID, CUSTOMER_ID, PRIMARY_ACCOUNT_ID, ALERT_IDS, RISK_SCORE_AT_OPEN,
               PRIORITY, STATUS, ASSIGNED_TO, CREATED_BY, CREATED_PERSONA, CREATED_AT, UPDATED_AT, DUE_DATE)
        SELECT ?, r.CUSTOMER_ID, r.PRIMARY_ACCOUNT_ID, ?, r.RISK_SCORE, ?, 'OPEN', ?, ?, ?,
               CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, DATEADD(day, 7, CURRENT_DATE())
        FROM TRACELEDGER.SIGNALS.RISK_SCORES r WHERE r.CUSTOMER_ID = ?
    """, (case_id, ", ".join(alert_ids), priority, assignee, current_user(), persona(), cid))
    case_event(case_id, None, "OPEN", note or "Case opened from alerts: " + ", ".join(alert_ids))
    audit("Case Management", "CREATE_CASE", object_id=case_id, details={"customer": cid, "alerts": alert_ids})
    return case_id


def case_event(case_id, from_status, to_status, note):
    run("""
        INSERT INTO TRACELEDGER.APP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TS, USER_NAME, PERSONA, FROM_STATUS, TO_STATUS, NOTE)
        SELECT TRACELEDGER.APP.EVENT_SEQ.NEXTVAL, ?, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, ?, ?, ?, ?, ?
    """, (case_id, current_user(), persona(), from_status, to_status, note))


def set_status(case_id, old, new, note, rationale=None):
    run("""
        UPDATE TRACELEDGER.APP.CASES
        SET STATUS = ?, UPDATED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
            DISPOSITION_RATIONALE = COALESCE(?, DISPOSITION_RATIONALE)
        WHERE CASE_ID = ?
    """, (new, rationale, case_id))
    case_event(case_id, old, new, note)
    audit("Case Management", "CHANGE_STATUS", object_id=case_id, details={"from": old, "to": new})


def page_cases():
    st.title("Case Management")
    st.caption("Workflow: OPEN → UNDER_REVIEW → ESCALATED → STR_FILED (needs an approved STR) or "
               "CLOSED_FALSE_POSITIVE (needs an approved closure memo). Policy TL-AML-POL-001 section 7.")

    with st.expander("➕ Open a new case", expanded=bool(st.session_state.get("case_prefill"))):
        cid = pick_customer("case_customer")
        alerts = q("SELECT ALERT_ID, RULE_NAME, WEIGHT FROM TRACELEDGER.SIGNALS.ALERTS WHERE CUSTOMER_ID = ? "
                   "ORDER BY WEIGHT DESC", (cid,))
        existing = q("SELECT CASE_ID, STATUS FROM TRACELEDGER.APP.CASES WHERE CUSTOMER_ID = ? "
                     "AND STATUS IN ('OPEN','UNDER_REVIEW','ESCALATED')", (cid,))
        if not existing.empty:
            st.warning(f"This customer already has an open case: {', '.join(existing.CASE_ID)}")
        sel = st.multiselect("Alerts to group", list(alerts.ALERT_ID), default=list(alerts.ALERT_ID))
        score = int(customer_options().set_index("CUSTOMER_ID").loc[cid, "RISK_SCORE"])
        c1, c2 = st.columns(2)
        prio = c1.selectbox("Priority", ["HIGH", "MEDIUM", "LOW"],
                            index=0 if score >= 70 else 1 if score >= 40 else 2)
        assignee = c2.text_input("Assign to", value=current_user())
        note = st.text_area("Opening note (optional)")
        if st.button("Create case", disabled=read_only() or not sel):
            case_id = create_case(cid, sel, prio, assignee, note)
            st.session_state.pop("case_prefill", None)
            st.session_state["open_case"] = case_id
            st.success(f"{case_id} created.")
            rerun()

    cases = q("""
        SELECT c.CASE_ID, c.STATUS, c.PRIORITY, c.CUSTOMER_ID, cu.FULL_NAME AS NAME, c.PRIMARY_ACCOUNT_ID AS ACCOUNT,
               c.RISK_SCORE_AT_OPEN AS SCORE, c.ASSIGNED_TO, c.DUE_DATE, c.UPDATED_AT
        FROM TRACELEDGER.APP.CASES c JOIN TRACELEDGER.CORE.CUSTOMERS cu ON cu.CUSTOMER_ID = c.CUSTOMER_ID
        ORDER BY c.UPDATED_AT DESC
    """)
    st.subheader("Cases")
    if cases.empty:
        st.info("No cases yet. Open one above, or from Customer 360.")
        return
    statuses = st.multiselect("Status", CASE_STATUSES, default=CASE_STATUSES)
    view = cases[cases.STATUS.isin(statuses)]
    show_df(view, height=260)

    ids = list(cases.CASE_ID)
    default = st.session_state.get("open_case")
    case_id = st.selectbox("Work on case", ids, index=ids.index(default) if default in ids else 0)
    st.session_state["open_case"] = case_id
    case = cases.set_index("CASE_ID").loc[case_id]
    detail = q("SELECT * FROM TRACELEDGER.APP.CASES WHERE CASE_ID = ?", (case_id,)).iloc[0]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Status", case.STATUS)
    c2.metric("Priority", case.PRIORITY)
    c3.metric("Score at open", int(case.SCORE))
    c4.metric("Due", str(case.DUE_DATE))
    st.markdown(f"**{case.NAME}** · {case.CUSTOMER_ID} · {case.ACCOUNT} · alerts: `{detail.ALERT_IDS}`")
    if detail.DISPOSITION_RATIONALE:
        st.info(f"**Disposition rationale:** {detail.DISPOSITION_RATIONALE}")

    st.markdown("**Move the case**")
    nxt = NEXT_STATUS.get(case.STATUS, [])
    cols = st.columns(max(len(nxt), 1) + 2)
    for i, s in enumerate(nxt):
        if cols[i].button(f"→ {s}", disabled=read_only(), key=f"mv_{s}"):
            set_status(case_id, case.STATUS, s, f"Moved to {s}")
            rerun()
    if cols[-2].button("📝 Draft STR / closure memo", disabled=read_only() or case.STATUS in ("STR_FILED", "CLOSED_FALSE_POSITIVE")):
        go("Report Generator", report_case=case_id)
    if cols[-1].button("🔎 Customer 360"):
        go("Customer 360", focus_customer=case.CUSTOMER_ID)

    note = st.text_area("Add an investigation note", key="case_note")
    if st.button("Add note", disabled=read_only() or not note.strip()):
        case_event(case_id, case.STATUS, case.STATUS, note.strip())
        audit("Case Management", "ADD_NOTE", object_id=case_id)
        rerun()

    st.markdown("**History**")
    show_df(q("SELECT EVENT_TS, USER_NAME, PERSONA, FROM_STATUS, TO_STATUS, NOTE FROM TRACELEDGER.APP.CASE_EVENTS "
              "WHERE CASE_ID = ? ORDER BY EVENT_TS DESC", (case_id,)))
    st.markdown("**Findings for this case**")
    show_df(q("SELECT FINDING_ID, REPORT_TYPE, VERSION, STATUS, RECOMMENDATION, GENERATED_BY, GENERATED_AT, "
              "REVIEWED_BY, REVIEWED_AT FROM TRACELEDGER.APP.CASE_FINDINGS WHERE CASE_ID = ? ORDER BY GENERATED_AT DESC",
              (case_id,)))


# -----------------------------------------------------------------------------
# 5. Report Generator
# -----------------------------------------------------------------------------
STR_SECTIONS = """# Suspicious Transaction Report (DRAFT) - {case_id}
Use exactly these sections:
## 1. Summary of suspicion (3-5 sentences)
## 2. Subject details (customer id, name, type, occupation, declared income, KYC tier, PEP, accounts)
## 3. Grounds of suspicion (one bullet per alert: what happened, amounts in INR lakh, dates, evidence transaction ids)
## 4. Typology and policy breached (each typology with its policy clause)
## 5. Supporting information (screening matches, adverse media, analyst notes - cite their ids)
## 6. Actions taken and proposed (EDD, restrictions, monitoring)
## 7. Recommendation (exactly one of: FILE STR / ENHANCED DUE DILIGENCE AND CONTINUE MONITORING / RESTRICT ACCOUNT PENDING RE-KYC / CLOSE AS FALSE POSITIVE) and the filing deadline per policy section 8.1"""

MEMO_SECTIONS = """# Case Closure Memo (DRAFT) - {case_id}
Use exactly these sections:
## 1. Alerts reviewed (alert ids, rules, policy clauses)
## 2. Evidence examined (transactions, documents, notes - cite ids)
## 3. Analyst rationale for closure (use the rationale given below; explain why the activity is explained)
## 4. Policy basis (policy section 7.3 and the clauses of the alerts; for name matches policy section 5.3)
## 5. Recommendation: CLOSE AS FALSE POSITIVE, with any residual monitoring"""


def case_context(case_id):
    case = q("SELECT * FROM TRACELEDGER.APP.CASES WHERE CASE_ID = ?", (case_id,)).iloc[0]
    cid = case.CUSTOMER_ID
    prof = q("""
        SELECT c.CUSTOMER_ID, c.FULL_NAME, c.CUSTOMER_TYPE, c.OCCUPATION, c.DECLARED_ANNUAL_INCOME, c.KYC_RISK_TIER,
               c.PEP_FLAG, c.NATIONALITY, c.CITY, c.ONBOARDING_DATE, r.RISK_SCORE, r.RISK_BAND, r.SCORE_EXPLANATION
        FROM TRACELEDGER.CORE.CUSTOMERS c JOIN TRACELEDGER.SIGNALS.RISK_SCORES r ON r.CUSTOMER_ID = c.CUSTOMER_ID
        WHERE c.CUSTOMER_ID = ?
    """, (cid,)).iloc[0]
    accounts = q("SELECT ACCOUNT_ID, ACCOUNT_TYPE, STATUS, CURRENT_BALANCE FROM TRACELEDGER.CORE.ACCOUNTS WHERE CUSTOMER_ID = ?", (cid,))
    alert_ids = [a.strip() for a in (case.ALERT_IDS or "").split(",") if a.strip()]
    alerts = q(f"""
        SELECT ALERT_ID, RULE_ID, RULE_NAME, TYPOLOGY, POLICY_REF, POLICY_CLAUSE, AMOUNT_INR, REASON
        FROM TRACELEDGER.SIGNALS.V_ALERTS_FLAT WHERE ALERT_ID IN ({placeholders(alert_ids)})
    """, tuple(alert_ids)) if alert_ids else pd.DataFrame()
    evidence = q(f"""
        SELECT DISTINCT TXN_ID, ALERT_ID, TXN_TS, DIRECTION, AMOUNT, CHANNEL, COUNTERPARTY_NAME, COUNTERPARTY_COUNTRY, DESCRIPTION
        FROM TRACELEDGER.SIGNALS.V_ALERT_EVIDENCE WHERE ALERT_ID IN ({placeholders(alert_ids)})
        ORDER BY TXN_TS LIMIT 60
    """, tuple(alert_ids)) if alert_ids else pd.DataFrame()
    clauses = sorted(set(alerts.POLICY_CLAUSE) if not alerts.empty else set()) + ["5.3", "7.3", "7.4", "8.1", "8.3", "8.4", "8.5"]
    policy = q(f"""
        SELECT CITATION, CHUNK_TEXT FROM TRACELEDGER.DOCS.POLICY_CHUNKS
        WHERE DOC_ID = 'TL-AML-POL-001' AND CLAUSE_NO IN ({placeholders(clauses)}) ORDER BY CLAUSE_NO
    """, tuple(clauses))
    notes = q("SELECT NOTE_ID, NOTE_DATE, RISK_TAG, NOTE_TEXT FROM TRACELEDGER.DOCS.ANALYST_NOTES_ENRICHED "
              "WHERE CUSTOMER_ID = ? ORDER BY NOTE_DATE", (cid,))
    media = q("""
        SELECT m.ARTICLE_ID, m.PUBLISHED_DATE, m.SOURCE, m.HEADLINE, e.AI_CATEGORY
        FROM TRACELEDGER.SIGNALS.V_ADVERSE_MEDIA_MATCHES m
        JOIN TRACELEDGER.DOCS.ADVERSE_MEDIA_ENRICHED e ON e.ARTICLE_ID = m.ARTICLE_ID WHERE m.CUSTOMER_ID = ?
    """, (cid,))
    screening = q("SELECT LISTED_NAME, PROGRAM, MATCH_SCORE, MATCH_TYPE, DOB_MATCH FROM TRACELEDGER.SIGNALS.V_SCREENING_CUSTOMERS "
                  "WHERE CUSTOMER_ID = ?", (cid,))

    def block(title, df):
        return f"### {title}\n" + (df.to_csv(index=False) if not df.empty else "(none)\n")

    text = "\n".join([
        f"CASE: {case_id} | status {case.STATUS} | priority {case.PRIORITY}",
        f"CUSTOMER PROFILE: {prof.to_dict()}",
        block("ACCOUNTS", accounts),
        block("ALERTS IN THIS CASE", alerts),
        block("EVIDENCE TRANSACTIONS (amounts in INR)", evidence),
        block("SANCTIONS SCREENING", screening),
        block("ADVERSE MEDIA", media),
        block("ANALYST NOTES", notes),
        "### POLICY CLAUSES (cite as [citation])\n" + "\n".join(f"[{r.CITATION}] {r.CHUNK_TEXT}" for r in policy.itertuples()),
    ])
    allowed = set(evidence.TXN_ID) if not evidence.empty else set()
    allowed |= set(alerts.ALERT_ID) if not alerts.empty else set()
    allowed |= set(notes.NOTE_ID) | set(media.ARTICLE_ID)
    return case, text, allowed, (sorted(set(alerts.POLICY_REF)) if not alerts.empty else [])


def generate_report(case_id, kind, rationale=""):
    case, ctx, allowed, refs = case_context(case_id)
    template = (STR_SECTIONS if kind == "STR" else MEMO_SECTIONS).format(case_id=case_id)
    prompt = (
        "You are a senior AML investigator at TraceLedger Bank (India). Draft the document below for the "
        "Principal Officer. Rules: use ONLY the case data provided; cite every fact in square brackets with the "
        "transaction id, alert id, note id, article id or policy citation it comes from; never invent ids, "
        "names, dates or amounts; write amounts as INR lakh or crore; if something is not in the data write "
        "'Insufficient evidence'; do not contact or tip off the customer.\n\n"
        f"{template}\n\n"
        + (f"ANALYST RATIONALE FOR CLOSURE: {rationale}\n\n" if rationale else "")
        + f"CASE DATA:\n{ctx}"
    )
    content = llm(prompt)
    cited = set(re.findall(ID_PATTERN, content))
    unverified = sorted(cited - allowed)
    rec = next((r for r in ["FILE STR", "ENHANCED DUE DILIGENCE AND CONTINUE MONITORING",
                            "RESTRICT ACCOUNT PENDING RE-KYC", "CLOSE AS FALSE POSITIVE"] if r in content.upper()), "UNSPECIFIED")
    return {"case": case, "content": content, "cited": sorted(cited & allowed), "unverified": unverified,
            "refs": refs, "recommendation": rec}


def save_finding(case_id, cid, kind, title, r):
    version = int(scalar("SELECT COALESCE(MAX(VERSION), 0) + 1 FROM TRACELEDGER.APP.CASE_FINDINGS "
                         "WHERE CASE_ID = ? AND REPORT_TYPE = ?", (case_id, kind)))
    n = scalar("SELECT TRACELEDGER.APP.FINDING_SEQ.NEXTVAL")
    fid = f"FND-{int(n):05d}"
    run("""
        INSERT INTO TRACELEDGER.APP.CASE_FINDINGS (FINDING_ID, CASE_ID, CUSTOMER_ID, REPORT_TYPE, VERSION, TITLE, CONTENT,
               RECOMMENDATION, CITED_TXNS, CITED_CLAUSES, UNVERIFIED_IDS, MODEL, GENERATED_BY, GENERATED_PERSONA,
               GENERATED_AT, STATUS)
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'DRAFT'
    """, (fid, case_id, cid, kind, version, title, r["content"], r["recommendation"], ", ".join(r["cited"]),
          ", ".join(r["refs"]), ", ".join(r["unverified"]), LLM, current_user(), persona()))
    audit("Report Generator", f"SAVE_{kind}", object_id=fid,
          sources=", ".join(r["cited"] + r["refs"]), details={"case": case_id, "version": version})
    return fid, version


def as_html(title, content):
    return (f"<html><head><meta charset='utf-8'><title>{html.escape(title)}</title></head>"
            "<body style='font-family:Arial,sans-serif;max-width:860px;margin:40px auto;line-height:1.5'>"
            f"<p style='color:#a00'><b>CONFIDENTIAL - do not disclose to the customer (PMLA tipping-off).</b></p>"
            f"<pre style='white-space:pre-wrap;font-family:inherit'>{html.escape(content)}</pre></body></html>")


def page_reports():
    st.title("Report Generator")
    tabs = st.tabs(["STR draft", "Case closure memo", "Approvals (maker-checker)", "CTR report", "Regulatory summary"])
    cases = q("SELECT CASE_ID, CUSTOMER_ID, STATUS FROM TRACELEDGER.APP.CASES ORDER BY UPDATED_AT DESC")
    case_ids = list(cases.CASE_ID)
    pref = st.session_state.get("report_case")

    for tab, kind in ((tabs[0], "STR"), (tabs[1], "CLOSURE_MEMO")):
        with tab:
            if not case_ids:
                st.info("Open a case first (Case Management or Customer 360).")
                continue
            case_id = st.selectbox("Case", case_ids, index=case_ids.index(pref) if pref in case_ids else 0, key=f"rc_{kind}")
            rationale = ""
            if kind == "CLOSURE_MEMO":
                rationale = st.text_area("Analyst rationale for closing as false positive (required, Policy 7.3)",
                                         key="memo_rationale",
                                         placeholder="e.g. Cash deposits are consistent with audited turnover and GST returns…")
            ok = not read_only() and (kind == "STR" or len(rationale.strip()) >= 30)
            if st.button(f"Generate {'STR draft' if kind == 'STR' else 'closure memo'} with Cortex AI", disabled=not ok,
                         key=f"gen_{kind}"):
                with st.spinner("Collecting evidence, policy clauses, notes and media; drafting…"):
                    st.session_state[f"draft_{kind}"] = (case_id, generate_report(case_id, kind, rationale))
                audit("Report Generator", f"GENERATE_{kind}", object_id=case_id)
            if st.session_state.get(f"draft_{kind}") and st.session_state[f"draft_{kind}"][0] == case_id:
                r = st.session_state[f"draft_{kind}"][1]
                c1, c2, c3 = st.columns(3)
                c1.metric("Recommendation", r["recommendation"])
                c2.metric("Verified citations", len(r["cited"]))
                c3.metric("Unverified ids", len(r["unverified"]), delta_color="inverse")
                if r["unverified"]:
                    st.error("Guardrail: the draft cites ids that are not in the case evidence: "
                             + ", ".join(r["unverified"]) + ". Regenerate or correct before saving.")
                else:
                    st.success("Guardrail passed: every cited id exists in the case evidence.")
                st.markdown(r["content"])
                title = f"{'STR' if kind == 'STR' else 'Closure memo'} - {case_id} - {r['case'].CUSTOMER_ID}"
                d1, d2, d3 = st.columns(3)
                if d1.button("💾 Save draft for approval", disabled=read_only() or bool(r["unverified"]), key=f"save_{kind}"):
                    fid, v = save_finding(case_id, r["case"].CUSTOMER_ID, kind, title, r)
                    if kind == "CLOSURE_MEMO":
                        run("UPDATE TRACELEDGER.APP.CASES SET DISPOSITION_RATIONALE = ? WHERE CASE_ID = ?",
                            (rationale.strip(), case_id))
                    st.success(f"Saved {fid} (version {v}) to CASE_FINDINGS. A Compliance Head must approve it.")
                d2.download_button("⬇ Markdown", r["content"], file_name=f"{title}.md", key=f"md_{kind}")
                d3.download_button("⬇ HTML (print to PDF)", as_html(title, r["content"]), file_name=f"{title}.html",
                                   mime="text/html", key=f"html_{kind}")

    with tabs[2]:
        st.caption("Maker-checker (Policy 7.4): an Analyst drafts; a Compliance Head approves or rejects. "
                   "The same persona cannot be maker and checker.")
        drafts = q("""
            SELECT FINDING_ID, CASE_ID, CUSTOMER_ID, REPORT_TYPE, VERSION, RECOMMENDATION, UNVERIFIED_IDS,
                   GENERATED_BY, GENERATED_PERSONA, GENERATED_AT, STATUS
            FROM TRACELEDGER.APP.CASE_FINDINGS ORDER BY GENERATED_AT DESC
        """)
        if drafts.empty:
            st.info("No findings yet.")
        else:
            show_df(drafts, height=240)
            pending = list(drafts[drafts.STATUS == "DRAFT"].FINDING_ID)
            if pending:
                fid = st.selectbox("Review", pending)
                f = q("SELECT * FROM TRACELEDGER.APP.CASE_FINDINGS WHERE FINDING_ID = ?", (fid,)).iloc[0]
                with st.expander(f"{f.TITLE} (v{f.VERSION})", expanded=True):
                    st.markdown(f.CONTENT)
                comment = st.text_input("Review comment")
                is_checker = persona() == "COMPLIANCE_HEAD"
                same = f.GENERATED_PERSONA == persona()
                if not is_checker:
                    st.warning("Switch 'Acting as' to Compliance Head (checker) to approve or reject.")
                elif same:
                    st.warning("The maker cannot approve their own draft.")
                c1, c2 = st.columns(2)
                if c1.button("✅ Approve", disabled=not is_checker or same):
                    run("""UPDATE TRACELEDGER.APP.CASE_FINDINGS SET STATUS = 'APPROVED', REVIEWED_BY = ?, REVIEWED_PERSONA = ?,
                           REVIEWED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, REVIEW_COMMENT = ? WHERE FINDING_ID = ?""",
                        (current_user(), persona(), comment, fid))
                    new = "STR_FILED" if f.REPORT_TYPE == "STR" and "FILE STR" in str(f.RECOMMENDATION) else \
                          "CLOSED_FALSE_POSITIVE" if f.REPORT_TYPE == "CLOSURE_MEMO" else None
                    if new:
                        old = scalar("SELECT STATUS FROM TRACELEDGER.APP.CASES WHERE CASE_ID = ?", (f.CASE_ID,))
                        set_status(f.CASE_ID, old, new, f"{f.REPORT_TYPE} {fid} approved by checker. {comment}")
                    audit("Report Generator", "APPROVE_FINDING", object_id=fid, details={"case": f.CASE_ID})
                    rerun()
                if c2.button("❌ Reject", disabled=not is_checker or same):
                    run("""UPDATE TRACELEDGER.APP.CASE_FINDINGS SET STATUS = 'REJECTED', REVIEWED_BY = ?, REVIEWED_PERSONA = ?,
                           REVIEWED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, REVIEW_COMMENT = ? WHERE FINDING_ID = ?""",
                        (current_user(), persona(), comment, fid))
                    audit("Report Generator", "REJECT_FINDING", object_id=fid, details={"case": f.CASE_ID})
                    rerun()

    with tabs[3]:
        st.caption("Cash Transaction Report candidates (Policy 4.1): single cash transactions of INR 10 lakh+ or "
                   "connected cash transactions above INR 10 lakh in a month. Due by the 15th of the next month.")
        months = q("SELECT DISTINCT REPORT_MONTH FROM TRACELEDGER.SIGNALS.V_CTR_REPORT ORDER BY 1 DESC")
        if months.empty:
            st.info("No CTR candidates.")
        else:
            m = st.selectbox("Month", list(months.REPORT_MONTH))
            ctr = q("""
                SELECT v.REPORT_MONTH, v.CUSTOMER_ID, c.FULL_NAME, c.PAN_NUMBER, v.CASH_DEPOSITS_INR, v.CASH_WITHDRAWALS_INR,
                       v.N_CASH_TXNS, v.LARGEST_CASH_TXN_INR, v.CTR_REASON, v.DUE_DATE,
                       ARRAY_TO_STRING(v.TXN_IDS, ', ') AS TXN_IDS
                FROM TRACELEDGER.SIGNALS.V_CTR_REPORT v JOIN TRACELEDGER.CORE.CUSTOMERS c ON c.CUSTOMER_ID = v.CUSTOMER_ID
                WHERE v.REPORT_MONTH = ? ORDER BY v.CASH_DEPOSITS_INR DESC
            """, (m,))
            st.metric("Customers to report", len(ctr))
            show_df(ctr)
            if st.download_button("⬇ CTR (CSV)", ctr.to_csv(index=False), file_name=f"CTR_{m}.csv", mime="text/csv"):
                audit("Report Generator", "DOWNLOAD_CTR", object_id=str(m))

    with tabs[4]:
        typ = q("""SELECT TYPOLOGY, RULE_NAME, COUNT(*) AS ALERTS, COUNT(DISTINCT CUSTOMER_ID) AS CUSTOMERS,
                          SUM(AMOUNT_INR) AS FLAGGED_INR FROM TRACELEDGER.SIGNALS.ALERTS GROUP BY 1, 2 ORDER BY 3 DESC""")
        bands = q("SELECT RISK_BAND, COUNT(*) AS CUSTOMERS FROM TRACELEDGER.SIGNALS.RISK_SCORES GROUP BY 1 ORDER BY 2")
        strs = q("""SELECT REPORT_TYPE, STATUS, COUNT(*) AS N FROM TRACELEDGER.APP.CASE_FINDINGS GROUP BY 1, 2 ORDER BY 1, 2""")
        credit = q("""
            SELECT l.ASSET_CLASSIFICATION, COUNT(*) AS LOANS, SUM(l.OUTSTANDING_AMOUNT) AS OUTSTANDING_INR,
                   SUM(IFF(r.RISK_BAND IN ('HIGH', 'MEDIUM'), l.OUTSTANDING_AMOUNT, 0)) AS TO_FLAGGED_BORROWERS_INR
            FROM TRACELEDGER.CORE.LOANS l JOIN TRACELEDGER.SIGNALS.RISK_SCORES r ON r.CUSTOMER_ID = l.CUSTOMER_ID
            GROUP BY 1 ORDER BY 1
        """)
        c1, c2 = st.columns(2)
        with c1:
            st.markdown("**AML: alerts by typology**")
            show_df(typ)
            st.markdown("**Customers by risk band**")
            show_df(bands)
        with c2:
            st.markdown("**Reports (STR / memos)**")
            show_df(strs) if not strs.empty else st.caption("None yet.")
            st.markdown("**Credit risk: exposure by asset class (TL-RSK-NOTE-003)**")
            show_df(credit)
        if st.button("Write the narrative with Cortex AI", disabled=read_only()):
            prompt = ("Write a one-page regulatory summary for the Board Risk Committee of TraceLedger Bank, in four "
                      "short sections: AML activity, reporting (STR/CTR), credit risk (NPA and exposure to AML-flagged "
                      "borrowers), and key actions. Use only these figures (INR):\n"
                      f"ALERTS BY TYPOLOGY:\n{typ.to_csv(index=False)}\nRISK BANDS:\n{bands.to_csv(index=False)}\n"
                      f"REPORTS:\n{strs.to_csv(index=False)}\nCREDIT:\n{credit.to_csv(index=False)}")
            with st.spinner("Drafting…"):
                st.session_state["reg_summary"] = llm(prompt)
            audit("Report Generator", "GENERATE_REG_SUMMARY")
        if st.session_state.get("reg_summary"):
            st.markdown(st.session_state["reg_summary"])
            st.download_button("⬇ HTML (print to PDF)", as_html("Regulatory summary", st.session_state["reg_summary"]),
                               file_name="regulatory_summary.html", mime="text/html")


# -----------------------------------------------------------------------------
# 6. What-If Simulator
# -----------------------------------------------------------------------------
def page_what_if():
    st.title("What-If Simulator")
    st.subheader("Tune the structuring rule (TM-STR, Policy 4.2)")
    p = q("SELECT STR_MIN_AMOUNT, STR_MIN_COUNT, STR_WINDOW_DAYS FROM TRACELEDGER.SIGNALS.V_PARAMS").iloc[0]
    c1, c2, c3 = st.columns(3)
    min_amt = c1.slider("Lower bound of a sub-threshold cash deposit (INR lakh)", 3.0, 9.5,
                        float(p.STR_MIN_AMOUNT) / 1e5, 0.5)
    min_cnt = c2.slider("Deposits needed in the window", 2, 6, int(p.STR_MIN_COUNT))
    days = c3.slider("Window (days)", 3, 30, int(p.STR_WINDOW_DAYS))
    sim = q("""
        WITH dep AS (
          SELECT TXN_ID, ACCOUNT_ID, TXN_TS FROM TRACELEDGER.CORE.TRANSACTIONS
          WHERE CHANNEL = 'CASH' AND DIRECTION = 'CREDIT' AND AMOUNT >= ? AND AMOUNT < 1000000
        ),
        win AS (
          SELECT a.ACCOUNT_ID, a.TXN_ID, COUNT(*) AS N
          FROM dep a JOIN dep b ON b.ACCOUNT_ID = a.ACCOUNT_ID AND b.TXN_TS >= a.TXN_TS
                               AND b.TXN_TS < DATEADD(day, ?, a.TXN_TS)
          GROUP BY a.ACCOUNT_ID, a.TXN_ID HAVING COUNT(*) >= ?
        )
        SELECT w.ACCOUNT_ID, MAX(w.N) AS MAX_DEPOSITS_IN_WINDOW, ANY_VALUE(c.OCCUPATION) AS OCCUPATION,
               MAX(IFF(al.ALERT_ID IS NOT NULL, 1, 0)) AS FLAGGED_TODAY
        FROM win w
        JOIN TRACELEDGER.CORE.ACCOUNTS a ON a.ACCOUNT_ID = w.ACCOUNT_ID
        JOIN TRACELEDGER.CORE.CUSTOMERS c ON c.CUSTOMER_ID = a.CUSTOMER_ID
        LEFT JOIN TRACELEDGER.SIGNALS.ALERTS al ON al.ACCOUNT_ID = w.ACCOUNT_ID AND al.RULE_ID = 'TM-STR'
        GROUP BY w.ACCOUNT_ID ORDER BY 2 DESC
    """, (min_amt * 1e5, days, min_cnt))
    today = int(scalar("SELECT COUNT(*) FROM TRACELEDGER.SIGNALS.ALERTS WHERE RULE_ID = 'TM-STR'"))
    m1, m2, m3 = st.columns(3)
    m1.metric("Accounts flagged with these settings", len(sim), len(sim) - today)
    m2.metric("Flagged by the current rule", today)
    m3.metric("New alerts to review", int((sim.FLAGGED_TODAY == 0).sum()) if not sim.empty else 0)
    st.caption("Every extra alert costs analyst time (about 30-45 minutes of L1 review each); too few alerts "
               "risks missing structuring. Compare before changing the policy threshold.")
    show_df(sim, height=280)
    if persona() == "COMPLIANCE_HEAD":
        if st.button("Apply these thresholds to production rules"):
            for name, val in (("STR_MIN_AMOUNT", min_amt * 1e5), ("STR_MIN_COUNT", min_cnt), ("STR_WINDOW_DAYS", days)):
                run("UPDATE TRACELEDGER.SIGNALS.RULE_PARAMS SET PARAM_VALUE = ? WHERE PARAM_NAME = ?", (val, name))
            audit("What-If Simulator", "APPLY_RULE_PARAMS",
                  details={"STR_MIN_AMOUNT": min_amt * 1e5, "STR_MIN_COUNT": min_cnt, "STR_WINDOW_DAYS": days})
            st.success("Saved. ALERTS and RISK_SCORES recompute automatically within about a minute.")
    else:
        st.caption("Only the Compliance Head can apply new thresholds to production.")

    st.divider()
    st.subheader("Liquidity stress: what if the top depositors withdraw? (TL-RSK-NOTE-003 section 4)")
    total = float(scalar("SELECT SUM(CURRENT_BALANCE) FROM TRACELEDGER.CORE.ACCOUNTS"))
    n_top = st.slider("Top N depositors withdraw everything", 1, 50, 10)
    hqla_pct = st.slider("High-quality liquid assets (HQLA) as % of deposits", 5, 60, 25)
    top = q("""
        SELECT a.CUSTOMER_ID, c.FULL_NAME, SUM(a.CURRENT_BALANCE) AS DEPOSITS, ANY_VALUE(r.RISK_BAND) AS AML_BAND
        FROM TRACELEDGER.CORE.ACCOUNTS a
        JOIN TRACELEDGER.CORE.CUSTOMERS c ON c.CUSTOMER_ID = a.CUSTOMER_ID
        JOIN TRACELEDGER.SIGNALS.RISK_SCORES r ON r.CUSTOMER_ID = a.CUSTOMER_ID
        GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 50
    """).head(n_top)
    outflow_top = float(top.DEPOSITS.sum())
    rest = total - outflow_top
    stressed_outflow = outflow_top + 0.10 * rest                  # 100% run-off top N, 10% on the rest
    lcr = (hqla_pct / 100 * total) / stressed_outflow * 100 if stressed_outflow else 0
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Total deposits", inr(total))
    c2.metric(f"Top {n_top} share", f"{outflow_top / total * 100:.1f}%")
    c3.metric("Stressed 30-day outflow", inr(stressed_outflow))
    c4.metric("Indicative LCR", f"{lcr:.0f}%", "below 100% minimum" if lcr < 100 else "above 100% minimum",
              delta_color="inverse" if lcr < 100 else "normal")
    st.caption("Simplified: 100% run-off for the top N depositors and 10% for everyone else (Policy note 4.2). "
               "AML-flagged depositors are a less stable funding source (section 4.4).")
    show_df(top)


# -----------------------------------------------------------------------------
# 7. Audit Trail
# -----------------------------------------------------------------------------
def page_audit():
    st.title("Audit Trail")
    st.caption("Every question, generated SQL, cited source, report, approval and status change (Policy 9.2).")
    log = q("""
        SELECT EVENT_ID, EVENT_TS, USER_NAME, ROLE_NAME, PERSONA, PAGE, ACTION, OBJECT_ID, QUESTION, SOURCES,
               GENERATED_SQL, DETAILS::STRING AS DETAILS
        FROM TRACELEDGER.APP.AUDIT_LOG ORDER BY EVENT_TS DESC LIMIT 1000
    """)
    if log.empty:
        st.info("Nothing logged yet.")
        return
    c1, c2 = st.columns(2)
    actions = c1.multiselect("Action", sorted(log.ACTION.unique()), default=sorted(log.ACTION.unique()))
    personas = c2.multiselect("Persona", sorted(log.PERSONA.dropna().unique()), default=sorted(log.PERSONA.dropna().unique()))
    view = log[log.ACTION.isin(actions) & log.PERSONA.isin(personas)]
    m1, m2, m3 = st.columns(3)
    m1.metric("Events", len(view))
    m2.metric("Copilot questions", int((view.ACTION == "ASK_COPILOT").sum()))
    m3.metric("Reports approved", int((view.ACTION == "APPROVE_FINDING").sum()))
    show_df(view, height=420)
    st.download_button("⬇ Export audit log (CSV)", view.to_csv(index=False), file_name="traceledger_audit_log.csv",
                       mime="text/csv")
    st.subheader("Report versions")
    show_df(q("""SELECT FINDING_ID, CASE_ID, REPORT_TYPE, VERSION, STATUS, RECOMMENDATION, MODEL, GENERATED_BY,
                        GENERATED_PERSONA, GENERATED_AT, REVIEWED_BY, REVIEWED_PERSONA, REVIEWED_AT, REVIEW_COMMENT
                 FROM TRACELEDGER.APP.CASE_FINDINGS ORDER BY GENERATED_AT DESC"""))


# -----------------------------------------------------------------------------
# Router
# -----------------------------------------------------------------------------
{
    "Command Center": page_command_center,
    "Customer 360": page_customer_360,
    "Investigation Copilot": page_copilot,
    "Case Management": page_cases,
    "Report Generator": page_reports,
    "What-If Simulator": page_what_if,
    "Audit Trail": page_audit,
}[st.session_state["page"]]()
