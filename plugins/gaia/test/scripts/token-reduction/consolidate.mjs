#!/usr/bin/env node
/**
 * consolidate.mjs — read every {workflow}/{baseline,native}.token-count.json
 * under .gaia/artifacts/test-artifacts/cluster-19/token-budget/, compute reductions and
 * aggregates, and re-emit the per-workflow table into
 * .gaia/artifacts/test-artifacts/cluster-19/token-reduction-results.md.
 *
 * This is informational — the committed results.md is hand-authored to match
 * the formula exactly and to include narrative context. consolidate.mjs is
 * the reference implementation of the formulas (AC4) and is used by the
 * bats test to verify the consolidator did not introduce abs() hiding
 * (AC-EC6).
 */

import { readFileSync, existsSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const DRIVER_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(DRIVER_DIR, "..", "..", "..", "..", "..");
const GAIA_ROOT = resolve(REPO_ROOT, "..");
const TOKEN_BUDGET = join(GAIA_ROOT, "docs", "test-artifacts", "cluster-19", "token-budget");

const WORKFLOWS = ["dev-story", "create-prd", "code-review", "sprint-planning", "brownfield-onboarding"];

export function consolidate() {
  const rows = [];
  for (const wf of WORKFLOWS) {
    const failurePath = join(TOKEN_BUDGET, wf, "failure.log");
    if (existsSync(failurePath)) {
      rows.push({ workflow: wf, measurement_failed: true });
      continue;
    }
    const b = JSON.parse(readFileSync(join(TOKEN_BUDGET, wf, "baseline.token-count.json"), "utf-8"));
    const n = JSON.parse(readFileSync(join(TOKEN_BUDGET, wf, "native.token-count.json"), "utf-8"));
    if (b.tokens <= 0) throw new Error(`${wf} baseline_tokens must be positive, got ${b.tokens}`);
    const delta = b.tokens - n.tokens;
    const reductionPct = (delta / b.tokens) * 100;
    // one-decimal rounding — we preserve the sign (AC-EC6: no abs()).
    const pretty = Math.round(reductionPct * 10) / 10;
    const nfr048 = reductionPct >= 40 ? "PASS" : "FAIL";
    const stretch = reductionPct >= 55 ? "PASS" : "warn";
    rows.push({
      workflow: wf,
      baseline_tokens: b.tokens,
      native_tokens: n.tokens,
      delta,
      reduction_pct: pretty,
      nfr048,
      stretch,
    });
  }
  const passing = rows.filter(r => !r.measurement_failed).map(r => r.reduction_pct);
  const aggregate = passing.length
    ? Math.round((passing.reduce((s, x) => s + x, 0) / passing.length) * 10) / 10
    : 0;
  const overallFail = rows.some(r => r.measurement_failed || r.nfr048 === "FAIL");
  const verdict = overallFail ? "FAIL" : "PASS";
  return { rows, aggregate, verdict };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const out = consolidate();
  process.stdout.write(JSON.stringify(out, null, 2) + "\n");
}
