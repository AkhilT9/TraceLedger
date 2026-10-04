"""
TraceLedger - Layer 1 synthetic data generator.

Generates a realistic Indian retail/SME banking dataset with deliberately
injected AML / fraud typologies, and writes one CSV per table into ../data/.

Pure standard library, deterministic (fixed seed) so every run produces the
same accounts, the same alerts and the same demo story (ACC-1042 is always the
structuring case).

Usage:
    python data_gen/generate_data.py
"""

import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

SEED = 42
AS_OF = date(2026, 9, 30)                  # "today" for the whole dataset
WINDOW_START = date(2025, 10, 1)           # 12 months of transactions
CTR_THRESHOLD = 1_000_000                  # INR 10 lakh cash reporting threshold

N_CUSTOMERS = 500
OUT_DIR = Path(__file__).resolve().parent.parent / "data"

rng = random.Random(SEED)

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------
FIRST_M = ["Aarav", "Vihaan", "Arjun", "Rohan", "Karan", "Rahul", "Amit", "Suresh",
           "Rajesh", "Vikram", "Anil", "Sanjay", "Manoj", "Deepak", "Nikhil", "Pranav",
           "Siddharth", "Harsh", "Gaurav", "Imran", "Farhan", "Joseph", "Ravi", "Kiran",
           "Venkat", "Srinivas", "Mahesh", "Naveen", "Ajay", "Tarun"]
FIRST_F = ["Priya", "Ananya", "Diya", "Sneha", "Pooja", "Kavya", "Neha", "Anjali",
           "Meera", "Lakshmi", "Divya", "Swati", "Ritu", "Sunita", "Fatima", "Ayesha",
           "Mary", "Shreya", "Nandini", "Aishwarya", "Keerthi", "Bhavana", "Rekha", "Sahana"]
LAST = ["Sharma", "Verma", "Gupta", "Reddy", "Rao", "Nair", "Iyer", "Patel", "Shah",
        "Mehta", "Singh", "Kumar", "Das", "Bose", "Banerjee", "Chatterjee", "Joshi",
        "Kulkarni", "Deshpande", "Menon", "Pillai", "Khan", "Sheikh", "Fernandes",
        "D'Souza", "Agarwal", "Jain", "Malhotra", "Kapoor", "Chopra", "Naidu", "Choudhary"]
ENTITY_PREFIX = ["Shree", "Sai", "Balaji", "Ganesh", "Lakshmi", "Om", "Galaxy", "Sunrise",
                 "Apex", "Vertex", "Orion", "Pioneer", "Global", "Royal", "Metro", "Prime"]
ENTITY_SUFFIX = ["Traders", "Enterprises", "Exports", "Impex", "Logistics", "Agencies",
                 "Infra Pvt Ltd", "Textiles", "Jewellers", "Motors", "Tech Solutions",
                 "Commodities LLP", "Fintech Pvt Ltd", "Realty", "Overseas"]

OCCUPATIONS = [  # (occupation, income_low, income_high, cash_intensive)
    ("Salaried - IT", 600_000, 3_500_000, False),
    ("Salaried - Government", 400_000, 1_500_000, False),
    ("Salaried - Private", 300_000, 1_800_000, False),
    ("Doctor", 1_200_000, 6_000_000, False),
    ("Lawyer", 900_000, 5_000_000, False),
    ("Chartered Accountant", 1_000_000, 4_500_000, False),
    ("Shop Owner", 500_000, 2_500_000, True),
    ("Farmer", 150_000, 800_000, True),
    ("Retired", 200_000, 900_000, False),
    ("Student", 0, 150_000, False),
    ("Homemaker", 0, 200_000, False),
    ("Self-Employed Consultant", 700_000, 3_000_000, False),
]
ENTITY_BUSINESS = [  # (business line, turnover_low, turnover_high, cash_intensive)
    ("Wholesale Trading", 20_000_000, 150_000_000, True),
    ("Jewellery Retail", 30_000_000, 200_000_000, True),
    ("Import/Export", 25_000_000, 250_000_000, False),
    ("IT Services", 15_000_000, 120_000_000, False),
    ("Real Estate", 40_000_000, 300_000_000, True),
    ("Logistics", 10_000_000, 80_000_000, False),
]

BRANCHES = [  # branch_id, name, city, state, region, high_risk_area
    ("BR-001", "Mumbai Fort", "Mumbai", "Maharashtra", "WEST", False),
    ("BR-002", "Mumbai Zaveri Bazaar", "Mumbai", "Maharashtra", "WEST", True),
    ("BR-003", "Pune Camp", "Pune", "Maharashtra", "WEST", False),
    ("BR-004", "Ahmedabad CG Road", "Ahmedabad", "Gujarat", "WEST", False),
    ("BR-005", "Surat Ring Road", "Surat", "Gujarat", "WEST", True),
    ("BR-006", "Delhi Connaught Place", "New Delhi", "Delhi", "NORTH", False),
    ("BR-007", "Delhi Chandni Chowk", "New Delhi", "Delhi", "NORTH", True),
    ("BR-008", "Jaipur MI Road", "Jaipur", "Rajasthan", "NORTH", False),
    ("BR-009", "Amritsar Hall Bazaar", "Amritsar", "Punjab", "NORTH", True),
    ("BR-010", "Bengaluru MG Road", "Bengaluru", "Karnataka", "SOUTH", False),
    ("BR-011", "Hyderabad Banjara Hills", "Hyderabad", "Telangana", "SOUTH", False),
    ("BR-012", "Chennai T Nagar", "Chennai", "Tamil Nadu", "SOUTH", False),
    ("BR-013", "Kochi Marine Drive", "Kochi", "Kerala", "SOUTH", False),
    ("BR-014", "Kolkata Park Street", "Kolkata", "West Bengal", "EAST", False),
    ("BR-015", "Kolkata Burrabazar", "Kolkata", "West Bengal", "EAST", True),
    ("BR-016", "Guwahati Fancy Bazaar", "Guwahati", "Assam", "EAST", True),
]

COUNTRIES = [  # code, name, risk_category, fatf_status
    ("IN", "India", "LOW", "MEMBER"),
    ("US", "United States", "LOW", "MEMBER"),
    ("GB", "United Kingdom", "LOW", "MEMBER"),
    ("SG", "Singapore", "LOW", "MEMBER"),
    ("AE", "United Arab Emirates", "MEDIUM", "MEMBER"),
    ("HK", "Hong Kong", "MEDIUM", "MEMBER"),
    ("DE", "Germany", "LOW", "MEMBER"),
    ("AU", "Australia", "LOW", "MEMBER"),
    ("CA", "Canada", "LOW", "MEMBER"),
    ("KP", "North Korea", "HIGH", "CALL_FOR_ACTION"),
    ("IR", "Iran", "HIGH", "CALL_FOR_ACTION"),
    ("MM", "Myanmar", "HIGH", "CALL_FOR_ACTION"),
    ("SY", "Syria", "HIGH", "INCREASED_MONITORING"),
    ("YE", "Yemen", "HIGH", "INCREASED_MONITORING"),
    ("PA", "Panama", "HIGH", "INCREASED_MONITORING"),
    ("VG", "British Virgin Islands", "HIGH", "TAX_HAVEN"),
    ("KY", "Cayman Islands", "HIGH", "TAX_HAVEN"),
    ("SC", "Seychelles", "HIGH", "TAX_HAVEN"),
    ("NG", "Nigeria", "HIGH", "INCREASED_MONITORING"),
    ("ZA", "South Africa", "MEDIUM", "INCREASED_MONITORING"),
]
HIGH_RISK_CC = [c[0] for c in COUNTRIES if c[2] == "HIGH"]
SAFE_FOREIGN_CC = ["US", "GB", "SG", "AE", "DE", "AU", "CA", "HK"]

FOREIGN_BANKS = {
    "US": "First Liberty Bank NA", "GB": "Thames Commercial Bank", "SG": "Straits Pacific Bank",
    "AE": "Gulf Crescent Bank", "HK": "Harbour Asia Bank", "DE": "Rheinland Handelsbank",
    "AU": "Southern Cross Bank", "CA": "Maple North Bank", "KP": "Korea Daesong Trade Bank",
    "IR": "Persia Mercantile Bank", "MM": "Irrawaddy Commerce Bank", "SY": "Levant Commercial Bank",
    "YE": "Aden Gulf Bank", "PA": "Banco Istmo Offshore", "VG": "Tortola Trust Bank",
    "KY": "Grand Cayman Fiduciary Bank", "SC": "Mahe International Bank",
    "NG": "Lagos Continental Bank", "ZA": "Cape Meridian Bank",
}
INDIAN_BANKS = ["State Bank of India", "HDFC Bank", "ICICI Bank", "Axis Bank", "Kotak Mahindra Bank",
                "Punjab National Bank", "Bank of Baroda", "Canara Bank", "Yes Bank", "IDFC First Bank"]
MERCHANTS = ["Big Bazaar", "Reliance Fresh", "Amazon India", "Flipkart", "Swiggy", "Zomato",
             "BigBasket", "Indian Oil", "HP Petrol Pump", "Apollo Pharmacy", "DMart", "Croma",
             "IRCTC", "MakeMyTrip", "BookMyShow", "Airtel", "Jio Recharge", "BESCOM", "Tata Power"]

SANCTIONED_PEOPLE = [  # name, aliases, country, program, dob
    ("Viktor Petrov", "Viktor Petrof; V. Petrov", "RU", "SYN-RUSSIA-EO", "1968-03-14"),
    ("Abdul Rahman Al-Khatib", "Abdulrahman Khatib; A.R. Al Khatib", "SY", "SYN-SYRIA", "1971-07-02"),
    ("Kim Jong Chol", "Kim Jong-chol; J.C. Kim", "KP", "SYN-DPRK", "1975-11-21"),
    ("Hossein Rezaei", "Hosein Rezai; H. Rezaei", "IR", "SYN-IRAN", "1966-01-30"),
    ("Mohammed Farouk Haddad", "Mohamed Farouk Hadad", "YE", "SYN-SDGT", "1980-05-09"),
    ("Dmitri Sokolov", "Dmitry Sokolov; D. Sokolow", "RU", "SYN-RUSSIA-EO", "1972-09-18"),
    ("Aung Min Thein", "Aung Min Thien", "MM", "SYN-BURMA", "1969-12-01"),
    ("Rakesh Bhandari", "Rakesh Bhandary; R.K. Bhandari", "AE", "SYN-NARCOTICS", "1977-04-25"),
    ("Salim Yusuf Merchant", "Saleem Yousuf Merchant; Salim Merchant", "PK", "SYN-SDGT", "1974-08-13"),
    ("Chen Weiguo", "Chen Wei Guo; W.G. Chen", "HK", "SYN-CYBER", "1983-02-11"),
    ("Olusegun Adeyemi", "Olu Adeyemi", "NG", "SYN-FRAUD", "1979-06-06"),
    ("Javier Mendoza Ruiz", "J. Mendoza Ruiz; Javi Mendoza", "PA", "SYN-NARCOTICS", "1970-10-10"),
]
SANCTIONED_ENTITIES = [
    ("Golden Crescent General Trading LLC", "Golden Crescent Trading", "AE", "SYN-IRAN", ""),
    ("Northstar Maritime Holdings", "North Star Maritime", "PA", "SYN-DPRK", ""),
    ("Levant Petro Services", "Levant Petroleum Services", "SY", "SYN-SYRIA", ""),
    ("Baltic Amber Resources Ltd", "Baltic Amber Resources", "CY", "SYN-RUSSIA-EO", ""),
    ("Irrawaddy Jade Consortium", "Irawaddy Jade Consortium", "MM", "SYN-BURMA", ""),
    ("Red Sea Logistics FZE", "Redsea Logistics", "AE", "SYN-SDGT", ""),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def rand_date(start: date, end: date) -> date:
    return start + timedelta(days=rng.randint(0, (end - start).days))


def rand_ts(day: date, hour_lo=8, hour_hi=21) -> datetime:
    return datetime(day.year, day.month, day.day,
                    rng.randint(hour_lo, hour_hi), rng.randint(0, 59), rng.randint(0, 59))


def pan_number(is_entity: bool) -> str:
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    fourth = "C" if is_entity else "P"
    return ("".join(rng.choice(letters) for _ in range(3)) + fourth + rng.choice(letters)
            + f"{rng.randint(0, 9999):04d}" + rng.choice(letters))


def phone() -> str:
    return f"+91-{rng.choice('6789')}{rng.randint(100000000, 999999999)}"


def money(x: float) -> float:
    return round(x, 2)


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------
customers, accounts, txns, loans, notes, media, ground_truth = [], [], [], [], [], [], []
txn_seq = [0]


def add_txn(acc, ts, direction, amount, channel, cp_name="", cp_acc="", cp_bank="",
            cp_country="IN", desc=""):
    txn_seq[0] += 1
    txns.append({
        "TXN_ID": f"TXN-{txn_seq[0]:07d}",
        "ACCOUNT_ID": acc,
        "TXN_TS": ts.strftime("%Y-%m-%d %H:%M:%S"),
        "DIRECTION": direction,
        "AMOUNT": money(amount),
        "CURRENCY": "INR",
        "CHANNEL": channel,
        "COUNTERPARTY_ACCOUNT_ID": cp_acc,
        "COUNTERPARTY_NAME": cp_name,
        "COUNTERPARTY_BANK": cp_bank,
        "COUNTERPARTY_COUNTRY": cp_country,
        "DESCRIPTION": desc,
    })
    return f"TXN-{txn_seq[0]:07d}"


def transfer(src, dst, ts, amount, channel="IMPS", desc="Fund transfer"):
    """Internal transfer: a DEBIT on src and a matching CREDIT on dst."""
    src_name = acct_owner_name[src]
    dst_name = acct_owner_name[dst]
    add_txn(src, ts, "DEBIT", amount, channel, dst_name, dst, "TraceLedger Bank", "IN", desc)
    add_txn(dst, ts + timedelta(seconds=rng.randint(5, 90)), "CREDIT", amount, channel,
            src_name, src, "TraceLedger Bank", "IN", desc)


def tag(customer_id, account_id, pattern, detail):
    ground_truth.append({"CUSTOMER_ID": customer_id, "ACCOUNT_ID": account_id,
                         "INJECTED_PATTERN": pattern, "DETAIL": detail})


# ---- Customers -------------------------------------------------------------
def make_customer(i, name=None, entity=None, occupation=None, income=None, tier=None,
                  pep=False, nationality="IN", residence="IN"):
    is_entity = entity if entity is not None else rng.random() < 0.15
    if is_entity:
        biz, lo, hi, _ = rng.choice(ENTITY_BUSINESS)
        name = name or f"{rng.choice(ENTITY_PREFIX)} {rng.choice(ENTITY_SUFFIX)}"
        occ = occupation or biz
        inc = income if income is not None else rng.randint(lo, hi)
        dob = rand_date(date(1985, 1, 1), date(2020, 12, 31))   # incorporation date
        gender = ""
    else:
        gender = rng.choice("MF")
        if not name:
            name = f"{rng.choice(FIRST_M if gender == 'M' else FIRST_F)} {rng.choice(LAST)}"
        o = next((x for x in OCCUPATIONS if x[0] == occupation), None) or rng.choice(OCCUPATIONS)
        occ = o[0]
        inc = income if income is not None else rng.randint(o[1], o[2]) // 1000 * 1000
        lo_age = date(2006, 1, 1) if occ == "Student" else date(1996, 1, 1)
        hi_age = date(1955, 1, 1) if occ == "Retired" else date(1960, 1, 1)
        dob = rand_date(hi_age, lo_age)
    branch = rng.choice(BRANCHES)
    cid = f"CUST-{i:04d}"
    tier = tier or rng.choices(["LOW", "MEDIUM", "HIGH"], [70, 25, 5])[0]
    slug = name.lower().replace(" ", ".").replace("'", "")
    customers.append({
        "CUSTOMER_ID": cid,
        "FULL_NAME": name,
        "CUSTOMER_TYPE": "ENTITY" if is_entity else "INDIVIDUAL",
        "DATE_OF_BIRTH": dob.isoformat(),
        "GENDER": gender,
        "NATIONALITY": nationality,
        "COUNTRY_OF_RESIDENCE": residence,
        "CITY": branch[2],
        "STATE": branch[3],
        "REGION": branch[4],
        "HOME_BRANCH_ID": branch[0],
        "OCCUPATION": occ,
        "DECLARED_ANNUAL_INCOME": inc,
        "KYC_RISK_TIER": tier,
        "PEP_FLAG": pep,
        "PAN_NUMBER": pan_number(is_entity),
        "PHONE": phone(),
        "EMAIL": f"{slug}{rng.randint(1, 99)}@example.in",
        "ONBOARDING_DATE": rand_date(date(2012, 1, 1), date(2025, 6, 30)).isoformat(),
        "KYC_LAST_REVIEWED": rand_date(date(2023, 1, 1), date(2026, 6, 30)).isoformat(),
    })
    return customers[-1]


acct_owner_name = {}
acct_seq = [1000]


def make_account(cust, acc_type=None, acc_id=None, status="ACTIVE", open_date=None):
    if not acc_id:
        acct_seq[0] += 1
        if acct_seq[0] == 1042:          # reserved for the demo hero account
            acct_seq[0] += 1
    aid = acc_id or f"ACC-{acct_seq[0]}"
    if cust["CUSTOMER_TYPE"] == "ENTITY":
        acc_type = acc_type or "CURRENT"
    else:
        acc_type = acc_type or rng.choices(["SAVINGS", "CURRENT"], [85, 15])[0]
    branch = cust["HOME_BRANCH_ID"] if rng.random() < 0.9 else rng.choice(BRANCHES)[0]
    od = open_date or max(date.fromisoformat(cust["ONBOARDING_DATE"]),
                          rand_date(date(2012, 1, 1), date(2025, 6, 30)))
    accounts.append({
        "ACCOUNT_ID": aid,
        "CUSTOMER_ID": cust["CUSTOMER_ID"],
        "ACCOUNT_TYPE": acc_type,
        "BRANCH_ID": branch,
        "OPEN_DATE": od.isoformat(),
        "STATUS": status,
        "CURRENCY": "INR",
        "CURRENT_BALANCE": 0.0,      # filled in after txns are generated
    })
    acct_owner_name[aid] = cust["FULL_NAME"]
    return aid


# ---- Baseline (normal) behaviour ------------------------------------------
def normal_activity(acc, cust, start=WINDOW_START, end=AS_OF, intensity=1.0):
    """Salary/business credits, card/UPI spend, bills, occasional cash."""
    is_entity = cust["CUSTOMER_TYPE"] == "ENTITY"
    income = max(cust["DECLARED_ANNUAL_INCOME"], 120_000)
    monthly_in = income / 12
    cash_heavy = cust["OCCUPATION"] in ("Shop Owner", "Farmer", "Wholesale Trading",
                                        "Jewellery Retail", "Real Estate")
    d = date(start.year, start.month, 1)
    while d <= end:
        month_end = min(date(d.year + (d.month // 12), d.month % 12 + 1, 1) - timedelta(days=1), end)
        if d < start:
            d = start
        # inflows
        if is_entity:
            for _ in range(int(rng.randint(6, 14) * intensity)):
                amt = monthly_in / 10 * rng.uniform(0.5, 1.5)
                day = rand_date(d, month_end)
                if cash_heavy and rng.random() < 0.35:
                    add_txn(acc, rand_ts(day), "CREDIT", min(amt, 450_000), "CASH",
                            desc="Cash deposit - daily sales")
                else:
                    add_txn(acc, rand_ts(day), "CREDIT", amt, rng.choice(["NEFT", "RTGS", "IMPS"]),
                            f"{rng.choice(ENTITY_PREFIX)} {rng.choice(ENTITY_SUFFIX)}",
                            cp_bank=rng.choice(INDIAN_BANKS), desc="Invoice payment received")
        elif cust["OCCUPATION"] not in ("Student", "Homemaker", "Farmer", "Shop Owner"):
            day = min(date(d.year, d.month, min(rng.randint(1, 3), 28)), month_end)
            if day >= start:
                add_txn(acc, rand_ts(day, 9, 11), "CREDIT", monthly_in * rng.uniform(0.95, 1.0),
                        "NEFT", "Employer Payroll", cp_bank=rng.choice(INDIAN_BANKS),
                        desc="Salary credit")
        else:
            for _ in range(rng.randint(1, 3)):
                amt = monthly_in / 2 * rng.uniform(0.6, 1.3)
                ch = "CASH" if cash_heavy and rng.random() < 0.6 else "UPI"
                add_txn(acc, rand_ts(rand_date(d, month_end)), "CREDIT", min(amt, 200_000), ch,
                        desc="Cash deposit" if ch == "CASH" else "UPI received")
        # outflows
        n_spend = int(rng.randint(4, 12) * intensity)
        for _ in range(n_spend):
            amt = monthly_in / n_spend * rng.uniform(0.3, 0.9)
            ch = rng.choices(["UPI", "CARD", "NEFT", "CASH"], [45, 30, 15, 10])[0]
            cp = rng.choice(MERCHANTS) if ch in ("UPI", "CARD") else ""
            desc = {"UPI": "UPI payment", "CARD": "POS purchase", "NEFT": "Bill / rent payment",
                    "CASH": "ATM withdrawal"}[ch]
            add_txn(acc, rand_ts(rand_date(d, month_end)), "DEBIT", min(amt, 300_000), ch, cp, desc=desc)
        # occasional legit foreign remittance
        if rng.random() < 0.03:
            cc = rng.choice(SAFE_FOREIGN_CC)
            add_txn(acc, rand_ts(rand_date(d, month_end)), "DEBIT",
                    rng.uniform(50_000, 400_000), "SWIFT", "Overseas University / Family",
                    cp_bank=FOREIGN_BANKS[cc], cp_country=cc, desc="Outward remittance - LRS")
        d = month_end + timedelta(days=1)


# ---------------------------------------------------------------------------
# Scenario injection
# ---------------------------------------------------------------------------
def scenario_structuring(cust, acc, n_bursts=2, hero=False):
    """Multiple cash deposits just below the INR 10L threshold within 7 days."""
    ids = []
    starts = [AS_OF - timedelta(days=12)] if hero else []
    while len(starts) < n_bursts:
        starts.append(rand_date(date(2026, 3, 1), AS_OF - timedelta(days=20)))
    for s in starts:
        branches = [b[0] for b in BRANCHES if b[4] == cust["REGION"]]
        for k in range(rng.randint(4, 6) if hero else rng.randint(3, 5)):
            day = s + timedelta(days=rng.randint(0, 6))
            amt = rng.randint(900_000, 995_000) // 500 * 500
            ids.append(add_txn(acc, rand_ts(day, 10, 16), "CREDIT", amt, "CASH",
                               desc=f"Cash deposit at {rng.choice(branches)}"))
        # funds then move out quickly
        total = sum(t["AMOUNT"] for t in txns if t["TXN_ID"] in ids[-6:])
        add_txn(acc, rand_ts(s + timedelta(days=8)), "DEBIT", total * 0.9, "RTGS",
                "Red Sea Logistics FZE" if hero else f"{rng.choice(ENTITY_PREFIX)} Impex",
                cp_bank=FOREIGN_BANKS["AE"] if hero else rng.choice(INDIAN_BANKS),
                cp_country="AE" if hero else "IN", desc="Payment for goods")
    tag(cust["CUSTOMER_ID"], acc, "STRUCTURING",
        f"{len(ids)} cash deposits of INR 9.0L-9.95L in {len(starts)} 7-day bursts")


def scenario_velocity(cust, acc):
    """Normal ~10 txns/month, then 50-80 txns in 3 days."""
    s = rand_date(date(2026, 6, 1), AS_OF - timedelta(days=5))
    n = rng.randint(50, 80)
    for _ in range(n):
        day = s + timedelta(days=rng.randint(0, 2))
        direction = rng.choice(["CREDIT", "DEBIT"])
        add_txn(acc, rand_ts(day, 0, 23), direction, rng.uniform(9_000, 49_000), "UPI",
                f"UPI-{rng.randint(1000, 9999)}@okbank", desc="UPI P2P transfer")
    tag(cust["CUSTOMER_ID"], acc, "VELOCITY_SPIKE", f"{n} UPI txns within 3 days starting {s}")


def scenario_dormant(cust, acc):
    """No activity for 9+ months, then large credits and quick outflows."""
    s = rand_date(AS_OF - timedelta(days=45), AS_OF - timedelta(days=5))
    total = 0
    for k in range(rng.randint(3, 6)):
        amt = rng.uniform(400_000, 2_500_000)
        total += amt
        add_txn(acc, rand_ts(s + timedelta(days=k)), "CREDIT", amt,
                rng.choice(["NEFT", "RTGS", "IMPS"]), f"{rng.choice(ENTITY_PREFIX)} {rng.choice(ENTITY_SUFFIX)}",
                cp_bank=rng.choice(INDIAN_BANKS), desc="Fund transfer")
    add_txn(acc, rand_ts(s + timedelta(days=6)), "DEBIT", total * 0.93, "RTGS",
            f"{rng.choice(ENTITY_PREFIX)} Commodities LLP", cp_bank=rng.choice(INDIAN_BANKS),
            desc="Fund transfer")
    tag(cust["CUSTOMER_ID"], acc, "DORMANT_REACTIVATION",
        f"Dormant since before {WINDOW_START}; INR {total/1e5:.1f}L received from {s}")


def scenario_round_trip(cust, acc):
    """Outflows to a high-risk jurisdiction that come back from another one."""
    for _ in range(rng.randint(2, 3)):
        s = rand_date(date(2026, 1, 1), AS_OF - timedelta(days=30))
        amt = rng.randint(20, 80) * 100_000
        out_cc, in_cc = rng.sample(HIGH_RISK_CC, 2)
        add_txn(acc, rand_ts(s), "DEBIT", amt, "SWIFT", "Oceanic Holdings Ltd",
                cp_bank=FOREIGN_BANKS[out_cc], cp_country=out_cc, desc="Advance for imports")
        add_txn(acc, rand_ts(s + timedelta(days=rng.randint(10, 25))), "CREDIT", amt * rng.uniform(0.95, 1.02),
                "SWIFT", "Meridian Capital Partners", cp_bank=FOREIGN_BANKS[in_cc], cp_country=in_cc,
                desc="Investment inflow / FDI")
    tag(cust["CUSTOMER_ID"], acc, "HIGH_RISK_GEOGRAPHY", "SWIFT round-tripping via high-risk jurisdictions")


def scenario_income_mismatch(cust, acc):
    """Student/homemaker with declared income < 2L receiving crores."""
    for _ in range(rng.randint(8, 14)):
        add_txn(acc, rand_ts(rand_date(date(2026, 1, 1), AS_OF)), "CREDIT",
                rng.uniform(300_000, 1_500_000), rng.choice(["IMPS", "NEFT", "UPI"]),
                f"{rng.choice(FIRST_M)} {rng.choice(LAST)}", cp_bank=rng.choice(INDIAN_BANKS),
                desc="Transfer")
    tag(cust["CUSTOMER_ID"], acc, "INCOME_MISMATCH",
        f"Declared income INR {cust['DECLARED_ANNUAL_INCOME']:,} vs crores credited")


def scenario_round_amounts(cust, acc):
    """Many exact multiples of INR 1 lakh."""
    for _ in range(rng.randint(10, 16)):
        amt = rng.randint(2, 25) * 100_000
        direction = rng.choice(["CREDIT", "DEBIT"])
        add_txn(acc, rand_ts(rand_date(date(2026, 4, 1), AS_OF)), direction, amt,
                rng.choice(["RTGS", "NEFT", "CASH"]), f"{rng.choice(ENTITY_PREFIX)} Agencies",
                cp_bank=rng.choice(INDIAN_BANKS), desc="Settlement")
    tag(cust["CUSTOMER_ID"], acc, "ROUND_AMOUNTS", "10+ transactions in exact INR lakh multiples")


def scenario_rapid_in_out(cust, acc):
    """Large credit followed by >=90% debit within 48h (pass-through)."""
    for _ in range(rng.randint(3, 5)):
        s = rand_ts(rand_date(date(2026, 2, 1), AS_OF - timedelta(days=3)))
        amt = rng.uniform(800_000, 4_000_000)
        add_txn(acc, s, "CREDIT", amt, "RTGS", f"{rng.choice(ENTITY_PREFIX)} Overseas",
                cp_bank=rng.choice(INDIAN_BANKS), desc="Receipt")
        add_txn(acc, s + timedelta(hours=rng.randint(2, 40)), "DEBIT", amt * rng.uniform(0.92, 0.99),
                rng.choice(["RTGS", "SWIFT"]), f"{rng.choice(ENTITY_PREFIX)} Impex",
                cp_bank=FOREIGN_BANKS["HK"], cp_country="HK", desc="Onward payment")
    tag(cust["CUSTOMER_ID"], acc, "RAPID_IN_OUT", "Credits passed through within 48h")


def scenario_mule_ring(ring_accounts, ring_custs, label):
    """A->B->C->D->A cycles of large transfers within hours."""
    for _ in range(rng.randint(4, 6)):
        s = rand_ts(rand_date(date(2026, 3, 1), AS_OF - timedelta(days=4)), 9, 12)
        amt = rng.uniform(1_500_000, 3_500_000)
        # seed money enters the ring as cash
        add_txn(ring_accounts[0], s - timedelta(hours=3), "CREDIT", amt, "CASH",
                desc="Cash deposit")
        for k in range(len(ring_accounts)):
            src, dst = ring_accounts[k], ring_accounts[(k + 1) % len(ring_accounts)]
            amt *= rng.uniform(0.97, 0.995)              # small "commission" skimmed per hop
            transfer(src, dst, s + timedelta(hours=k * rng.uniform(1, 4)), amt,
                     rng.choice(["IMPS", "NEFT", "RTGS"]))
    for c, a in zip(ring_custs, ring_accounts):
        tag(c["CUSTOMER_ID"], a, "MULE_RING", f"{label}: cycle {' -> '.join(ring_accounts)} -> {ring_accounts[0]}")


def scenario_fan_in(hub_cust, hub_acc, feeders):
    """15+ accounts send to a hub which wires out abroad."""
    total = 0
    s = rand_date(date(2026, 7, 1), AS_OF - timedelta(days=10))
    for f in feeders:
        amt = rng.uniform(45_000, 49_500)
        total += amt
        transfer(f, hub_acc, rand_ts(s + timedelta(days=rng.randint(0, 4))), amt, "UPI",
                 "Loan repayment")
    add_txn(hub_acc, rand_ts(s + timedelta(days=6)), "DEBIT", total * 0.97, "SWIFT",
            "Golden Crescent General Trading LLC", cp_bank=FOREIGN_BANKS["AE"], cp_country="AE",
            desc="Import payment")
    tag(hub_cust["CUSTOMER_ID"], hub_acc, "FAN_IN_HUB",
        f"{len(feeders)} feeder accounts -> hub -> SWIFT to sanctioned entity in AE")


# ---------------------------------------------------------------------------
# Build the population
# ---------------------------------------------------------------------------
def build():
    # --- special, hand-crafted customers (IDs fixed for the demo) ---
    specials = {}

    # Hero case: ACC-1042 structuring + near-match counterparty
    specials["hero"] = make_customer(1, name="Rajesh Bhandari", entity=False,
                                     occupation="Shop Owner", income=1_200_000, tier="MEDIUM")
    specials["hero"]["HOME_BRANCH_ID"], specials["hero"]["CITY"] = "BR-002", "Mumbai"
    specials["hero"]["STATE"], specials["hero"]["REGION"] = "Maharashtra", "WEST"

    # Sanctions near-matches / exact match / PEPs
    near = [("Viktor Petrovv", "RU"), ("Hossein Rezai", "IR"), ("Dmitry Sokolov", "RU"),
            ("Salim Yusuf Merchant", "IN"), ("Chen Wei Guo", "HK")]
    for k, (nm, nat) in enumerate(near):
        specials[f"sanc{k}"] = make_customer(2 + k, name=nm, entity=False,
                                             occupation="Self-Employed Consultant",
                                             nationality=nat, tier="HIGH" if k < 2 else "MEDIUM")
    specials["sanc_entity"] = make_customer(7, name="Red Sea Logistic FZE", entity=True,
                                            occupation="Logistics", tier="HIGH",
                                            nationality="AE", residence="AE")
    peps = [("Anil Choudhary", "Member of Legislative Assembly (MLA)"),
            ("Sunita Malhotra", "Spouse of Senior IAS Officer"),
            ("Venkat Naidu", "Former Municipal Commissioner")]
    for k, (nm, _role) in enumerate(peps):
        specials[f"pep{k}"] = make_customer(8 + k, name=nm, entity=False,
                                            occupation="Salaried - Government", tier="HIGH", pep=True)

    # remaining customers
    for i in range(len(customers) + 1, N_CUSTOMERS + 1):
        make_customer(i)

    # --- accounts ---
    cust_accounts = {}
    for c in customers:
        if c["CUSTOMER_ID"] == "CUST-0001":
            continue
        n = rng.choices([1, 2, 3], [75, 20, 5])[0]
        cust_accounts[c["CUSTOMER_ID"]] = [make_account(c) for _ in range(n)]
    # hero gets the famous account id
    hero = specials["hero"]
    cust_accounts[hero["CUSTOMER_ID"]] = [make_account(hero, "CURRENT", acc_id="ACC-1042",
                                                       open_date=date(2019, 8, 14))]
    acct_owner_name["ACC-1042"] = hero["FULL_NAME"]

    pool = [c for c in customers if c["CUSTOMER_ID"] not in {s["CUSTOMER_ID"] for s in specials.values()}]
    rng.shuffle(pool)

    def take(n, pred=lambda c: True):
        out = []
        for c in list(pool):
            if pred(c) and len(out) < n:
                out.append(c)
                pool.remove(c)
        return out

    individuals = lambda c: c["CUSTOMER_TYPE"] == "INDIVIDUAL"
    entities = lambda c: c["CUSTOMER_TYPE"] == "ENTITY"

    groups = {
        "structuring": take(5),
        "velocity": take(5, individuals),
        "dormant": take(5, individuals),
        "roundtrip": take(4, entities),
        "rapid": take(4),
        "roundamt": take(4),
        "ring1": take(4, individuals),
        "ring2": take(5, individuals),
        "hub": take(1, entities),
        "feeders": take(16, individuals),
    }
    # income-mismatch: force low-income profile
    groups["income"] = take(5, individuals)
    for k, c in enumerate(groups["income"]):
        c["OCCUPATION"] = ["Student", "Homemaker"][k % 2]
        c["DECLARED_ANNUAL_INCOME"] = rng.randint(0, 150) * 1000
        c["DATE_OF_BIRTH"] = rand_date(date(2000, 1, 1), date(2005, 12, 31)).isoformat() \
            if c["OCCUPATION"] == "Student" else c["DATE_OF_BIRTH"]
    # false-positive control: cash-heavy jeweller with high declared turnover
    groups["fp_jeweller"] = take(2, entities)
    for c in groups["fp_jeweller"]:
        c["OCCUPATION"] = "Jewellery Retail"
        c["DECLARED_ANNUAL_INCOME"] = rng.randint(150, 250) * 1_000_000
        c["KYC_RISK_TIER"] = "MEDIUM"

    dormant_accs = {cust_accounts[c["CUSTOMER_ID"]][0] for c in groups["dormant"]}
    for a in accounts:
        if a["ACCOUNT_ID"] in dormant_accs:
            a["OPEN_DATE"] = rand_date(date(2014, 1, 1), date(2019, 12, 31)).isoformat()

    scenario_ids = {c["CUSTOMER_ID"] for g in groups.values() for c in g}
    scenario_ids |= {s["CUSTOMER_ID"] for s in specials.values()}

    # --- baseline activity for everyone ---
    for c in customers:
        for a in cust_accounts[c["CUSTOMER_ID"]]:
            if a in dormant_accs:
                continue                         # truly silent until the burst
            if c["CUSTOMER_ID"] not in scenario_ids and rng.random() < 0.04:
                # a few genuinely dormant accounts that are never reactivated
                for acc_row in accounts:
                    if acc_row["ACCOUNT_ID"] == a:
                        acc_row["STATUS"] = "DORMANT"
                continue
            normal_activity(a, c, intensity=0.7 if c["CUSTOMER_TYPE"] == "INDIVIDUAL" else 1.0)

    first = lambda c: cust_accounts[c["CUSTOMER_ID"]][0]

    # --- inject typologies ---
    scenario_structuring(hero, "ACC-1042", n_bursts=2, hero=True)
    # hero also has the near-match counterparty: pays Red Sea Logistics FZE (sanctioned)
    for c in groups["structuring"]:
        scenario_structuring(c, first(c), n_bursts=rng.randint(1, 2))
    for c in groups["velocity"]:
        scenario_velocity(c, first(c))
    for c in groups["dormant"]:
        scenario_dormant(c, first(c))
    for c in groups["roundtrip"]:
        scenario_round_trip(c, first(c))
    for c in groups["income"]:
        scenario_income_mismatch(c, first(c))
    for c in groups["roundamt"]:
        scenario_round_amounts(c, first(c))
    for c in groups["rapid"]:
        scenario_rapid_in_out(c, first(c))
    scenario_mule_ring([first(c) for c in groups["ring1"]], groups["ring1"], "RING-A")
    scenario_mule_ring([first(c) for c in groups["ring2"]], groups["ring2"], "RING-B")
    scenario_fan_in(groups["hub"][0], first(groups["hub"][0]), [first(c) for c in groups["feeders"]])

    # sanctions / PEP customers: some foreign wires
    for key in [k for k in specials if k.startswith("sanc")]:
        c = specials[key]
        a = first(c)
        for _ in range(rng.randint(3, 6)):
            cc = rng.choice(["AE", "HK", "PA", "IR", "SY"] if key == "sanc_entity" else ["AE", "HK", "SG"])
            add_txn(a, rand_ts(rand_date(date(2026, 1, 1), AS_OF)), rng.choice(["CREDIT", "DEBIT"]),
                    rng.uniform(500_000, 3_000_000), "SWIFT", "Consulting Fee", cp_bank=FOREIGN_BANKS[cc],
                    cp_country=cc, desc="Professional fees")
        tag(c["CUSTOMER_ID"], a, "SANCTIONS_NEAR_MATCH", f"Name '{c['FULL_NAME']}' resembles a watchlist entry")
    for key in [k for k in specials if k.startswith("pep")]:
        c = specials[key]
        a = first(c)
        for _ in range(rng.randint(2, 4)):
            add_txn(a, rand_ts(rand_date(date(2026, 1, 1), AS_OF)), "CREDIT",
                    rng.uniform(1_000_000, 5_000_000), "RTGS", f"{rng.choice(ENTITY_PREFIX)} Infra Pvt Ltd",
                    cp_bank=rng.choice(INDIAN_BANKS), desc="Consultancy / advisory")
        tag(c["CUSTOMER_ID"], a, "PEP", "PEP receiving large third-party credits from infra contractors")

    # jeweller false positives: legit high cash (individual deposits under 10L but explained by turnover)
    for c in groups["fp_jeweller"]:
        a = first(c)
        for _ in range(rng.randint(20, 30)):
            add_txn(a, rand_ts(rand_date(date(2026, 1, 1), AS_OF)), "CREDIT",
                    rng.uniform(200_000, 900_000), "CASH", desc="Cash deposit - showroom sales")
        tag(c["CUSTOMER_ID"], a, "FALSE_POSITIVE_CONTROL",
            "Cash-intensive jeweller; volumes consistent with declared turnover and GST filings")

    # --- balances & dormant status ---
    bal = {a["ACCOUNT_ID"]: rng.uniform(5_000, 400_000) for a in accounts}
    for t in txns:
        bal[t["ACCOUNT_ID"]] += t["AMOUNT"] if t["DIRECTION"] == "CREDIT" else -t["AMOUNT"]
    for a in accounts:
        a["CURRENT_BALANCE"] = money(max(bal[a["ACCOUNT_ID"]], rng.uniform(1_000, 50_000)))

    # --- loans (credit-risk angle) ---
    loan_custs = rng.sample(customers, 140)
    for k, c in enumerate(loan_custs):
        product, lo, hi, coll = rng.choice([
            ("HOME_LOAN", 2_000_000, 15_000_000, "RESIDENTIAL_PROPERTY"),
            ("PERSONAL_LOAN", 100_000, 1_500_000, "UNSECURED"),
            ("AUTO_LOAN", 400_000, 2_500_000, "VEHICLE"),
            ("BUSINESS_LOAN", 1_000_000, 30_000_000, "COMMERCIAL_PROPERTY"),
            ("GOLD_LOAN", 50_000, 1_000_000, "GOLD"),
            ("NBFC_MSME_LOAN", 500_000, 8_000_000, "RECEIVABLES"),
        ])
        sanctioned = rng.randint(lo, hi) // 1000 * 1000
        disb = rand_date(date(2020, 1, 1), date(2026, 3, 31))
        outstanding = money(sanctioned * rng.uniform(0.2, 0.98))
        dpd = rng.choices([0, rng.randint(1, 29), rng.randint(30, 89), rng.randint(90, 400)],
                          [75, 12, 8, 5])[0]
        loans.append({
            "LOAN_ID": f"LN-{k + 1:05d}",
            "CUSTOMER_ID": c["CUSTOMER_ID"],
            "ACCOUNT_ID": cust_accounts[c["CUSTOMER_ID"]][0],
            "PRODUCT": product,
            "SANCTIONED_AMOUNT": sanctioned,
            "OUTSTANDING_AMOUNT": outstanding,
            "INTEREST_RATE": round(rng.uniform(8.0, 18.5), 2),
            "DISBURSAL_DATE": disb.isoformat(),
            "TENURE_MONTHS": rng.choice([12, 24, 36, 60, 120, 240]),
            "DPD": dpd,
            "ASSET_CLASSIFICATION": "NPA" if dpd > 90 else ("SMA-2" if dpd >= 61 else
                                    ("SMA-1" if dpd >= 31 else ("SMA-0" if dpd >= 1 else "STANDARD"))),
            "COLLATERAL_TYPE": coll,
            "COLLATERAL_VALUE": 0 if coll == "UNSECURED" else money(sanctioned * rng.uniform(1.0, 1.8)),
            "STATUS": "ACTIVE",
        })

    # --- analyst / call notes ---
    flagged = {g["CUSTOMER_ID"]: g["INJECTED_PATTERN"] for g in ground_truth}
    suspicious_notes = {
        "STRUCTURING": [
            "Customer visited branch three times this week with cash bundles, each time asking the teller what amount would 'avoid paperwork'. Declined to provide source of cash.",
            "Called customer regarding repeated cash deposits just under 10 lakh. Customer became evasive and said the cash belongs to 'relatives in business'. No documents provided.",
        ],
        "VELOCITY_SPIKE": [
            "Sudden burst of UPI transfers to many unrelated handles. Customer says phone was 'used by a friend'. Possible account takeover or money mule.",
        ],
        "DORMANT_REACTIVATION": [
            "Account inactive for over a year suddenly received large RTGS credits. Customer could not explain the remitters. Requested updated KYC; pending.",
        ],
        "HIGH_RISK_GEOGRAPHY": [
            "Import advances sent to offshore entity with no shipping documents on file. Inflows labelled FDI from a different tax-haven jurisdiction of similar value. Director unresponsive.",
        ],
        "INCOME_MISMATCH": [
            "Customer profile is student with negligible income but account has received multiple lakhs from unknown individuals. Customer said they are 'helping a friend receive money for a commission'.",
            "Homemaker account receiving high-value transfers. Spouse called on her behalf and refused to share source of funds.",
        ],
        "ROUND_AMOUNTS": [
            "Pattern of exact lakh settlements with agencies that have no visible business relationship to the customer. Invoices not provided.",
        ],
        "RAPID_IN_OUT": [
            "Funds received and wired to Hong Kong within a day. Customer describes it as trade but cannot name goods or provide bill of lading.",
        ],
        "MULE_RING": [
            "Account appears to be part of a circular transfer chain with other customers at different branches. Customer claims they are business partners but no partnership deed exists.",
        ],
        "FAN_IN_HUB": [
            "Business account received many small UPI transfers labelled 'loan repayment' from individuals, then a single SWIFT to UAE. Customer is not a registered lender.",
        ],
        "SANCTIONS_NEAR_MATCH": [
            "Name screening returned a potential watchlist match. Customer provided passport copy; date of birth differs from listed individual. Pending L2 review.",
        ],
        "PEP": [
            "PEP customer. Large advisory fees received from infrastructure contractors who bid for municipal tenders. Enhanced due diligence questionnaire sent.",
        ],
        "FALSE_POSITIVE_CONTROL": [
            "Cash-heavy jewellery showroom. Reviewed GST returns and audited financials; cash deposits are consistent with declared turnover. Customer cooperative and transparent.",
        ],
    }
    benign = [
        "Routine periodic KYC review completed. No adverse findings. Documents up to date.",
        "Customer called to update mobile number. Verified via OTP. No concerns.",
        "Customer requested increase in UPI limit for home renovation payments. Supporting quotation shared.",
        "Branch visit for locker renewal. Customer courteous, KYC current.",
        "Inquiry about fixed deposit rates. No unusual activity observed.",
        "Customer explained large NEFT as property down payment; sale agreement copy provided.",
    ]
    analysts = ["analyst.priya", "analyst.rohan", "analyst.meera", "analyst.karan"]
    nid = 0
    for c in customers:
        cid = c["CUSTOMER_ID"]
        if cid in flagged:
            texts = suspicious_notes[flagged[cid]]
            for t in texts:
                nid += 1
                notes.append({"NOTE_ID": f"NOTE-{nid:05d}", "CUSTOMER_ID": cid,
                              "NOTE_DATE": rand_date(date(2026, 6, 1), AS_OF).isoformat(),
                              "AUTHOR": rng.choice(analysts),
                              "NOTE_TYPE": rng.choice(["CALL", "BRANCH_VISIT", "KYC_REVIEW"]),
                              "NOTE_TEXT": t})
        if rng.random() < 0.35:
            nid += 1
            notes.append({"NOTE_ID": f"NOTE-{nid:05d}", "CUSTOMER_ID": cid,
                          "NOTE_DATE": rand_date(date(2025, 10, 1), AS_OF).isoformat(),
                          "AUTHOR": rng.choice(analysts),
                          "NOTE_TYPE": rng.choice(["CALL", "BRANCH_VISIT", "KYC_REVIEW"]),
                          "NOTE_TEXT": rng.choice(benign)})

    # --- adverse media ---
    sources = ["The Economic Ledger", "Mumbai Mirror Daily", "Financial Chronicle India",
               "Deccan Business Post", "Global Compliance Wire", "Bharat Times"]
    bad_templates = [
        "{name} questioned by Enforcement Directorate in hawala probe. Officials said the {city}-based {occ} is suspected of routing unaccounted cash through multiple bank accounts.",
        "Police bust cyber-fraud mule network; accounts linked to {name} under scanner. Investigators say funds from victims were layered through several accounts before being wired abroad.",
        "GST intelligence unearths fake invoice racket; {name} among those named. The {city} firm allegedly issued bogus invoices worth crores.",
        "{name} linked to shell companies in offshore leak. Documents show directorships in entities registered in tax havens.",
        "Tax raids at premises connected to {name}; unexplained cash and jewellery seized, sources say.",
        "Infrastructure tender irregularities: opposition alleges {name} favoured contractors who later paid advisory fees.",
    ]
    benign_templates = [
        "{name} wins state award for small business excellence in {city}.",
        "{name} expands operations with new showroom in {city}; plans to hire 50 staff.",
        "Local entrepreneur {name} donates to flood relief efforts.",
    ]
    mid = 0
    adverse_targets = [c for c in customers if flagged.get(c["CUSTOMER_ID"]) in
                       ("STRUCTURING", "MULE_RING", "FAN_IN_HUB", "HIGH_RISK_GEOGRAPHY",
                        "SANCTIONS_NEAR_MATCH", "PEP", "ROUND_AMOUNTS")]
    for c in [hero] + rng.sample(adverse_targets, min(14, len(adverse_targets))):
        tmpl = bad_templates[5] if c["PEP_FLAG"] else rng.choice(bad_templates[:5])
        mid += 1
        media.append({"ARTICLE_ID": f"ART-{mid:04d}",
                      "PUBLISHED_DATE": rand_date(date(2025, 6, 1), AS_OF).isoformat(),
                      "SOURCE": rng.choice(sources),
                      "HEADLINE": tmpl.split(".")[0].format(name=c["FULL_NAME"], city=c["CITY"], occ=c["OCCUPATION"].lower()),
                      "BODY": tmpl.format(name=c["FULL_NAME"], city=c["CITY"], occ=c["OCCUPATION"].lower()),
                      "MENTIONED_NAME": c["FULL_NAME"], "SENTIMENT_HINT": "NEGATIVE"})
    for c in rng.sample(customers, 10):                          # benign mentions of customers
        tmpl = rng.choice(benign_templates)
        mid += 1
        media.append({"ARTICLE_ID": f"ART-{mid:04d}",
                      "PUBLISHED_DATE": rand_date(date(2025, 6, 1), AS_OF).isoformat(),
                      "SOURCE": rng.choice(sources),
                      "HEADLINE": tmpl.format(name=c["FULL_NAME"], city=c["CITY"]).rstrip("."),
                      "BODY": tmpl.format(name=c["FULL_NAME"], city=c["CITY"]),
                      "MENTIONED_NAME": c["FULL_NAME"], "SENTIMENT_HINT": "POSITIVE"})
    for s in SANCTIONED_PEOPLE[:8] + SANCTIONED_ENTITIES[:4]:    # watchlist news (not customers)
        mid += 1
        media.append({"ARTICLE_ID": f"ART-{mid:04d}",
                      "PUBLISHED_DATE": rand_date(date(2025, 1, 1), AS_OF).isoformat(),
                      "SOURCE": "Global Compliance Wire",
                      "HEADLINE": f"Authorities add {s[0]} to sanctions list",
                      "BODY": f"{s[0]} (also known as {s[1]}) was designated under program {s[3]} for alleged involvement in sanctions evasion and illicit finance.",
                      "MENTIONED_NAME": s[0], "SENTIMENT_HINT": "NEGATIVE"})


def write_csv(name, rows):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{name}.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"  {name:<20} {len(rows):>7,} rows -> {path.relative_to(OUT_DIR.parent)}")


def main():
    build()
    txns.sort(key=lambda t: (t["TXN_TS"], t["TXN_ID"]))
    for k, t in enumerate(txns, 1):          # chronological transaction ids
        t["TXN_ID"] = f"TXN-{k:07d}"
    print("TraceLedger synthetic data")
    write_csv("branches", [dict(BRANCH_ID=b[0], BRANCH_NAME=b[1], CITY=b[2], STATE=b[3],
                                REGION=b[4], HIGH_RISK_AREA=b[5]) for b in BRANCHES])
    write_csv("country_risk", [dict(COUNTRY_CODE=c[0], COUNTRY_NAME=c[1], RISK_LEVEL=c[2],
                                    FATF_STATUS=c[3]) for c in COUNTRIES])
    write_csv("customers", customers)
    write_csv("accounts", accounts)
    write_csv("transactions", txns)
    write_csv("loans", loans)
    write_csv("sanctions_list", [
        dict(SANCTION_ID=f"SAN-{k + 1:03d}", LISTED_NAME=s[0], ALIASES=s[1], ENTITY_TYPE=t,
             COUNTRY=s[2], PROGRAM=s[3], DATE_OF_BIRTH=s[4], LIST_SOURCE=src,
             LISTED_DATE=rand_date(date(2015, 1, 1), date(2026, 6, 30)).isoformat())
        for k, (s, t, src) in enumerate(
            [(p, "INDIVIDUAL", rng.choice(["OFAC-SYN", "UN-SYN"])) for p in SANCTIONED_PEOPLE]
            + [(e, "ENTITY", rng.choice(["OFAC-SYN", "UN-SYN", "EU-SYN"])) for e in SANCTIONED_ENTITIES])])
    write_csv("analyst_notes", notes)
    write_csv("adverse_media", media)
    write_csv("ground_truth", ground_truth)


if __name__ == "__main__":
    main()
