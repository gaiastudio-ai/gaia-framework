# Perf Quality Rubric — `/gaia-test-perf` Phase 3B

> JIT-loaded by Phase 3B LLM judgment. Categories and severity tiers conform
> to the LLM-cannot-override invariant. The LLM applies this rubric on
> top of the deterministic Phase 3A `analysis-results.json` artifact and the
> SLO/baseline overlays — it CANNOT override an `errored` toolkit check or a
> deterministic SLO breach.

## Categories

Perf findings are organized into four orthogonal categories:

1. **SLO** — restatement of breaches surfaced by `slo-check.sh`. The LLM
   classifies each breach as Critical (any p95 / error-rate breach on a
   declared scenario) or High (RPS shortfall) and explicitly emits a
   no-breach finding when none.
2. **Regression** — interpretation of baseline regression annotations from
   `baseline-check.sh`. Critical when degradation > 2× threshold, High at
   threshold, Medium below threshold.
3. **Throughput consistency** — coefficient of variation across virtual-user
   ramps in k6 summaries. High variance hides intermittent saturation.
4. **Browser perf opportunities** — Lighthouse audits surfaced as
   "opportunities" (TBT, render-blocking resources, image opt). Suggestion
   tier unless the audit pushes a SLO metric over threshold.

## Severity Tiers

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not
> already block. Critical promotion is restricted to high-confidence
> regressions with deterministic evidence.

Examples:
- **SLO breach on critical scenario** — `slo-check.sh` reports `p95_latency_ms` 600 against 500 ms SLO for the login scenario.
- **Regression > 2× threshold** — `baseline-check.sh` reports 50% degradation against the 20% threshold.
- **Error rate > SLO** — k6 summary `http_req_failed` rate exceeds the declared `error_rate_max`.

### High

> Blocking unless justified. Verdict resolver weight: HIGH. The LLM may
> classify a finding as High only when reproducible across runs.

Examples:
- **RPS shortfall against `min_rps`** — k6 reports 80 rps against a 100 rps floor; saturating capacity.
- **Lighthouse `largest-contentful-paint` opportunity** — render-blocking inline CSS pushes LCP to 3.2 s against a 2.5 s SLO.
- **High variance across ramps** — coefficient of variation > 0.3 on p95 latency suggests an unstable load profile.

### Medium

> Non-blocking. Recorded in the report; does not flip the verdict on its own.

Examples:
- **Sub-threshold regression** — 10% degradation on a 20% threshold.
- **Lighthouse opportunity below SLO impact** — opportunity to save 200 ms on TBT but the metric is already within SLO.

### Suggestion

> Informational. Future-work, not gating.

Examples:
- **Image-format optimization** — Lighthouse suggests AVIF / WebP encoding.
- **Cache-policy improvements** — Lighthouse audit-only opportunity.

## LLM Output Contract

The fork emits `llm-findings.json` with:

```json
{
  "schema_version": "1.0.0",
  "skill": "gaia-test-perf",
  "findings": [
    {
      "category": "slo|regression|throughput|browser-opportunity",
      "severity": "Critical|High|Medium|Suggestion",
      "rule": "perf.<dotted.id>",
      "message": "<one-line summary>",
      "file": null,
      "line": 0,
      "metric": "<measured-metric>",
      "actual": <num>,
      "threshold": <num>
    }
  ]
}
```

## Cross-References

- `/gaia-test-e2e` reference rubric (`knowledge/e2e-rubric.md`).
