# `/gaia-test-dast` LLM Severity Rubric

> Loaded by Phase 3B (forked LLM judgment) of `/gaia-test-dast`.
> Categories and severity tiers consumed by `verdict-resolver.sh`.

## Categories

| Category               | Description                                                                                                    |
|------------------------|----------------------------------------------------------------------------------------------------------------|
| `dast.runtime-vuln`    | Runtime vulnerability detected by the DAST scanner — e.g., reflected/stored XSS, SQL injection, SSRF, IDOR.    |
| `dast.config`          | Misconfiguration class — missing security headers (CSP, HSTS, X-Frame-Options), permissive CORS, weak TLS.    |
| `dast.compliance`      | Compliance / regulatory finding — PCI-DSS, HIPAA, SOC2 attribute that is materially impacted by a finding.   |
| `dast.coverage`        | Scan-coverage gap — declared endpoints not crawled, authenticated routes not exercised, scope mis-match.      |

## Severity tiers

| Tier        | Definition                                                                                       | ZAP source severity (typical)   |
|-------------|--------------------------------------------------------------------------------------------------|---------------------------------|
| Critical    | Confirmed exploitability against a production-equivalent environment; CVSS ≥ 9.0 or chain leads to RCE/data exfil. | High (Confidence: High)         |
| High        | Highly likely exploitable; OWASP Top 10 Active findings; CVSS 7.0–8.9.                          | High (Confidence: Medium/High)  |
| Medium      | Plausible exploitability with prerequisites; CVSS 4.0–6.9; missing standard hardening header.   | Medium                          |
| Suggestion  | Informational, hygiene, or low-impact finding; CVSS < 4.0; cache/header advisories.             | Low / Informational             |

## Mapping precedence

`verdict-resolver.sh` applies the following precedence in computing the final
verdict (first match wins):

1. `errored` toolkit check (`checks[].status == "errored"`) → BLOCKED.
2. Tool-failed-blocking finding (`adapter run.sh` exit ≠ 0) → BLOCKED.
3. LLM Critical finding (`severity == "Critical"`) → REQUEST_CHANGES.
4. Otherwise → APPROVE.

The LLM MUST NOT compute or override the verdict in natural language; the
resolver is the single source of truth.

## Rubric notes

- ZAP "Informational" alerts MUST NOT escalate to Critical or High under any
  circumstance — they map to Suggestion only. Escalation to Medium is allowed
  only when the LLM determines the alert is part of a chain with a higher-
  severity finding.
- A `dast.coverage` Critical finding is reserved for the case where the scan
  failed to crawl the declared `target_url` entirely (zero requests issued) —
  this distinct from `errored` because the run.sh exit was 0 but the result
  set is empty in a way that materially undermines the verdict.
- Compliance findings (`dast.compliance`) inherit the maximum severity of the
  underlying technical finding; the rubric does not invent compliance
  severity independently.
