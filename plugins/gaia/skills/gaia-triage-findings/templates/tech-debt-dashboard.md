# Tech Debt Dashboard

> **Project:** {project_name}
> **Date:** {date}
> **Sprint:** {sprint_id}

---

## Summary

| Metric | Value |
|--------|-------|
| Total debt items | {total_count} |
| FIX NOW | {fix_now_count} |
| PLAN NEXT | {plan_next_count} |
| TRACK | {track_count} |
| Overdue (SLA breach) | {overdue_count} |
| STALE TARGET | {stale_count} |
| UNASSIGNED | {unassigned_count} |
| Debt ratio (debt / total backlog) | {debt_ratio}% |

## By Category

| Category | Count | Oldest (sprints) |
|----------|-------|------------------|
| Design | {design_count} | {design_oldest} |
| Code | {code_count} | {code_oldest} |
| Test | {test_count} | {test_oldest} |
| Infrastructure | {infra_count} | {infra_oldest} |

## Aging Distribution

```
{aging_histogram}
```

## Top 10 Debt Items

| Rank | ID | Item | Category | Source | Target | Resolution | Impact | Effort | Risk | Score | Age | Priority | Action |
|------|----|----|----------|--------|--------|------------|--------|--------|------|-------|-----|----------|--------|
{top_items_rows}

**Scoring:** Score = Impact (1-5) + Risk of Inaction (1-5) - Effort (1-5). Higher = fix sooner.

## Overdue Alerts

{overdue_alerts}

**SLA thresholds:** FIX NOW > 1 sprint = OVERDUE | PLAN NEXT > 3 sprints = escalate | TRACK > 5 sprints = review relevance

## Target Validation Issues

{target_issues}

## Trend (vs Previous Review)

| Metric | Previous | Current | Delta |
|--------|----------|---------|-------|
| Total items | {prev_total} | {curr_total} | {delta_total} |
| FIX NOW | {prev_fix} | {curr_fix} | {delta_fix} |
| Resolved since last | — | {resolved_count} | — |
| New since last | — | {new_count} | — |

## Recommended Actions

{recommendations}

---

> Run `/gaia-correct-course` to inject high-priority debt items into the current sprint.
> Run `/gaia-triage-findings` first if there are untriaged findings pending.
