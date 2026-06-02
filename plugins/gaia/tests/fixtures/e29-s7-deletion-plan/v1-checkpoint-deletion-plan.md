---
template: 'planning-artifact'
type: 'deletion-plan'
key: 'v1-checkpoint-deletion-plan'
title: 'V1 Checkpoint Deletion Plan + Sunset Window'
status: 'proposed'
date: '2026-04-25'
author: 'dev-story (E29-S7)'
story_ref: 'E29-S7'
adr_refs: ['ADR-049', 'ADR-042', 'ADR-048', 'ADR-059']
sprint_id: 'sprint-28'
---

# V1 Checkpoint Deletion Plan + Sunset Window

## Purpose

Define a safe, auditable cleanup of legacy V1 (workflow.xml-engine-era)
checkpoints that remain on disk under `_memory/checkpoints/` after the
ADR-049 V1 sunset (2026-04-20). The V1 engine is retired, the V2 ADR-059
checkpoint format is now canonical, and the legacy artifacts are no longer
written to or read from in any active flow. This document recommends the
sunset window, the inventory script, the archive-vs-delete policy, and the
coordination contract with `/gaia-resume`.

This is a planning artifact only. A separate execution story (filed as the
DoD action item) will carry out the actual deletion.

## Scope

In scope:

- All checkpoint files written by the V1 `workflow.xml` engine prior to
  2026-04-20 (ADR-049 sunset date).
- The `_memory/checkpoints/completed/` archive subtree of V1-era
  checkpoints.
- Legacy `.json` checkpoints from pre-E28 ADR-059 work (38 files,
  pre-`atdd`/early V1 era).

Out of scope:

- V2 ADR-059 per-skill JSON checkpoints under
  `_memory/checkpoints/{skill}/` (these are the canonical active format).
- Validator sidecar memory under `_memory/validator-sidecar/`.
- Agent sidecar memory under `_memory/{agent}-sidecar/`.

## Inventory (as of 2026-04-25)

Directory: `_memory/checkpoints/`

| Bucket | Count | Format / Shape | V1 / V2 |
|---|---:|---|---|
| Flat `*.yaml` (root) | 832 | V1 free-form YAML — `workflow:` / `step:` / `files_touched:` keys | V1 |
| Flat `*.md` (root) | 164 | V1 narrative checkpoints (atdd, qa-tests, performance-review) | V1 |
| Flat `*.json` (root) | 38 | Pre-E28 legacy JSON (atdd-E13-S5, add-stories-AF-2026-04-06-4-*) | V1 (proto) |
| `completed/` subtree | 840 | Archived V1 checkpoints from finished workflows | V1 (archived) |
| `active/` subtree | 0 | Reserved for V2 ADR-059 active dispatch | V2 |
| `create-story/`, `dev-story/` | <5 | V2 per-skill ADR-059 JSON | V2 |
| **Total entries at root** | **1038** | mixed | mostly V1 |

V1-shape markers used to classify a file as a V1 checkpoint:

1. Located directly under `_memory/checkpoints/` (NOT inside a per-skill
   subdirectory like `dev-story/` or `create-story/`).
2. Filename matches one of the V1 patterns:
   `{workflow}-{key}.yaml`, `{workflow}-{date}.yaml`,
   `{key}-{workflow}.checkpoint.yaml`, `{workflow}-{key}.md`,
   `{workflow}-{key}.json`, or any flat name predating ADR-059.
3. Schema marker (if YAML): top-level `workflow:` key paired with a
   numeric `step:` key and an optional `files_touched:` list — the V1
   checkpoint shape produced by the workflow.xml engine.
4. File mtime predates 2026-04-20 (the ADR-049 sunset cutoff). Any file
   newer than the cutoff under the flat root is treated as
   non-conforming and surfaced for manual review (it should not exist —
   V2 writes go into per-skill subdirectories).

The `completed/` subtree is treated as a single bucket of V1 archives —
its 840 entries follow the same schema as the active flat-root V1 files;
they were moved by V1 workflow completion routines that are no longer
running.

## Recommended Sunset Window

ADR-049 sunset date: **2026-04-20**.

| Phase | Window | Action |
|---|---|---|
| T+0 (sunset) | 2026-04-20 | V1 engine retired. No new V1 checkpoints written. (Already in effect.) |
| Soak | 2026-04-20 → 2026-05-20 (30 days) | Read-only soak. No deletes. `/gaia-resume` continues to read V1 YAMLs for any in-flight resume request. Inventory script (below) runs weekly and snapshots the V1 set. |
| Cutoff | **2026-05-20** | Hard cutoff. Any V1 checkpoint not promoted, not archived externally, and not still referenced is deleted in the execution story. |
| Grace | 2026-05-20 → 2026-06-20 | Grace period — `/gaia-resume` returns "no active workflows to resume" for any deleted V1 checkpoint name (no crash, see Coordination below). External tarball retained off-tree. |

Rationale for 30 days: the soak window covers a full sprint cycle plus a
buffer. If any V1 checkpoint were still required by an in-flight
workflow, it would surface in that window through a `/gaia-resume`
attempt — no V1 engine activity has been observed since 2026-04-20,
giving high confidence the bucket is dormant.

## Inventory Script (Recommendation)

To be added by the execution story under
`gaia-public/plugins/gaia/scripts/v1-checkpoint-inventory.sh`. Contract:

```
v1-checkpoint-inventory.sh [--format text|json] [--output PATH]

  Exit 0  — inventory printed (or written to PATH).
  Exit 1  — read failure on _memory/checkpoints/.
```

Behavior:

1. Walk `_memory/checkpoints/` (NOT recursing into the V2 per-skill
   subdirectories enumerated in `_memory/config.yaml`).
2. For each file at the root and under `completed/`, emit one record:
   `path`, `size_bytes`, `mtime_iso`, `format` (`yaml`/`md`/`json`),
   `v1_marker_match` (boolean — schema marker check on YAML).
3. Summary footer with counts by bucket and total bytes.
4. JSON mode produces a machine-readable manifest the execution story
   can checksum and archive alongside the deletion log.

## Archive-vs-Delete Policy

Each V1 checkpoint falls into one of two cases:

| Case | Criterion | Action | One-sentence rationale |
|---|---|---|---|
| Archive-then-delete | File references a story in `done` status whose Review Gate row is PASSED, OR the file lives in `completed/` | Tar the bucket to an off-tree artifact (`v1-checkpoints-archive-2026-05-20.tar.zst`), checksum it, then delete the on-disk files | Preserves a forensic trail for any retroactive audit (sprint retros, traceability re-derivation) without keeping cold data in the working tree. |
| Straight-delete | File references a story that was retired by the ADR-049 sweep (E29-S2 sweep log) or a workflow that no longer exists in the V2 manifest, OR the file is a corrupted/zero-byte artifact | Delete in place — no archive | The referenced story or workflow is gone; the checkpoint has no recoverable consumer and archiving stale pointers adds noise without value. |

The execution story emits a deletion log
(`docs/planning-artifacts/v1-checkpoint-deletion-log-{date}.md`)
recording every path deleted, its case, the inventory hash, and the
archive tarball checksum (where applicable).

## Coordination with `/gaia-resume`

`/gaia-resume` already dispatches by file extension (`.yaml` → V1 legacy
path, `.json` → V2 ADR-059 path) per its SKILL.md Step 3, and explicitly
excludes the `completed/` subtree from the active-workflow list. The
deletion plan must preserve three guarantees against that contract:

1. **No-crash on missing legacy checkpoint.** When a user invokes
   `/gaia-resume {name}` for a V1 checkpoint that has been deleted,
   the Glob in Step 1 returns zero matches and the skill prints
   `No active workflows to resume.` — the existing happy-path. The
   execution story MUST NOT introduce a stub file or sentinel that
   would cause the dispatcher to attempt to parse a missing
   checkpoint.
2. **No silent V2 collision.** The deletion sweep operates only on
   files at the flat root and under `completed/`. It MUST NOT touch
   any per-skill subdirectory enumerated by
   `resume-discovery.sh` (V2 ADR-059 dispatch surface).
3. **Pre-flight resume scan.** Immediately before the cutoff date the
   execution story runs `resume-discovery.sh` and `checkpoint.sh
   list` once more, and aborts the delete if any V1 YAML is reported
   as a resumable active workflow — the soak window assumption is
   then violated and the cutoff is rescheduled.

A regression test should be filed against `/gaia-resume` to assert that
Glob returning zero V1 matches yields the no-active-workflows path
without any stderr noise or non-zero exit (see action items below).

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| In-flight V1 workflow exists undetected | Low | Medium — lost resume state | 30-day soak + pre-cutoff `resume-discovery.sh` scan + 1-month off-tree archive retention |
| Archive tarball corruption | Very low | Low — forensic trail only | sha256 checksum recorded in deletion log, tar verified post-write |
| Future audit needs old checkpoint contents | Low | Low | Archive tarball retained 90 days off-tree; sweep log + deletion log preserved in-tree |
| Sweep deletes a V2 file by mistake | Very low | High — active workflow loss | Inventory script excludes V2 per-skill subdirectories; deletion script reuses the same exclusion list with explicit allowlist of `_memory/checkpoints/*.{yaml,md,json}` and `_memory/checkpoints/completed/**` only |

## Verification

The execution story is complete when:

1. `_memory/checkpoints/` contains zero V1-shape files at the flat root.
2. `_memory/checkpoints/completed/` is empty (or removed).
3. The archive tarball exists off-tree with a recorded sha256 in the
   deletion log.
4. `/gaia-resume` invoked with no arguments returns the
   `No active workflows to resume.` message OR shows only V2 per-skill
   checkpoints — no V1 entries.
5. The post-deletion inventory script reports zero V1 matches.

## Open Questions

- [x] Are any V1 checkpoints still actively referenced by an in-flight
      workflow? **Resolved during soak**: a `resume-discovery.sh` /
      `checkpoint.sh list` scan run on the day before cutoff is the
      authoritative answer; if any V1 entry is reported as resumable,
      the cutoff slips by one sprint and this question re-opens.
- [ ] Should the off-tree archive retention extend beyond 90 days for
      compliance / audit trail reasons? Defer to the execution story's
      DoD review.

## Action Items (filed by this story's DoD)

1. **File the V1 checkpoint deletion execution story** under E29 — V1
   Sunset, sized S/2 points, scheduled for sprint-29 (after the
   2026-05-20 cutoff). The story owns the inventory script, the
   archive-then-delete sweep, the deletion log, and the `/gaia-resume`
   no-active-workflows regression test.
2. **Add a one-line note to ADR-049** referencing this deletion plan
   so the V1 sunset trail closes cleanly.
3. **Schedule the cutoff in `_gaia/_config/global.yaml`** (or wherever
   sprint-29 planning artifacts land) as a sprint-29 commitment so it
   surfaces in `/gaia-sprint-status`.
