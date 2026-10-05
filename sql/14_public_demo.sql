-- =============================================================================
-- TraceLedger | Public demo | 14_public_demo.sql
-- Lets judges open the app WITHOUT a Snowflake login:
--   Streamlit Community Cloud (public web page)  --key-pair-->  this Snowflake account
-- Everything (data, Dynamic Tables, Cortex Agent / Search / AI) still runs in Snowflake.
-- Safety: a dedicated SERVICE user with its own limited role (TL_DEMO), key-pair auth
-- (no password), warehouse capped by the resource monitor, AI requests rate-limited in the app.
-- The LAST result is one line of text: paste it into the Streamlit Cloud "Secrets" box.
-- Run it again any time to rotate the key (the old key stops working).
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE TRACELEDGER_WH;
USE DATABASE TRACELEDGER;
USE SCHEMA GOVERNANCE;

-- 1. Role for the public demo app (like the in-Snowflake app owner: the app applies the
--    persona masking and region rules itself; the data is fully synthetic)
CREATE ROLE IF NOT EXISTS TL_DEMO COMMENT = 'Service role for the public TraceLedger demo app';

GRANT USAGE ON WAREHOUSE TRACELEDGER_WH TO ROLE TL_DEMO;
GRANT USAGE ON DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT USAGE ON ALL SCHEMAS IN DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT SELECT ON ALL TABLES IN DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT SELECT ON ALL VIEWS IN DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT SELECT ON ALL DYNAMIC TABLES IN DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT SELECT ON FUTURE TABLES IN DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT SELECT ON FUTURE VIEWS IN DATABASE TRACELEDGER TO ROLE TL_DEMO;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN DATABASE TRACELEDGER TO ROLE TL_DEMO;

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE TL_DEMO;
GRANT SELECT ON SEMANTIC VIEW TRACELEDGER.APP.TRACELEDGER_SV TO ROLE TL_DEMO;
GRANT USAGE ON CORTEX SEARCH SERVICE TRACELEDGER.APP.POLICY_SEARCH TO ROLE TL_DEMO;
GRANT USAGE ON CORTEX SEARCH SERVICE TRACELEDGER.APP.NOTES_SEARCH  TO ROLE TL_DEMO;
GRANT USAGE ON CORTEX SEARCH SERVICE TRACELEDGER.APP.MEDIA_SEARCH  TO ROLE TL_DEMO;
GRANT USAGE ON AGENT TRACELEDGER.APP.TRACELEDGER_COPILOT TO ROLE TL_DEMO;

GRANT INSERT, UPDATE ON TABLE TRACELEDGER.APP.CASES         TO ROLE TL_DEMO;
GRANT INSERT         ON TABLE TRACELEDGER.APP.CASE_EVENTS   TO ROLE TL_DEMO;
GRANT INSERT, UPDATE ON TABLE TRACELEDGER.APP.CASE_FINDINGS TO ROLE TL_DEMO;
GRANT INSERT         ON TABLE TRACELEDGER.APP.AUDIT_LOG     TO ROLE TL_DEMO;
GRANT USAGE ON SEQUENCE TRACELEDGER.APP.CASE_SEQ    TO ROLE TL_DEMO;
GRANT USAGE ON SEQUENCE TRACELEDGER.APP.FINDING_SEQ TO ROLE TL_DEMO;
GRANT USAGE ON SEQUENCE TRACELEDGER.APP.EVENT_SEQ   TO ROLE TL_DEMO;
-- deliberately NOT granted: UPDATE on SIGNALS.RULE_PARAMS (visitors cannot change the rules)

-- 2. Policies: the demo app service role reads like the app owner (persona masking is
--    applied in the app); everyone else is unchanged
-- Create the policies if 13_governance.sql did not get to them (then set the bodies below)
CREATE TABLE IF NOT EXISTS REGION_ACCESS (ROLE_NAME VARCHAR(60), REGION VARCHAR(10));
CREATE MASKING POLICY IF NOT EXISTS PII_NAME_MASK AS (VAL STRING) RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE REGEXP_REPLACE(VAL, '([A-Za-z])[A-Za-z]*', '\\1***') END;
CREATE MASKING POLICY IF NOT EXISTS PII_PAN_MASK AS (VAL STRING) RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE 'XXXXXX' || RIGHT(VAL, 4) END;
CREATE MASKING POLICY IF NOT EXISTS PII_PHONE_MASK AS (VAL STRING) RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE LEFT(VAL, 4) || 'XXXXXX' || RIGHT(VAL, 4) END;
CREATE MASKING POLICY IF NOT EXISTS PII_EMAIL_MASK AS (VAL STRING) RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE LEFT(VAL, 1) || '***@' || SPLIT_PART(VAL, '@', 2) END;
CREATE MASKING POLICY IF NOT EXISTS PII_DOB_MASK AS (VAL DATE) RETURNS DATE ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE DATE_FROM_PARTS(YEAR(VAL), 1, 1) END;
CREATE ROW ACCESS POLICY IF NOT EXISTS REGION_RAP AS (CUSTOMER_REGION STRING) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_AUDITOR', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN')
  OR EXISTS (SELECT 1 FROM TRACELEDGER.GOVERNANCE.REGION_ACCESS m
             WHERE m.ROLE_NAME = CURRENT_ROLE() AND m.REGION = CUSTOMER_REGION);

ALTER MASKING POLICY PII_NAME_MASK SET BODY ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE REGEXP_REPLACE(VAL, '([A-Za-z])[A-Za-z]*', '\\1***') END;
ALTER MASKING POLICY PII_PAN_MASK SET BODY ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE 'XXXXXX' || RIGHT(VAL, 4) END;
ALTER MASKING POLICY PII_PHONE_MASK SET BODY ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE LEFT(VAL, 4) || 'XXXXXX' || RIGHT(VAL, 4) END;
ALTER MASKING POLICY PII_EMAIL_MASK SET BODY ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE LEFT(VAL, 1) || '***@' || SPLIT_PART(VAL, '@', 2) END;
ALTER MASKING POLICY PII_DOB_MASK SET BODY ->
  CASE WHEN CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN') THEN VAL
       ELSE DATE_FROM_PARTS(YEAR(VAL), 1, 1) END;
ALTER ROW ACCESS POLICY REGION_RAP SET BODY ->
  CURRENT_ROLE() IN ('TL_COMPLIANCE_HEAD', 'TL_AUDITOR', 'TL_DEMO', 'ACCOUNTADMIN', 'SYSADMIN')
  OR EXISTS (SELECT 1 FROM TRACELEDGER.GOVERNANCE.REGION_ACCESS m
             WHERE m.ROLE_NAME = CURRENT_ROLE() AND m.REGION = CUSTOMER_REGION);

-- 3. Service user (no password; key-pair only)
CREATE USER IF NOT EXISTS TRACELEDGER_DEMO
  TYPE = SERVICE
  DEFAULT_ROLE = TL_DEMO
  DEFAULT_WAREHOUSE = TRACELEDGER_WH
  DEFAULT_NAMESPACE = TRACELEDGER.APP
  COMMENT = 'Public TraceLedger demo (Streamlit Community Cloud)';
GRANT ROLE TL_DEMO TO USER TRACELEDGER_DEMO;

-- 4. Generate the key pair inside Snowflake (pure Python, no extra packages), register the
--    public key on the user and return the ready-to-paste Streamlit secret
CREATE OR REPLACE PROCEDURE GENERATE_DEMO_SECRET()
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run'
  EXECUTE AS CALLER
AS
$$
import base64, secrets

def _is_probable_prime(n, rounds=40):
    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = secrets.randbelow(n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True

def _prime(bits):
    while True:
        c = secrets.randbits(bits) | (3 << (bits - 2)) | 1
        if _is_probable_prime(c):
            return c

def _len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b

def _tlv(tag, content):
    return bytes([tag]) + _len(len(content)) + content

def _int(v):
    b = v.to_bytes((v.bit_length() + 7) // 8 or 1, "big")
    if b[0] & 0x80:
        b = b"\x00" + b
    return _tlv(0x02, b)

def _seq(*parts):
    return _tlv(0x30, b"".join(parts))

RSA_ALG = _seq(bytes.fromhex("06092a864886f70d010101"), b"\x05\x00")

def generate(bits=2048):
    e = 65537
    while True:
        p, q = _prime(bits // 2), _prime(bits // 2)
        phi = (p - 1) * (q - 1)
        if p != q and phi % e and (p * q).bit_length() == bits:
            break
    n, d = p * q, pow(e, -1, (p - 1) * (q - 1))
    pkcs1 = _seq(_int(0), _int(n), _int(e), _int(d), _int(p), _int(q),
                 _int(d % (p - 1)), _int(d % (q - 1)), _int(pow(q, -1, p)))
    pkcs8 = _seq(_int(0), RSA_ALG, _tlv(0x04, pkcs1))
    spki = _seq(RSA_ALG, _tlv(0x03, b"\x00" + _seq(_int(n), _int(e))))
    return base64.b64encode(pkcs8).decode(), base64.b64encode(spki).decode()


def run(session):
    priv_b64, pub_b64 = generate()
    session.sql(f"ALTER USER TRACELEDGER_DEMO SET RSA_PUBLIC_KEY = '{pub_b64}'").collect()
    account = session.sql("SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME()").collect()[0][0]
    return ('snowflake_demo = { account = "' + account + '", user = "TRACELEDGER_DEMO", role = "TL_DEMO", '
            'warehouse = "TRACELEDGER_WH", database = "TRACELEDGER", schema = "APP", '
            'private_key_b64 = "' + priv_b64 + '" }')
$$;

CALL GENERATE_DEMO_SECRET();
