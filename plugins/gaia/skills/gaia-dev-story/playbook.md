# Dev-Story Playbook — LLM Reasoning Guide

This playbook contains the reasoning instructions for the dev-story skill. It guides the LLM through story comprehension, design decisions, test strategy, and self-review. All mechanical operations (git, checkpoints, sprint-state, sha256, PR, CI, merge) are handled by scripts — this file contains reasoning only.

## Story Comprehension

When loading a story file, reason about:

- **Epic context:** How does this story fit within the broader epic? What preceding stories has this epic already delivered? What does this story unblock?
- **Acceptance criteria mapping:** Map each AC to specific implementation actions. Identify which ACs are independent and which have dependencies.
- **Risk assessment:** For high-risk stories, identify the riskiest subtask and plan mitigation. Check for ATDD files that pre-define acceptance test scenarios.
- **Dependency validation:** Verify that all stories in the `depends_on` list are in `done` status. If any dependency is incomplete, flag it and ask whether to proceed.

## Mode Detection Reasoning

When determining the execution mode:

- **FRESH mode** (status: ready-for-dev): This is a clean-sheet implementation. No prior work exists. Plan from scratch using architecture and UX design context.
- **REWORK mode** (status: in-progress, failed reviews exist): Focus exclusively on what the reviews flagged. Do not re-implement passing areas. Read each failed review report and extract the specific issues to address.
- **RESUME mode** (status: in-progress, no failed reviews): Check the checkpoint for the last completed phase. Pick up from where the prior session left off. Validate that files touched in prior phases have not been modified externally (checksum verification).

## Design Approach

When planning the implementation:

- **Architecture alignment:** Read the relevant sections of architecture.md. Identify which ADRs apply to this story. Follow the patterns they prescribe. Flag any deviations with justification.
- **UX alignment** (frontend stories): Read the relevant sections of ux-design.md. Identify which screens, components, and interaction patterns apply. Reference specific wireframes or flow names.
- **File change analysis:** List every file that will be created, modified, or deleted. Group by new/modified/deleted. For each file, describe what changes and why.
- **Implementation ordering:** Determine the dependency order of changes. Identify which files can be changed independently (parallelizable) and which depend on others (sequential).
- **Minimal change principle:** Implement the minimum change needed to satisfy the acceptance criteria. Do not add features, refactor unrelated code, or make improvements beyond what was asked.

## Test Strategy

When writing tests in the Red phase:

- **AC-to-test mapping:** Each acceptance criterion maps to at least one test case. Create a mapping table before writing code.
- **Test type selection:** Choose the right level for each test — unit (isolated function behavior), integration (cross-module interaction), e2e (full user flow). Default to the lowest level that covers the AC.
- **Edge case coverage:** Beyond the ACs, consider boundary conditions, error paths, and concurrent access scenarios. Reference the story's AC-EC items if present.
- **Assertion quality:** Each test must assert specific observable behavior, not implementation details. A good test breaks when behavior changes, not when internals are refactored.
- **Naming convention:** Test names should read as behavior specifications: "given X, when Y, then Z" or "AC{n}: {description of expected behavior}".

## Self-Review Reasoning

Before marking the story complete, reason through:

- **Acceptance criteria verification:** Walk through each AC and verify it is demonstrably satisfied by the implementation. If an AC cannot be verified automatically, describe the manual verification step.
- **Definition of Done checklist:** Systematically check each DoD item. Do not mark an item as done without actually running the verification (build, test, lint, etc.).
- **Code quality assessment:** Review the code as if you were a peer reviewer. Look for: unclear naming, unnecessary complexity, missing error handling at boundaries, security concerns, performance implications.
- **Regression risk:** Consider whether any changes could break existing functionality. If the change touches shared utilities or APIs, verify that existing consumers are not affected.

## Review Gate Reasoning

When the story enters review status:

- **Review preparation:** Ensure the story file has a complete Review Gate table with all 6 rows initialized to UNVERIFIED.
- **Review scope:** Each review workflow examines a specific dimension — code quality, security, test coverage, test quality, performance, QA scenarios. The dev agent's self-review during DoD is not a substitute for these specialized reviews.
- **Failure response:** If any review returns FAILED, the story returns to in-progress. Read the specific findings, plan targeted fixes, and re-enter the TDD cycle for those fixes only.

## Post-Completion Gate Reasoning (SKILL.md Step 14)

After the dev-story subagent reports completion, the orchestrator must verify that a merge commit containing the story key actually exists on the target branch before accepting the result. This gate exists because two prior sprints saw subagents report completion while never pushing or merging — sprints closed with unmerged code. Reason about this gate as follows:

- **Gate purpose:** Trust-but-verify the subagent's self-reported `done`. The gate is a final integrity check, not a duplicate review.
- **Promotion-chain dependency:** The gate runs `verify-pr-merged.sh {story_key} {target_branch}` where `{target_branch}` is the first promotion-chain environment from `ci_cd.promotion_chain[0].branch`. If `ci_cd.promotion_chain` is absent, the script exits 3 (skip) and the gate passes silently — projects without a configured promotion chain are not penalized.
- **Word-boundary matching:** The script uses `\b{story_key}\b` regex anchors so `E20-S1` is not falsely matched by a merge commit referencing `E20-S19`. Matching is case-insensitive to tolerate squash-merge message rewrites.
- **Recovery path:** On exit 2 (no merge commit found), the orchestrator re-runs Steps 10–13 (commit, push, create PR, wait for CI, merge) in the main orchestrator context before advancing the story to `done`. Do not bypass the gate by hand-editing status — the gate exists precisely to catch the bypass case.
- **Sequencing invariant:** Step 14 runs BEFORE Step 16 (Auto-Reviews / YOLO). A story can never reach the auto-review aggregator without a verified merge commit on the target branch.
