# TraceLedger Bank – Anti-Money Laundering & Counter-Terrorist Financing Policy

Document ID: TL-AML-POL-001 | Version 4.2 | Effective: 01-April-2026 | Owner: Principal Officer, Compliance

Classification: Internal. SYNTHETIC DOCUMENT CREATED FOR A HACKATHON DEMO. NOT LEGAL OR REGULATORY ADVICE.

## 1. Purpose and Scope

1.1 This Policy sets out how TraceLedger Bank ("the Bank") prevents, detects and reports money laundering (ML) and terrorist financing (TF), in line with the Prevention of Money Laundering Act, 2002 (PMLA), the PML (Maintenance of Records) Rules, 2005, the RBI Master Direction on KYC, and the FATF Recommendations.

1.2 The Policy applies to all customers, accounts, products and channels of the Bank, including savings, current, NBFC/MSME lending, cash, UPI, IMPS, NEFT, RTGS, card and SWIFT transactions, and to all employees, branches and outsourced service providers.

1.3 Where this Policy is stricter than the applicable regulation, this Policy prevails. Where the regulation is stricter, the regulation prevails.

## 2. Definitions

2.1 Suspicious Transaction: a transaction, including an attempted transaction, that gives rise to a reasonable ground of suspicion that it may involve proceeds of crime, appears to be made in circumstances of unusual or unjustified complexity, appears to have no economic rationale or bona fide purpose, or gives reason to believe it may involve financing of terrorism.

2.2 STR: Suspicious Transaction Report filed with the Financial Intelligence Unit – India (FIU-IND).

2.3 CTR: Cash Transaction Report covering cash transactions above the reporting threshold.

2.4 Principal Officer: the officer designated by the Bank to file reports with FIU-IND and to oversee AML/CFT compliance.

2.5 PEP: Politically Exposed Person, being an individual entrusted with a prominent public function, including their family members and close associates.

2.6 Alert: a system-generated or manually raised signal that one or more transaction monitoring rules in Section 4 or screening rules in Section 5 have been triggered.

2.7 Case: one or more alerts on the same customer grouped for investigation.

## 3. Customer Due Diligence (CDD)

3.1 Risk categorisation. Every customer is assigned a KYC risk tier of LOW, MEDIUM or HIGH at onboarding, based on customer type, occupation or business line, geography, products used, expected transaction profile and source of funds.

3.2 Enhanced Due Diligence (EDD). EDD is mandatory for HIGH risk customers, PEPs, customers with nexus to a High-Risk Jurisdiction (Section 4.5), and any customer with an open case. EDD requires verified source of funds and source of wealth, senior management approval for the relationship, and intensified monitoring.

3.3 Periodic KYC updation. KYC must be refreshed at least once every two years for HIGH risk, every eight years for MEDIUM risk and every ten years for LOW risk customers, and immediately when a material change in profile or behaviour is observed.

3.4 Politically Exposed Persons. Opening or continuing a relationship with a PEP requires approval from the Business Head and the Principal Officer. All credits above INR 10,00,000 to a PEP account from third parties, and in particular from government contractors or vendors, must be reviewed for possible bribery or corruption. Rule mapping: SCR-PEP.

3.5 Declared income and business turnover. The declared annual income (individuals) or annual turnover (entities) captured at onboarding is the baseline for the expected transaction profile used in Section 4.6.

## 4. Transaction Monitoring and Red Flags

Each clause in this section maps to an automated detection rule. The Rule ID is quoted in every alert so that an investigator can trace an alert back to this Policy.

4.1 Cash Transaction Reporting (Rule ID: TM-CTR). All cash transactions of INR 10,00,000 and above, and all series of integrally connected cash transactions that together exceed INR 10,00,000 within a calendar month, must be reported to FIU-IND in the monthly CTR by the 15th day of the following month. A CTR is a regulatory report and is not by itself evidence of suspicion.

4.2 Structuring (Rule ID: TM-STR). Structuring means deliberately splitting cash so that each deposit stays below the INR 10,00,000 reporting threshold. An alert is raised when an account receives three (3) or more cash deposits, each between INR 8,00,000 and INR 9,99,999, within any rolling seven (7) day window. Aggravating factors: deposits made at multiple branches, deposits followed by rapid outward transfers, and customer questions about reporting limits. Structuring is a criminal offence irrespective of the source of the cash and is ordinarily grounds for an STR.

4.3 Velocity Spike (Rule ID: TM-VEL). An alert is raised when an account performs thirty (30) or more transactions within any three (3) day window and that count exceeds five (5) times the account's average three-day transaction count over the preceding ninety (90) days. Sudden high-frequency, low-value UPI or IMPS activity with many unrelated counterparties is a typical indicator of a money mule or account takeover.

4.4 Dormant Account Reactivation (Rule ID: TM-DOR). An account with no customer-initiated transaction for one hundred and eighty (180) days or more is treated as inactive. An alert is raised when such an account receives aggregate credits of INR 5,00,000 or more within thirty (30) days of its first new transaction. Re-KYC must be completed before any further debit is allowed.

4.5 High-Risk Geography (Rule ID: TM-GEO). High-Risk Jurisdictions are those on the FATF "Call for Action" list, those under FATF "Increased Monitoring", and jurisdictions designated internally as secrecy or tax havens (see the country risk register). (a) Any transaction with a FATF Call-for-Action jurisdiction must be escalated to the Principal Officer the same day. (b) An alert is raised when aggregate SWIFT transfers with other High-Risk Jurisdictions reach INR 10,00,000 or more in ninety (90) days. (c) Round-tripping: an outward remittance to one High-Risk Jurisdiction followed within thirty (30) days by an inward remittance of a similar value (within 10%) from another High-Risk Jurisdiction must be treated as a strong indicator of layering or disguised investment.

4.6 Income / Profile Mismatch (Rule ID: TM-INC). An alert is raised when total credits to all accounts of a customer in the trailing twelve (12) months exceed five (5) times the declared annual income or turnover and are at least INR 10,00,000. Students, homemakers and customers with nil declared income receiving large third-party transfers are high-priority mule indicators.

4.7 Round-Amount Transactions (Rule ID: TM-RND). An alert is raised when an account records five (5) or more transactions of INR 1,00,000 or above that are exact multiples of INR 1,00,000 within ninety (90) days, without a documented commercial reason. Round-amount settlements between parties with no visible trade relationship are an indicator of fictitious invoicing.

4.8 Rapid Movement of Funds / Pass-Through (Rule ID: TM-RIO). An alert is raised when a credit of INR 5,00,000 or more is followed by debits totalling at least ninety per cent (90%) of that credit within forty-eight (48) hours. A pass-through account that keeps a near-zero balance while moving large values is characteristic of the layering stage of money laundering.

4.9 Networks, Mule Rings and Fan-In Hubs (Rule ID: TM-NET). (a) Circular flows: an alert is raised when funds originating from an account return to that same account through two (2) or more intermediary accounts within seven (7) days. (b) Fan-in hub: an alert is raised when ten (10) or more distinct accounts send funds to a single account within seven (7) days and that account transfers out eighty per cent (80%) or more of the receipts, especially cross-border. All accounts in the network must be investigated together as one Case.

4.10 Other red flags requiring analyst judgement. Reluctance to provide source of funds; inconsistent explanations; frequent change of mobile number or address; third parties depositing cash; use of the account by persons other than the account holder; transactions inconsistent with the stated occupation; adverse media about the customer or associated persons.

## 5. Sanctions and Watchlist Screening

5.1 All customers, beneficial owners and counterparties of cross-border transactions are screened against the UN Security Council consolidated list, domestic designations under UAPA, and the internal watchlist at onboarding, on every list update and before release of any SWIFT payment.

5.2 Match thresholds (Rule ID: SCR-SAN). Name similarity is computed with fuzzy matching (Jaro-Winkler and edit distance) against the listed name and all aliases. (a) Similarity of 95 or above, or an exact match on name and date of birth, is a Potential True Match: the account must be frozen and escalated to the Principal Officer within 24 hours. (b) Similarity from 85 to below 95 is a Near Match: Level-2 review within 48 hours. (c) Below 85 is not alerted.

5.3 Discounting a match. A Near Match may be closed as a false positive only when at least two independent identifiers (date of birth, nationality, passport or PAN, address) differ from the listed party. The rationale and documents relied upon must be recorded in the Case.

5.4 Counterparty screening. Payments to or from an entity whose name matches a listed entity at the thresholds in 5.2 must be held pending review, even if the customer itself is not listed.

## 6. Explainable Risk Scoring

6.1 The Bank does not use opaque models to decide suspicion. Each customer receives a transparent risk score equal to the sum of the weights of the rules that fired in the trailing ninety (90) days, capped at 100.

6.2 Rule weights: TM-STR 35; TM-NET 30; SCR-SAN 30 (Near Match) or 50 (Potential True Match); TM-GEO 25; TM-DOR 20; TM-INC 20; TM-RIO 20; TM-VEL 15; TM-RND 10; SCR-PEP 10; adverse media hit 10; KYC risk tier HIGH 10.

6.3 Score bands: 0 to 39 LOW (no action unless analyst judgement requires it); 40 to 69 MEDIUM (Level-1 review within 5 working days); 70 and above HIGH (Level-2 review and Principal Officer visibility within 2 working days).

6.4 Every score shown to a user must be accompanied by its breakdown, for example "Score 85 = TM-STR 35 + SCR-SAN 30 + TM-RIO 20".

## 7. Alert Handling and Investigation

7.1 Level-1 review. An analyst reviews each alert, gathers evidence (transaction IDs, KYC documents, analyst and call notes, adverse media) and records a disposition within five (5) working days.

7.2 Escalation. Alerts that cannot be satisfactorily explained are escalated to Level-2 (Compliance Head). Workflow states: OPEN, UNDER_REVIEW, ESCALATED, STR_FILED, CLOSED_FALSE_POSITIVE, CLOSED_NO_ACTION.

7.3 Closure. Closing an alert as a false positive requires a written rationale that cites the evidence relied upon (for example GST returns, audited financials, sale agreements) and the Policy clause concerned. Closure without rationale is a breach of this Policy.

7.4 Maker-checker. STRs and closures of HIGH band alerts require two people: a maker (analyst) who drafts and a checker (Compliance Head or Principal Officer) who approves. The same person cannot be maker and checker on a Case.

7.5 Evidence standard. Every finding in a case memo or STR must reference specific transaction IDs and the Policy clause breached. Statements that cannot be supported by evidence must be marked as "insufficient evidence".

## 8. Suspicious Transaction Reporting

8.1 Timeline. The Principal Officer must file an STR with FIU-IND within seven (7) working days of arriving at a conclusion that a transaction or series of transactions is suspicious.

8.2 No threshold. There is no minimum amount for an STR. Attempted transactions must also be reported.

8.3 Contents. An STR must include: customer and account identifiers; a summary of the suspicion; the grounds of suspicion with transaction IDs, dates, amounts and channels; the typology (e.g. structuring, layering, mule network); the Policy clause and rule triggered; actions taken (e.g. EDD, account restrictions); and the recommendation.

8.4 Tipping-off. Employees must not disclose to the customer or any third party that an STR has been or may be filed. Accounts may continue to operate unless a freeze is required under Section 5.2.

8.5 Recommendations available to investigators: FILE STR; ENHANCED DUE DILIGENCE AND CONTINUE MONITORING; RESTRICT ACCOUNT PENDING RE-KYC; CLOSE AS FALSE POSITIVE.

## 9. Record Keeping and Audit Trail

9.1 Transaction records, KYC records, alerts, case files, STRs and their working papers are retained for at least five (5) years after the end of the business relationship or the date of the transaction, whichever is later.

9.2 Every query, decision, generated report and approval in the investigation system must be logged with the user, role, timestamp, data accessed and sources cited, so that an auditor can reconstruct how each conclusion was reached.

## 10. Governance and Data Protection

10.1 Access to customer data follows least privilege. Analysts see masked personal identifiers (name, PAN, phone, account number) unless unmasking is required for a specific case. The Compliance Head and Principal Officer may view full data. Auditors have read-only access including the audit log.

10.2 Analysts may only access customers of branches within their assigned region unless a case is reassigned.

10.3 This Policy is reviewed annually by the Board Risk Committee or earlier on regulatory change.
