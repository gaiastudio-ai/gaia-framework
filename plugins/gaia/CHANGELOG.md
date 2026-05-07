# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.134.1] — 2026-05-04

### Fixed

- (E53-S233) accept legacy epics/index.md sharded layout in validate-gate.sh

## [1.134.0] — 2026-05-03

### Added

- (E53-S233) teach validate-gate.sh to accept sharded planning-artifact layouts (#408)
- (E38-S10) add inject subcommand to sprint-state.sh (#405)

### Fixed

- (E29-S8) substitute {project-root} placeholder in v1->v2 migrator (#406)
- (E29-S9) add placeholder-detection guard to resolve-config.sh (#407) — defense-in-depth companion to E29-S8; auto-classifier missed this entry because the squash commit's title didn't conform to Conventional Commits prefix; manually added.

### Maintenance

- (chore) remove misfiled story artifacts and {project-root} shim (#404) — sprint-36 cleanup of two production incidents from the {project-root} placeholder bug; companion to the four fixes above.

## [1.133.0] — 2026-05-03

### Added

- (E28-S181) add sidecar schema-drift detection to gaia-migrate (#398)
- (E29-S6) extend dead-reference-scan allowlist for skill setup.sh / finalize.sh (#394)
- (E20-S20) extract safe_grep_log() shell helper (#393)
- (E65-S8) absorb severity rubric format into gaia-code-review-standards (#392)
- (E65-S7) migrate gaia-performance-review to seven-phase Evidence/Judgment template (#391)
- (E65-S6) migrate gaia-test-review to seven-phase Evidence/Judgment template (#390)
- (E65-S5) migrate gaia-test-automate to hybrid seven-phase + ADR-051 template (#389)
- (E65-S4) migrate gaia-qa-tests to seven-phase Evidence/Judgment template (#388)
- (E65-S3) migrate gaia-security-review to seven-phase Evidence/Judgment template (#387)
- (E60-S5) resolve-config.sh --all batch mode + session-scoped cache (#384)
- (E28-S223) require reproduction snippet in triage findings (#383)
- (E28-S219) wire Fix workspace-guard hole in e45-s8-adr-finalize-che (#382)
- (E28-S222) wire Refresh cluster-9 C9-FIXTURE-fake.md frozen-date li (#381)
- (E62-S3) add claude-opus-4-7 to _SCHEMA.md model enum (#379)
- (E63-S12) slugify.sh --help emits canonical Usage block (fix E63-S1 (#378)
- (e65-s1) review-skill template foundation with shared scripts, schema, and severity rubric (#377)

### Changed

- (E9-S26) sweep legacy _memory/tier2-results paths and document Step 14 (#397)
- (E28-S220) document bun test:bats vs bare bats fallback

### Fixed

- (F-S231-DEDUP) dedup story-file resolver matches by realpath (#401)
- (F-S225-PATH-RESOLVER) support epic-grouped story file layout (#400)
- (E64-S2) tighten dod-check.sh test resolver and subtask scope (#396)

## [1.132.0] — 2026-04-29

### Added

- (create-story) thin-orchestrator rewrite + e2e + token-savings benchmark (E63-S11) (#374)
- (create-story) migrate SKILL.md + setup.sh to resolve-config.sh (E60-S3) (#366)
- (create-story) add scaffold-story.sh + bats (E63-S9) (#363)
- (create-story) add append-edge-case-tests.sh + bats (E63-S8) (#362)
- (create-story) add append-edge-case-acs.sh + bats (E63-S7) (#361)
- (create-story) add validate-frontmatter.sh + bats (E63-S5) (#360)
- (create-story) add validate-ac-format.sh + bats (E63-S6) (#359)
- (create-story) add validate-canonical-filename.sh + bats (E63-S4) (#358)
- (create-story) add generate-frontmatter.sh + bats (E63-S3) (#357)
- (create-story) add next-story-id.sh + bats (E63-S2)
- (create-story) add deterministic slugify.sh and bats coverage (E63-S1) (#355)
- (E62-S2) pin validator.md model to claude-opus-4-7 + document Val opus-pin contract
- (E62-S1) pin model claude-opus-4-7 + effort high in 10 Val-dispatching skills (#353)
- (E60-S1) add four flat artifact-path keys to project-config.yaml (#351)
- (E61-S2) wire gaia-create-story Step 4 to read sizing_map for points derivation (#350)
- (E61-S1) add sizing_map block to project-config.yaml + reclassify in MIGRATION (#349)
- (E64-S1) wire Dev-story tooling quirks cleanup (#345)
- (dev-story) rewrite gaia-run-all-reviews skill as thin orchestrator with --force flag (E58-S6) (#342)
- (dev-story) wire script invocations into SKILL.md Steps 1/10/11 (E57-S8) (#341)
- (dev-story) review-runner.sh true orchestration harness (E58-S5) (#339)
- (dev-story) add pr-body.sh and commit-msg.sh (E57-S7) (#336)
- (dev-story) add promotion-chain-guard.sh and check-deps.sh (E57-S6) (#335)
- (dev-story) add tdd-review-gate.sh decision script (E57-S2) (#334)
- (dev-story) add story-parse.sh and detect-mode.sh (E57-S5) (#331)
- (agents) add tdd-reviewer fork-context subagent (E57-S3) (#330)

### Changed

- (e38-s1-reconcile-risk) migrate CATALOG fixture to per-test TEST_TMP path (E38-S5) (#371)
- (retro) swap action-items-increment.sh for shared writer delegation (E36-S5) (#370)
- (skills) reconcile action-items.yaml path to planning-artifacts (E36-S4) (#369)
- (resolve-config) replace frozen-date literals with sentinel (E28-S214) (#368)
- (config) document four artifact-path keys in migration doc (E60-S4) (#367)
- (skills,claude-md) add status-edit discipline critical rule (E59-S4) (#365)
- (E60-S2) bats coverage for the four artifact-path keys (#352)
- (E59-S3) delete update-story-status.sh deprecation wrappers (#348)
- (E59-S2) update bats tests for wrapper removal (#347)

### Fixed

- (dev-story) close E57-S8 ac4 integration smoke gap (e57-s8) (#344)
- (dev-story) close E57-S8 ac5 absence-assertion gap (e57-s8) (#343)

## [1.131.0] — 2026-04-28

### Added

- (dev-story) step 6b conditional-check advisory hints (E55-S7) (#325)
- (dev-story) auto-reviews YOLO-only step 16 + 4 helper scripts + bats coverage (E55-S8) (#323)
- (dev-story) val-in-tdd single post-refactor pass (E55-S4) (#322)
- (dev-story) atdd gate + plan-structure validator + figma graceful-degrade (E55-S5) (#321)
- (dev-story) non-YOLO three-option planning gate (approve/revise/validate) (E55-S3) (#320)
- (dev-story) yolo val auto-validation loop with 3-iter cap and audit file (E55-S2) (#319)
- (dev-story) hard-halt planning gate via AskUserQuestion (E55-S1) (#317)

### Changed

- (yolo) add TC-AMG-1..5 conformance bats for ADR-067 disambiguation guard (E56-S1) (#324)

### Fixed

- (dev-story) emit step6b_gate stderr log + extend bats coverage (E55-S7)

## [1.130.0] — 2026-04-28

### Added

- (create-story) add YOLO param + non-YOLO [u]/[a] routing prompt (E54-S1) (#311)
- (create-story) restore V1 edge-case pipeline Steps 3b/3c/3d (E54-S4) (#310)
- (create-story) conditional ux-designer routing + parallel spawn (E54-S2) (#309)
- (scripts) unified transition-story-status.sh (E54-S3) (#308)

## [1.129.0] — 2026-04-27

### Added

- (teach-testing) operationalize JIT discipline + progressive gating
- (mobile-testing) add 90% device coverage rule and cloud config
- (scripts) producer-side token_estimate emit for val auto-fix loop (E44-S15)
- (skills) canonical document-rulesets for Phase 1 artifact types (E44-S12) (#289)
- (skills) inline-ask + scan-depth doc in /gaia-index-docs (E50-S4) (#287)
- (skills) inline confirm + slug algorithm in /gaia-merge-docs (E50-S3) (#286)
- (skills) inline-ask on empty arguments in /gaia-shard-doc (E50-S2) (#285)
- (skills) inline-ask + Next-Steps clarification in /gaia-summarize (E50-S1) (#284)
- (skills) per-dimension justification + migration trigger in /gaia-nfr (E49-S4) (#283)
- (skills) empty-context fallback interrogation in /gaia-problem-solving (E49-S3) (#282)
- (skills) severity prompt + rule table + fallback warning in /gaia-fill-test-gaps (E49-S2) (#281)
- (skills) explicit WCAG-level prompt + criterion mapping in /gaia-a11y-testing (E49-S1) (#280)
- (skills) inline AC linkage + pinned schemas in /gaia-test-gap-analysis (E48-S5) (#279)
- (skills) brownfield test-env pause + per-subagent scan diagnostics (E48-S4) (#278)
- (skills) add threat-model linkage to /gaia-review-security (E48-S3) (#277)
- (skills) plumb threat-model context into Zara dispatch (E48-S2) (#276)
- (skills) restore Val gate + assessment-doc in /gaia-add-feature (E48-S1) (#275)
- (skills) add /gaia-innovation native skill (E47-S2) (#274)
- (skills) add /gaia-design-thinking native skill (E47-S1)
- (E46-S10) narrow product-brief INDEX_GUIDED scope to brainstorm
- (E46-S9) add /gaia-product-brief plugin template and analyst assignment
- (E46-S2) restore /gaia-create-ux Import mode + read-only FR-140 audit (#270)
- (E46-S1) restore /gaia-create-ux Generate mode + FR-140 audit
- (E46-S4) readiness-check priority/schedule + compliance + self-contradiction (#268)
- (E46-S8) document /gaia-adversarial Step 4 invocation contract
- (E46-S7) add /gaia-ci-setup schema validation retry loop (#266)
- (E46-S6) add /gaia-create-arch tech-stack pause + ADR sidecar write
- (E46-S5) add /gaia-edit-test-plan orchestrator trigger inheritance
- (E46-S3) add /gaia-atdd batch mode, red-phase, and graceful exit
- (E45-S5) add VCP-MEM-04 ADR-061/ADR-057 scope-boundary regression test
- (E44-S9) add NFR-VCP-2 token-budget verification harness
- (E44-S8) document Val auto-fix iteration log format and witness via VCP-FIX-07
- (E44-S6) wire Val auto-review into 3 Phase 3 Testing artifact skills
- (E44-S5) wire Val auto-review into 6 Phase 3 Solutioning artifact skills
- (E44-S4) wire Val auto-review into 3 Phase 2 + product-brief skills
- (E44-S3) wire Val auto-review into 4 Phase 1 artifact skills (#252)
- (E45-S3) auto-save session memory at finalize for 24 Phase 1-3 skills (#251)
- (E45-S1) static `## Next Steps` sections for 10 lifecycle skills (#250)
- (E45-S4) declare discover-inputs strategy on 6 lifecycle skills
- (E45-S2) quality gates pre_start/post_complete in setup.sh/finalize.sh
- (E41-S1) yolo mode contract helper + framework lint (ADR-057)
- (E44-S7) open-question detection helper + wire into 18 skills
- (E28-S182) add SIGINT/SIGTERM trap handler to gaia-migrate.sh
- (E42-S15) port /gaia-test-framework + /gaia-atdd + /gaia-ci-setup checklists to V2
- (E42-S14) port /gaia-edit-test-plan and /gaia-test-design checklists to V2
- (E42-S13) port /gaia-readiness-check 65-item checklist to V2
- (E42-S12) port /gaia-infra-design 25-item checklist to V2
- (E42-S11) port /gaia-threat-model 25-item checklist to V2 (#235)
- (E42-S10) port /gaia-create-epics 31-item checklist to V2 (#234)
- (E42-S9) port /gaia-edit-arch 25-item checklist to V2
- (E42-S8) port /gaia-create-arch 33-item checklist to V2
- (E42-S7) port /gaia-create-ux 26-item checklist to V2
- (E42-S6) port /gaia-create-prd 36-item checklist to V2
- (E42-S5) port /gaia-product-brief 27-item checklist to V2
- (E42-S4) port /gaia-tech-research 22-item checklist to V2
- (E42-S3) port /gaia-domain-research 22-item checklist to V2
- (E42-S2) port /gaia-market-research 28-item checklist to V2
- (E42-S1) port /gaia-brainstorm 24-item checklist to V2
- (E43-S6) /gaia-resume ADR-059 JSON consumption contract
- (E43-S7) checkpoint failure-mode handling (corruption, partial writes)
- (E43-S5) wire checkpoint writes into 8 Phase 3 Testing skills
- (E43-S4) wire checkpoint writes into 8 Phase 3 Solutioning skills
- (checkpoint) wire write-checkpoint.sh into Phase 2 skills (E43-S3)
- (checkpoint) wire write-checkpoint.sh into Phase 1 skills (E43-S2)
- (checkpoint) add write-checkpoint.sh schema v1 helper (E43-S1)
- (release) automate plugin release on staging-to-main merge

### Changed

- (skills) review-deps runtime-first ordering + tier collapse (E52-S11)
- (skills) perf-testing baseline mandate + CRP techniques (E52-S8)
- (skills) memory-hygiene token recovery + cross-agent matrix (E52-S7)
- (skills) ci-edit cascade targets + failure surfacing (E52-S6)
- (skills) performance-review percentiles + file logging (E52-S5)
- (skills) project-context TRUNCATED marker + inference (E52-S4)
- (skills) document-project manifest entries + counts (E52-S3)
- (skills) changelog version validation + excluded commits (E52-S2)
- (skills) refresh-ground-truth budget check + entry schema (E52-S1)
- (skills) editorial-structure doc-type conventions (E51-S2)
- (skills) document editorial-prose default save behaviour (E51-S1)
- (sprint-state) add wrapper-sync invariant bats test (E38-S6)
- (E29-S7) allowlist V1 checkpoint deletion plan fixture in dead-reference-scan
- (E29-S7) add V1 checkpoint deletion plan + sunset window
- (E45-S8) scrub V1-engine references from ADR-068 fixture for ADR-048 guard
- (E45-S8) pin canonical finalize-checklist.sh contract in ADR-068
- (E45-S6) add bats wall-clock budget-watch invariant
- (E44-S2) implement Val auto-fix loop pattern (ADR-058)
- (E44-S1) formalize /gaia-val-validate upstream integration contract
- (E38-S8) add direct unit tests for canonical_states_hint and assert_canonical_state
- (E43-S6) complete NFR-052 public-function coverage signal
- (E43-S7) add NFR-052 coverage signal for resume-discovery.sh public functions
- (bats-tests) bump job timeout from 2m to 5m for growing bats suite
- (E43-S5) consolidate per-skill step-count tests to fit 2-min CI cap
- (checkpoint) declare NFR-052 coverage signal for helper functions
- (checkpoint) harden AC-EC7 PATH isolation for Linux CI
- (changelog) note ADR-056 pivot to PR-based release model

### Fixed

- (skills) scrub legacy core/engine ref from refresh-ground-truth (E52-S1)
- (tests) stabilize flaky TC-VSP-7 perf test (E34-S3) (#290)
- (skills) align tech-research artifact_type slug with filename (E44-S11) (#288)
- (E46-S8) rename contract heading to avoid Step-N count inflation
- (E46-S6) keep gaia-create-arch checkpoint count at 13 (sub-steps no-emit)
- (E45-S7) replace BSD/mawk-incompatible awk word boundaries with portable form
- (E44-S8) skip test-plan.md row checks when project-root is unavailable
- (E45-S2) seed brainstorm fixture in audit and cluster-4 e2e harnesses
- (E41-S1) mark yolo-lint internal helpers private
- (E44-S7) mark detect-open-questions internal helpers private
- (E38-S8) sprint-state transition emits canonical enum hint and guards writers
- (E38-S7) tighten sprint-state reconcile glob to require story frontmatter
- (E42-S14) scrub legacy-engine path refs from finalize.sh comments
- (E42-S13) make finalize.sh opt-in and tests self-contained
- (checkpoint) scrub workflow.xml reference from write-checkpoint.sh header

## [1.128.0] — 2026-04-23

### Added

- (release) pivot release.yml to PR model + ADR-056 (E40-S1)

## [1.127.2] — 2026-04-23

### Added

- Release automation pipeline (E40-S1 / ADR-056). The first automated release will land in v1.128.0.

### Changed

- **ADR-056 amendment (2026-04-23):** `release.yml` pivoted from direct-bot-push to a PR-based model. Branch protection on `main` requires PR + status checks, which the original direct-push design could not satisfy. The workflow now has two modes — `prepare` (opens a `release/vX.Y.Z` PR on qualifying commits to main) and `publish` (cuts tag + GitHub Release when the release PR merges). Manual work per release: one click to merge the release PR.

Initial changelog seeded by E40-S1. Prior history available via `git log --oneline -- plugins/gaia/`.
