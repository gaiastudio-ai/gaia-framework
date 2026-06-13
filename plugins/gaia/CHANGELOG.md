# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https:/keepachangelog.com/en/1.1.0).

## [1.192.1] — 2026-06-13

### Fixed

- (gaia-dev-story) bind TDD-gate WARNING fixes to the stack developer (#1480)

## [1.192.0] — 2026-06-13

### Added

- (E110-S5) add gaia-brain-query governance-envelope traversal with read-only boundary (#1475)
- (E110-S4) wire `brain-index.md` MOC render + brain-health (unlinked (#1474)
- (E110-S3) add gaia-brain-reindex sweep with content-hash and atomic write (#1473)
- (E110-S2) wire Seven-edge harvester + four-source unlinked predicat (#1471)
- (E110-S1) wire Brain store + `brain-index.yaml` schema (entry / sou (#1470)

### Changed

- (brain) add coverage capstone + read-only-boundary & single-writer static guards (#1476)

## [1.191.2] — 2026-06-12

### Fixed

- (skills) load validator memory in validate-story and sprint-review (#1467)

## [1.191.1] — 2026-06-12

### Changed

- re-scrub leaked epic-story keys re-introduced by the v1.191.0 changelog
- back-merge main (v1.191.0 release) into staging
- scrub leaked internal traceability IDs from published source (#1463)

## [1.191.0] — 2026-06-12

### Added

- clear stale marker on successful refresh + staleness capstone tests (#1457)
- add lazy ground-truth staleness backstop warning to memory-loader (#1456)
- wire ground-truth staleness check into four lifecycle points (#1454)
- add shared ground-truth staleness helper and marker (#1453)

### Changed

- back-merge main (v1.190.1 release) into staging
- cover .ground-truth-stale stale-flag registry registration (#1455)

## [1.190.1] — 2026-06-11

### Fixed

- (gaia-meeting) emit valid cost_breakdown YAML in meeting notes (#1449)

## [1.190.0] — 2026-06-11

### Added

- surface meeting research/discuss output + move notes to meeting-notes/ (#1446)
- robust project-root resolution for orchestration-mode detection (#1445)

## [1.189.0] — 2026-06-11

### Added

- mandatory triage gate in sprint-close (#1440)
- retire standalone tech-debt-review, rewire references (#1439)
- merge tech-debt phase into triage-findings (#1438)
- sprint-scope triage + deterministic findings extractor (#1437)
- add clarify mode to gaia-meeting (#1434)

## [1.188.0] — 2026-06-10

### Added

- (gaia) add post-cascade traceability↔registry consistency gate

## [1.187.12] — 2026-06-10

### Changed

- (validate-epic-registry) add public-function coverage anchor

### Fixed

- (transition-story-status) mirror legacy flat story-index when present
- (create-story) escape & and \ in scaffold-story.sh gsub replacements
- (create-story) add epic/story-key registry integrity audit
- (sprint-state) resolve .gaia/ tree from PROJECT_ROOT, not PROJECT_PATH

## [1.187.11] — 2026-06-09

### Changed

- (dev-story) harden delegation assertions against bats 1.10.0 pipe semantics

### Fixed

- (dev-story) reword Step 3b dispatch prose to clear taxonomy-SSOT drift guard
- (dev-story) delegate plan and TDD implementation to stack-developer subagent

## [1.187.10] — 2026-06-08

### Changed

- rewrite ID-pinning assertions to assert behavior after the SKILL/doc leak sweep
- strip leaked internal traceability IDs from published SKILL.md + agents

## [1.187.9] — 2026-06-08

### Fixed

- (test-run,doctor) portable bats detection + spotbugs version probe

## [Unreleased]

### Fixed

- (test-run) `run-tests.sh` provider auto-detection uses a POSIX `find` glob instead of the bash-only `compgen` builtin, so it no longer errors under sh/zsh (#1129)
- (doctor) the spotbugs `version_cmd` extracts the numeric version token, so `gaia-doctor` / the gaia-tools BOM no longer prints a blank spotbugs version (#1304)
- (ci) the reference `run-tests.sh` contract test asserts the public-API header block instead of a scrubbed internal identifier

## [1.187.8] — 2026-06-06

### Fixed

- (init,brownfield) ci-provider normalization + manifest caller attribution
- (sprint,transition) quote-safe title YAML + epic-key normalization

## [Unreleased]

### Fixed

- (init) `ci_platform.provider` is normalized underscore→hyphen (e.g. `github_actions` → `github-actions`) so the naturally-typed provider answer validates against the schema's hyphenated `ciProvider` enum (#1244)
- (brownfield) Phase 5 sets `GAIA_TEST_ENV_CALLER=/gaia-brownfield` when generating the test-environment manifest, so its header is attributed to the brownfield skill instead of the default `/gaia-bridge-enable` (#1293)
- (sprint-lifecycle) story titles containing a double-quote are now emitted as single-quoted YAML scalars in `sprint-status.yaml` and `story-index.yaml`, so a quote in a title no longer corrupts the file and blocks `/gaia-sprint-close` (#1403)
- (transition) `transition-story-status.sh` derives the bare `E<n>` epic key from a full-title `epic:` frontmatter value before resolving the per-epic story-index path, so stories carrying the legacy full-title `epic:` form can be transitioned/reconciled without an `--epic` override (#1405)

## [1.187.7] — 2026-06-06

### Fixed

- (create-ux) align ux-design template §8 heading to SV-09 Components gate
- (brownfield,init,sprint,docs) eight v1.187.4 lifecycle-test findings

## [1.187.6] — 2026-06-05

### Fixed

- (trace,retro,bridge) three high-severity lifecycle-gate findings

## [Unreleased]

### Fixed

- (create-ux) the shipped ux-design template's §8 heading now leads with "Components" so it satisfies the create-ux SV-09 gate (it was "Design System / Component Reuse", which the anchored heading check did not match) (#1314)
- (brownfield) SARIF merge skips empty / non-conformant `.sarif` inputs instead of aborting the whole merge, so one bad input no longer drops all deterministic findings (#1389)
- (brownfield) jvm-spotbugs adapter short-circuits before any dispatch when the project has no JVM sources, so it no longer writes a 0-byte `spotbugs.sarif` (which crashed the merge) (#1390)
- (brownfield) scan-fidelity banner uses a bash-3.2-safe uppercase instead of `${TIER^^}`, so the degradation notice renders on macOS (#1391)
- (sprint-lifecycle) sprint-state.sh warns about a stale legacy `sprint-status.yaml` only when it actually diverges from the canonical copy, not on its own byte-identical mirror (#1392)
- (init) `primary_platform` is normalized with the same `backend`→`server` map as `platforms[]`, removing the generated-config self-contradiction (#1393)
- (readiness-check) the deterministic readiness-report generator emits a `date:` frontmatter key and an Architecture ADR review line, so its output passes the skill's own checklist (#1394)
- (test-strategy) SKILL.md no longer contradicts itself on artifact output location — doc artifacts go to `planning-artifacts/`, scaffold artifacts under the service/`tests/` tree (#1396)
- (docs) the brownfield walkthrough documents enabling the Docker tier-2 deterministic-tools runner (#1395)
- (trace) finalize exits non-zero when the generated traceability matrix declares its own verdict BLOCKED/FAIL, so downstream readiness gating reacts instead of passing on a path-only check (#1151)
- (retro) retro-sidecar writer allowlist accepts the canonical `.gaia/artifacts/planning-artifacts/action-items.yaml` home that the retro skill writes to, so action items are no longer rejected as unauthorized (#1168)
- (bridge-enable) document the copy-and-edit flow for a template / `*.example` test-environment manifest, so a project with only the shipped template gets guided to a ready manifest instead of a bare Layer-0 failure (#1137)

## [1.187.5] — 2026-06-05

### Fixed

- (test-strategy) hydrate runnable test_execution from detected runner

## [1.187.4] — 2026-06-05

### Changed

- assert AskUserQuestion contract in gaia-meeting sentinel-forbid suite
- fix CI-gated tests that pinned stripped IDs in skills + device-matrix
- assert behavior not stripped IDs in two CI/changelog checks
- scrub leaked IDs from repo-root, adapter and knowledge files
- remove leaked internal traceability identifiers from published source

## [1.187.3] — 2026-06-04

### Changed

- promote staging to main — fix #1113 (install CLAUDE.md on init)

### Fixed

- (init,brownfield) install project CLAUDE.md from template on init (#1113) (#1114)

## [1.187.2] — 2026-06-04

### Changed

- promote staging to main — fixes #1108 + #1109

### Fixed

- (dev-story,sprint-state) atdd-gate nested path + stale sprint-status warning (#1108, #1109) (#1110)

## [1.187.1] — 2026-06-04

### Changed

- promote staging to main — fixes #1091 + statusline leak

### Fixed

- (statusline) isolate git-branch cache per project to stop cross-session leak (#1105)
- (dev-story) tolerate story_key:/epic_key: frontmatter alias (#1091) (#1104)

## [1.187.0] — 2026-06-04

### Added

- adversarial sidecar schema + formalization (#1098)
- adversarial sidecar consumer migration (#1097)
- adversarial json sidecar emitter + paired paths (#1096)
- wire tc-osv traceability bats for envelope original_status field (#1095)
- compose-verdict original_status bookkeeping (#1094)
- wire envelope original_status field — persona Se (#1093)
- infrastructure-design schema + enum 18 to 19 (#1092)
- threat-model schema + /gaia-threat-model References (veri (#1090)
- performance-test-plan schema + enum 17 to 18 (#1089)
- nfr-assessment schema + enum 16→17 (#1088)
- validate-artifact-schema.sh shared lib (#1087)

### Changed

- retire README command-reference contract test (#1101)

## [1.186.0] — 2026-06-02

### Added

- brownfield sweep — 18 fixes (#1084)

## [1.185.1] — 2026-06-02

### Fixed

- (install-statusline) correct plugin.json path depth (#1080) (#1081)

## [1.185.0] — 2026-06-02

### Added

- gaia-statusline-refresh slash command (#1077)

## [1.184.0] — 2026-06-02

### Added

- consent-gated self-heal of stale statusline runtime (#1074)

## [1.183.0] — 2026-06-02

### Added

- rename gaia-public to gaia-framework across in-tree refs (#1071)

## [1.182.11] — 2026-06-01

### Fixed

- (v1.182.5) framework findings sweep — 19 F + 3 D (#1068)

## [1.182.10] — 2026-06-01

### Fixed

- (#1064) validate-gate.sh PROJECT_ROOT four-tier resolution (#1065)

## [1.182.9] — 2026-06-01

### Changed

- (CLAUDE.md) consult framework docs first + file framework bugs upstream (#1060)

### Fixed

- add SKILL.md backing bare /gaia slash command (#1061)

## [1.182.8] — 2026-06-01

### Fixed

- (#1051,#1052) config-validator strictness + reconciler 'section: {}' (#1055)

## [1.182.7] — 2026-06-01

### Fixed

- (#1047) add sprint_review.frontend_commands map (#1049)

## [1.182.6] — 2026-06-01

### Changed

- remove legacy gaia-public/docs/ tree + cruft sweep (#1044)
- remove legacy gaia-public/_memory/ tree (post) (#1042)

## [1.182.5] — 2026-06-01

### Changed

- promote staging to main — sweep

### Fixed

- (v1.182.4) framework findings sweep — 22 F + 3 D (#1039)

## [1.182.4] — 2026-06-01

### Changed

- 44 bats covering findings + 5 doc gaps

### Fixed

- (ci) mark merge_3deep as private (_merge_3deep) for the coverage gate
- (ci) bats regression fallout from / + fixture
- (low) init/yaml-editor/canonical-filename + SKILL prose
- (med) full layout retrofit + readiness-report generator
- (med) brownfield doctor/grype/resolve/render + ci-setup generator
- (high) sprint-state.sh review→closed requires Val sentinel
- (high) bundle Sarif.Multitool via .NET SDK + sarif entrypoint

## [1.182.3] — 2026-05-31

### Changed

- (med) gaia-tools image docs + 48 bats for fixes

### Fixed

- (ci) orchestration-warning regression test guards against the fix-class
- (med) pipeline + dashboard + init cleanup (LOW)
- (high) brownfield runner-aware dispatch (sarif-merge)
- (high) docker image rebuild — 6 build-blockers + sarif-multitool
- (high) three bash 3.2 regressions from the prior sweep

## [1.182.2] — 2026-05-31

### Changed

- cross-platform portability matrix + 59 bats covering fixes

### Fixed

- (ci) two test fallout fixes from (dispatches verb)
- (ci) collapse sprint-plan init to single line for regex match
- (high) doctor ANSI + bridge counts + sprint dates + state-machine + sprint flag
- (high) brownfield wire-up — grype/syft dispatch + yolo carve-out + template
- (med) init platform vocab adds server/backend + gitignore back-fill
- (high) bash 3.2 portability across deterministic-tools chain

## [1.182.1] — 2026-05-30

### Changed

- close + html doc gaps

## [1.182.0] — 2026-05-30

### Added

- (brownfield) flip deterministic-tools defaults to on
- (runner) docker dispatch for tier-2 adapters + `/gaia-doctor --install --docker` (the docker mode for the READ-ONLY check is config-driven via `brownfield.tools.runner: docker`, NOT a `check-tools.sh --docker` flag)
- (tools) gaia-tools OCI image bundling tier-2 scanners

### Changed

- 44 bats covering fixes
- 29 bats covering docker runner end-to-end

### Fixed

- (skills,scripts) med + low + d-gap batches
- (high) zero-config seed + bash guard + labels + bridge
- (doctor) stack parse + tier promotion + pip + sarif

## [1.181.0] — 2026-05-30

### Added

- (doctor) /gaia-doctor preflight tool readiness scan

### Changed

- 32 bats covering fixes

### Fixed

- register brownfield as managed-elsewhere + x-no-auto-hydration
- ci regressions round 2
- ci regressions from sweep over-correction
- (skills) canonical config-path sweep across skill md + scripts
- (low) /gaia-config-brownfield + templates + dev/sprint/trace polish (LOW batch)
- (med) bash 3.2 + ledger + DoD + dep-gate + retro paths + resolver + schemas
- (high) bridge + zero-config + headless platform + tier

## [1.180.10] — 2026-05-30

### Changed

- 23 bats covering drift closures

### Fixed

- mark migrate helper internals private
- (test-artifacts) per-story mirror layout via shared resolver (drift 2)
- (adversarial) write to adversarial/ subdir per (drift 1)

## [1.180.9] — 2026-05-29

### Changed

- (skills) add Operator Quickstart to dev-story + review-all + sprint-review (D6)

## [1.180.8] — 2026-05-29

### Changed

- 32 bats covering fixes
- update 2 tests that asserted the pre-fix behavior
- cover each fix + add SKILL.md↔script contract-drift sweep guard

### Fixed

- (trace) keep anchor literal in coverage formula
- (skills,agents) ui-present + stack-detect + pytest + trace + sprint-activate
- (skills) brownfield gates + envelope hash + project-root + create-story reg
- (brownfield,schema) brownfield setup greenfield-degrade + schema.yaml v2.0 (F1, F3)
- contract-mismatch sweep across 7 SKILL.md ↔ script pairs
- integrate the Test Execution Bridge into dod-check + locate stories

## [1.180.7] — 2026-05-28

### Changed

- troubleshooting/FAQ page + bats sweep-discipline guard

## [1.180.6] — 2026-05-28

### Changed

- update no-layout assertion for expanded format
- update gaia-trace error-message assertion for the expanded format
- cover each fix + add SKILL.md path-drift sweep-discipline guard

### Fixed

- heading placeholder, brittle regexes, slug freedom, error messages
- sweep stale artifact-path references across SKILL.md + agents docs

## [1.180.5] — 2026-05-28

### Changed

- align ci-finalize-gate + planning-vs-test taxonomy with the new contracts
- update tests that asserted the pre-refactor inline impls
- cover resolver project-root env precedence (fixture pattern)

### Fixed

- findings — shared artifact-path resolver + heading lib + gate
- broaden resolve-artifact-path project-root resolution
- ci-setup checklist default, delivered default, dod build/lint parity
- unblock create-arch threat-model gate in the pre-sprint phase
- centralize heading_present into one shared lib
- route artifact-path consumers through a shared resolver

## [1.180.4] — 2026-05-27

### Fixed

- (statusline) self-heal the installed runtime against the active plugin

## [1.180.3] — 2026-05-27

### Fixed

- (statusline) clear the update arrow once installed catches up to latest

## [1.180.2] — 2026-05-27

### Fixed

- (statusline) show staged/unstaged line-change counts instead of a dirty '*'
- (statusline) split rate-limit windows + per-window reset countdown
- (statusline) show bare model name, strip the context-window suffix
- (statusline) true green→amber→red gradient for the context-% bar + number

## [1.180.1] — 2026-05-27

### Fixed

- single-source review-report path resolver + per-story reviews/ producer migration
- (docs) doc-clarity + skill fixes
- (planning) complete prd/ux templates + init developer-experience gaps
- (sprint) unblock next-sprint init after close + add sanctioned sprint_id setter
- (reviews) close api-review + infra-design rubric gaps
- (agents) use the canonical plugin-root var in agent memory-loader headers
- point taxonomy producers at the planning-artifacts canonical home
- wire per-story layout into un-migrated story-file consumers

## [1.180.0] — 2026-05-27

### Added

- planned→active readiness gate (#977)
- gaia-create-story --for-sprint batch materializer (#976)
- sprint-plan selects from backlog (column-sourced dependency lint) (#975)
- add the planned sprint state to sprint-state.sh (#974)
- single-source review-report paths + verdict-line parser (#973)
- formalize the date-suffix convention + latest-by-date resolver (#972)
- planning-vs-test artifact taxonomy migration + consumer repoint (#971)
- per-epic story nesting + three-tier resolver fallback (#969)
- redefine SM capacity check on agent-native measures (#968)
- dual-track estimation — points + agent-wall-clock (#967)
- throughput-telemetry derivation layer + /gaia-history skill (#966)
- phase 4b reconciliation pass — demote reachable file-only findings (#957)
- phase 4b cross-stack warning emission + scope respect (#956)
- per-stack dead-code adapters (go deadcode + python vulture + jvm spotbugs) (#955)
- sbom completeness assertion with per-ecosystem carve-outs (#954)
- detect-signals stacks[].path proposal/audit mode (opt-in) (#953)
- orchestrator per-stack file-list intersection (path x paths x excludes) (#952)
- grype DB trust-boundary enforcement (max-age + checksum + drift reject) (#951)
- wire sarif_merge telemetry via shared writer (#950)
- wire pre_warm telemetry via shared writer + harden telemetry writer (#949)
- cross-tool finding dedup contract (dual dedup keys) + telemetry writer (#948)
- sarif Multitool merge as Phase 7 pre-processor — core (#947)
- brownfield Phase 3 pre-warm script (cdxgen + Grype DB) — core (#946)
- stacks[] 4-field schema delta + /gaia-init questionnaire + /gaia-config-stack editor (#945)

### Changed

- retire legacy _memory/ support — .gaia/ is the only tree (#983)

### Fixed

- val-sidecar routes on .gaia layout, not memory-subdir existence (#982)
- resolve 21 live findings across format/contract/a11y/housekeeping (#980)
- scaffold writes the nested per-story path (close AC1 gap) (#970)
- sprint-setup lifecycle gates honor strategy/+sharded placements (#964)
- framework findings — 26 live bugs across 5 bundles (#961)
- reconcile reachable-set via slurpfile + union multi-callgraph entry_points (#958)

## [1.179.0] — 2026-05-27

## [1.178.0] — 2026-05-26

## [1.177.0] — 2026-05-26

## [1.176.2] — 2026-05-25

### Fixed

- (pr-b) 6 script-behavior medium findings (#941)
- (pr-a) 13 quick-fix medium/low findings (#940)

## [1.176.1] — 2026-05-24

### Fixed

- bundle 10 high findings (#936)
- bundle 7 high findings (#935)
- distribute traceability gate to dev-story (minimal) (#934)
- review parent-write paths use .gaia/ canonical (critical) (#933)

## [1.176.0] — 2026-05-24

### Added

- (sprint-52) artifact-taxonomy cleanup + lifecycle ordering enforcement
- enforce lifecycle ordering across gaia skills
- group flat artifact files into purpose-named subdirectories
- add bats fixtures for decision and DOCUMENT path

### Fixed

- relocate review evidence to .gaia/state/review/ and strip gaia- prefix
- (sprint-52) unbreak existing bats suites after sprint-52 wiring
- skip lifecycle gates when no upstream artifacts present

## [1.175.0] — 2026-05-24

### Added

- wire Credential-isolation bats audit + permanent CI guard (#925)
- wire Custom adapter discovery + shadowing + `--strict-bui (#922)
- wire `static-site` adapter with 6-provider dispatch + cdn (#921)
- wire `github-releases` + `container-registry` adapters (#920)
- wire `claude-marketplace` + `npm` + `pypi` + `homebrew` a (#919)
- wire Adapter contract enforcement + envelope shap (#918)
- wire Pre-publish gates (CI green + manifest version match (#916)
- gaia-publish five-step orchestrator skeleton + happy path (#914)
- migration safety net (.config-stale + /gaia-config-validate warn) (#913)
- phase 5 routing + deploy-checklist publish-readiness (#906)

### Fixed

- address Code Review findings C1+C2 (#926)
- address Code Review findings C1+C2+W1 (third pass) (#924)
- address Code Review findings C1+W1+W2+W3 (#923)
- drop dead pom.xml alternative (shellcheck SC2221/SC2222) (#915)

## [1.174.0] — 2026-05-23

### Added

- gaia-config-distribution section editor (#903)
- distribution.manifest path canonicalization (#901)
- distribution section schema + 10-channel registry (#899)
- environments[].kind discriminator + resolver + default semantics (#898)
- wire backup integrity (sha256 manifest) + retention tutorial (#897)
- wire auto-rename migration flow with AskUserQuestion (#895)
- wire template_overrides interpreter + disable-allowlist (#892)
- wire Protected-jobs assertion script (#891)
- wire Overlay stitching engine (jobs + steps) (#889)
- wire Prefix-detection helper + regen contract (#888)

### Changed

- merge main into staging — resolve test-strategy finalize conflict

### Fixed

- yara test-report bundle (bugs 1,2,3,7,8,9,11,12,13,15,16) (#908)
- epic-dir naming convergence (bug 18 high) (#907)
- config-hydration fail-safe (bug 21 critical) (#905)
- 5 HIGH-severity bugs from YARA test report (#902)
- correct SKILL.md vs config-yaml-editor.sh API divergence (code-review C1+C2) (#904)
- correct malformed YAML required arrays in 7 publish-* schemas (#900)
- document AskUserQuestion orchestration + Y-branch regen step (code-review C1+C2) (#896)
- close AC3 validate-side + AC8 config-show extension (code-review C1-NEW, C2-NEW) (#894)
- wire template_overrides interpreter into Sub-flow C (code-review C1) (#893)
- address code-review Critical findings — mktemp + YAML re-indent (#890)
- test-strategy gate + missing scripts + config-hydration (#885)

## [1.173.1] — 2026-05-22

### Fixed

- test-strategy gate + missing scripts + config-hydration (#885) (#886)

## [1.173.0] — 2026-05-22

### Added

- adversarial-reviewer agent (Sage) + wire 6 SKILL.md dispatches (#873)
- calibrate sgr-velocity-003 incidental-goal floor for completion-pass sprint shape (#839)
- add CI regression guard — path-migration-guard.bats with grep-allowlist
- fix release-bot .plugin-version drift; add lockstep guard
- stale-comment sweep in resolve-config.sh + validate-gate.sh
- derive review-summary-gen.sh CANONICAL_REPORT_RELPATHS from resolved variables
- triage class-b mixed-state scripts; fix sprint-status remediation hint
- retire migrate-stories-to-canonical-layout.sh to scripts/retired
- wire config-hydration.sh + gaia-help/SKILL.md into lib/gaia-paths.sh

### Changed

- sync main into staging (resolve v1.171.0 version-bump conflict) (#875)

### Fixed

- memory-sidecar paths canonical in SKILL.md prose (#882)
- 5 PRD-dogfooding bugs + minor checkpoint paths (#881)
- release-bot ARG_MAX failure on large commit ranges (#878)
- final polish — 3 missed display-string canonical refs (#870)
- residual canonical-path sweep — 234 lines / 105 files (#869)
- config templates + gaia-help.csv canonical-first (#868)
- class-1 scripts batch 3 — framework-wide closure (#867)
- class-1 scripts batch 2 canonical-first migrations (#866)
- class-1 script-side canonical-path migration (#865)
- caveat-files surgical canonical-path cleanup (#864)
- bulk SKILL.md canonical-path sweep (58 simple files) (#863)
- final 10-skill SKILL.md canonical-path sweep (#862)
- 9-skill SKILL.md canonical-path sweep (#861)
- research cluster SKILL.md canonical-path migration (#860)
- test-cluster scripts canonical-path migration (#859)
- test-cluster SKILL.md writes to legacy docs/ instead of .gaia/ (#858)
- gaia-brownfield writes to legacy docs/ instead of canonical .gaia/ (#857)
- gaia-meeting writes to legacy docs/ instead of canonical .gaia/ (#856)
- trace + threat-model write to legacy docs/ instead of canonical .gaia/ (#855)
- ux cluster writes to legacy docs/ instead of canonical .gaia/ (#854)
- epics cluster SKILL.md writes to legacy docs/ instead of canonical .gaia/ (#853)
- gaia-edit-prd writes to legacy docs/ instead of canonical .gaia/ (#852)
- arch cluster writes to legacy docs/ instead of canonical .gaia/ (#851)
- gaia-create-prd writes PRD to legacy docs/ instead of canonical .gaia/ (#850)
- gaia-init Phase 0 loses project_kind=claude-code-plugin signal (#847)
- 4 scripts default to legacy config/ on greenfield, creating rogue dirs (#844)
- 14 scripts default to legacy _memory/ on greenfield, creating rogue dirs (#841)
- gaia-init emits legacy _memory/ paths + path-migration-guard blanket (#837)
- statusline.sh unbound CACHE_TS on fresh install + SKILL.md refreshInterval (#836)
- repair 3 dogfooding findings from sprint-50 (#833)
- validate-against-schema.sh date crash + SKILL.md --full polish (#832)
- (staging) repair 28 bats failures from path-migration drift (#829)

## [1.172.0] — 2026-05-22

## [1.171.0] — 2026-05-22

## [1.170.0] — 2026-05-21

## [1.169.0] — 2026-05-21

## [1.168.0] — 2026-05-21

## [1.167.0] — 2026-05-21

## [1.166.0] — 2026-05-21

## [1.165.0] — 2026-05-21

## [1.164.3] — 2026-05-21

### Fixed

- complete path migration for 8 helper scripts
- complete path migration for 8 helper scripts
- printf -- escape for Findings-section bullets

## [1.164.2] — 2026-05-20

### Fixed

- opt gaia-create-story.bats out of proof-of-execution
- opt remaining bats suites out of proof-of-execution
- proof-of-execution gate on review-gate.sh + summary-gen + run-all-reviews

## [1.164.1] — 2026-05-20

### Fixed

- (yaml-resolvers) smart-fallback for .gaia/state/sprint-status.yaml

## [1.164.0] — 2026-05-20

### Added

- post-deprecation cleanup — write-boundary scoped + missed hook (#806)
- partial-4 — smart-fallback across 24 missed runtime helpers (#805)
- bulk legacy-path sweep — runtime helpers + AC6 fixture+bats (#804)
- cleanup — CLAUDE.md / README sweep + audit script + ADR cross-refs (#798)
- phase 4 — _memory/ migration with hash-manifest sentinel (#797)
- phase 3 — root-state files + custom/ relocation to .gaia/ (#796)
- phase 2 — docs/ rename to .gaia/artifacts/ + state extraction (#795)
- add gaia-paths helper + Phase 1 config migration + phase-exit gate (#794)
- (sprint-wiring) — wire /gaia-sprint-plan + /gaia-correct-course + /gaia-sprint-close for sprint-level edges (#788)
- (sprint-review) — Track B per-stack execution-review runner + threat-model mitigations (#787)
- (sprint-review) — /gaia-sprint-review skill scaffold (Mode A, Track A Val dispatch, composite verdict, UNVERIFIED bypass) (#786)

### Fixed

- (sprint-close) smart-fallback for .gaia/state + .gaia/memory + .gaia/artifacts (#809)
- (sidecars) smart-fallback for .gaia/memory/ in retro + val sidecar writers (#808)
- gaia-sprint-review/finalize.sh smart-fallback for .gaia/memory/ (#807)
- phase-exit-gate cumulative-target + rollback-scope defects + runtime sweep (#801)
- (sprint-review) manual-test defect bundle (-2/-4/-5) (#791)

## [1.163.0] — 2026-05-20

## [1.162.0] — 2026-05-20

## [1.161.0] — 2026-05-19

## [1.160.0] — 2026-05-19

## [1.159.0] — 2026-05-19

### Added

- wire /gaia-config-sprint-review + sprint_review project-config schema
- wire sprint-level state machine + goals field on sprint-state.sh

### Changed

- sync main v1.158.0 release-bump into staging
- add base sprint-review rubric for /gaia-sprint-review Track A

### Fixed

- check-deps.sh skips *-review-summary.md siblings
- check-deps.sh skips *-review-summary.md siblings
- classify sprint_review as managed-elsewhere; drop output-text grep
- allowlist + CRUD-disclaimer + ajv-tolerant regex
- coverage — list 5 new public functions in bats header
- emit_lifecycle_event call shape — sprint-level uses direct lifecycle-event.sh
- sprint-state.sh mktemp + bats fixture compat

## [1.158.0] — 2026-05-18

### Added

- document promote-PR squash-merge release-pipeline pitfall
- wire Add surface_type column and BLOCKED-severity finding (#773)
- add hotfix priority_flag enum + active-sprint injection (#772)
- wire Anchor release.yml commit-classification range on mos (#771)
- post-install Step 5 summary with canonical path + edit prompt (#768)
- add GAIA-MANIFEST-TEMPLATE sentinel + Layer 0 guard (#767)
- wire bridge-toggle Step 4 to inline manifest generator (#766)
- extract test-environment.yaml generator to scripts/lib helper (#765)
- relocate test-environment.yaml canonical path to config/ (#764)
- make bridge-toggle Step 4 option [b] actionable (#760)
- wire test-environment.yaml.example installation into V2 plugin (#759)

### Changed

- merge main into staging (resolve conflicts in favor of)

## [1.157.0] — 2026-05-18

### Added

- bridge-enable inline manifest + config/ relocation (#769)

## [1.156.0] — 2026-05-18

### Added

- publish bridge-toggle V2 plugin port to marketplace (#762)

<!-- v1.155.13 entry will be auto-generated by the release workflow from the commits below. -->

## [1.155.12] — 2026-05-18

### Fixed

- make warning_body private (coverage gate)
- cross-platform stat in bats test
- surface orchestration warning above Claude Code fold

## [1.155.11] — 2026-05-18

### Fixed

- gaia-meeting manual-test findings (6 patches)

## [1.155.10] — 2026-05-17

### Fixed

- mobile family honest diagnostic + platforms gate

## [1.155.9] — 2026-05-17

### Fixed

- three-phase a11y family gating consistency

## [1.155.8] — 2026-05-17

### Fixed

- gaia-fill-test-gaps strategy/ fallback

## [1.155.7] — 2026-05-17

### Fixed

- device-target clear writes bare section shape

## [1.155.6] — 2026-05-17

### Fixed

- bridge-toggle absent-key + resolver allowlist

## [1.155.5] — 2026-05-17

### Fixed

- gaia-test-run runner-invocation mapping
- gaia-test-run vocab + detection bundle

## [1.155.4] — 2026-05-16

### Fixed

- resolve-config.bats CWD-isolation in setup

## [1.155.3] — 2026-05-16

### Fixed

- gaia-test-gap-analysis schema-drift documentation

## [1.155.2] — 2026-05-16

### Fixed

- gaia-trace + sister skills test-artifact strategy-fallback

## [1.155.1] — 2026-05-16

### Fixed

- sister-skills sharded-PRD fallback
- gaia-trace sharded-PRD fallback

## [1.155.0] — 2026-05-16

### Added

- wire /gaia-triage-findings YOLO auto-apply — closes epic (#716)
- wire /gaia-dev-story YOLO Val on TDD phases (#715)
- wire /gaia-dev-story YOLO auto-run-reviews after merge (#714)
- wire /gaia-create-story YOLO wire-up (#713)

### Fixed

- extend test_plan_exists strategy/ alias

## [1.154.0] — 2026-05-15

### Added

- opt-in --auto-file flag for /gaia-retro action items (#709)
- check-deps.sh walks up to find implementation-artifacts root (#704)
- pr-create title-prefix guard + commitlint depth fix (#703)
- swap PostToolUse hook to ${CLAUDE_PLUGIN_ROOT} (#702)

### Changed

- plugin-cache refresh playbook + Step 14b advisory (#705)

### Fixed

- (staging) pr-create title-prefix bats tests build per-test git work tree (#710)
- helpful redirect for sprint-state inject --points (#708)
- extend type-guard to canonicalize_payload jq fallback path (#707)
- type-guard val-sidecar-write jq sort key (#706)

## [1.153.0] — 2026-05-15

### Added

- (e92-s2) enforce step 7 val-sidecar write via finalize sentinel (#699)
- (e92-s1) main-turn direct-write fallback for create-story spawn (#698)
- (e76-s22) wire dispatch-provenance-check into phase 7 save (#696)
- (e91-s3) two-stage path resolution in story-state scripts (#695)
- default-skip @hardware-dependent tests in plugin-ci (#693)
- populate .plugin-version + semver-tag persona_sig framework-wide (#692)
- deterministic parent-epic inference helper + step 8 pre-flight (#691)
- step 8 deferred-seed-brief mode + step_8_mode field (#690)
- setup.sh test-plan + traceability prereq gates + CLI (#688)
- anti-stub Then-clause for dispatch-verb ACs in /gaia-atdd (#686)
- completion-notes-deferral-scan helper + Val pattern + triage extension (#684)
- generalize assert-agent-envelope.sh with --expected-agent flag (#682)
- taxonomy SSOT foundation + loader + matchers + bats audit (#681)
- reconciler writes framework_version after successful apply (D8) (#680)
- gaia-config-* dogfooding bugs + enhancements bundle (D7) (#679)
- framework-wide /gaia-config-* SKILL.md drift sweep (D1+D2+D3) (#678)
- gaia-config-* wrong-section-name cluster fix (#677)
- dev-story workflow friction bundle (6 defects from (#670)
- wire `_detect_v1` custom/ v1-marker false positive — re (#669)

### Fixed

- (refresh-ground-truth) inline sidecar writability check (replace dir_writable gate)

## [1.152.0] — 2026-05-14

### Added

- promote + to release

## [1.151.0] — 2026-05-13

### Added

- sentinel-write writer shift to orchestrator (#664)

## [1.150.0] — 2026-05-13

### Added

- doc cascade + stale-flag registry static check (#662)
- ci suppression + GAIA_SKIP_VERSION_CHECK guard + bats suite (#661)
- gaia-help state-detection branch (Step 3a) — 4-state enum (#660)
- self-healing clear of framework-version-stale marker (#659)
- extract framework-version.sh from template-header.sh (#657)

## [1.149.0] — 2026-05-13

### Added

- dispatch gaia-migrate.sh exit-11 to gaia-reconcile-v2.sh (#648)
- retire greenfield-guard.sh + sweep call sites (#646)
- wire /gaia-infra-design hydration trigger for environments + ci_cd (#645)
- wire /gaia-create-arch hydration trigger for stacks + platforms (#644)

### Changed

- cascade v2-to-v2 reconciliation path into SKILL + manifests (#650)

### Fixed

- tighten /gaia-add-feature Val-dispatch contract (#649)

## [1.148.0] — 2026-05-13

### Added

- wire Bats anti-pattern check + SKILL.md changelog (#638)
- wire Migrate `/gaia-add-feature` Step 2 Val gate (LAST — (#637)
- wire Migrate `/gaia-dev-story` Steps 4 + 7b (#636)
- wire Migrate `/gaia-validate-story` Component 4 + `/gaia-f (#635)

## [1.147.2] — 2026-05-12

### Fixed

- (statusline) lower update-check TTL from 24h to 30min

## [1.147.1] — 2026-05-12

### Fixed

- (statusline) recompute update_available on every render against live version
- (statusline) trigger update-check fetcher from renderer + fix plugin.json path resolution

## [1.147.0] — 2026-05-12

### Added

- wire `project-config.schema.json` v2.0.0 — `config_phase
- shared config-hydration.sh helper (#620)

### Changed

- add canonical resolve-story-file.bats covering ..5 (#619)

### Fixed

- (statusline) match Claude Code's actual context_window schema + lower refreshInterval to 10s + lower rate-limits width threshold to 80

## [1.146.1] — 2026-05-12

### Fixed

- (statusline) rich theme is the runtime default + walk-up sprint-status.yaml resolution

## [1.146.0] — 2026-05-12

### Added

- (statusline) track active branch via PreToolUse + two-line layout + gradient context-bar

### Fixed

- (statusline) resolve GAIA version from plugin cache, drop unset CLAUDE_PLUGIN_ROOT path

## [1.145.0] — 2026-05-12

### Added

- shared resolve-story-file.sh helper + retrofit validate-story, fix-story, sprint-plan

### Changed

- coverage stub for resolve_story_file

### Fixed

- (statusline) suppress closed sprint_id in rich theme
- preserve docs-contract phrases in sprint-plan SKILL.md retrofit

## [1.144.0] — 2026-05-12

### Added

- shared resolve-story-file.sh helper + retrofit validate-story, fix-story, sprint-plan

### Changed

- coverage stub for resolve_story_file

### Fixed

- preserve docs-contract phrases in sprint-plan SKILL.md retrofit

## [1.143.0] — 2026-05-12

### Added

- wire orchestration-warning into 42 heavy-procedural and conversational skills (#599)
- gaia-shard-doc sub-shard directory preservation (option A) (#597)
- check-monolith-shard-sync.sh sub-shard directory awareness (#596)
- statusline rate-limits chunk (rich-theme-only) (#595)
- sprint-state.sh rollover + sprint-plan prior-close guard (#594)
- context-window progress bar (segment implementation) (#593)
- statusline git-dirty marker via PreToolUse hook (#592)
- statusline runtime staleness detection (marker + cache field) (#591)
- statusline smart-hiding — suppress empty MODEL/PROJECT chunks (#589)
- gaia-sprint-close skill — close + archive + lifecycle event (#588)

### Changed

- bats fixture for -10-5 drift-report closure (#598)

### Fixed

- toggle.sh --enable emits canonical {type, command, refreshInterval} (#590)

## [1.142.0] — 2026-05-11

### Added

- add silent-Val-bypass audit script + bats coverage (#585)
- add lossy-mode warning helper + yield-gate amendment (#584)
- strip context:fork + dual-mode runtime + framework gate (#583)
- classify all 146 SKILL.md files with orchestration_class (#582)
- document orchestration_class schema in skills README (#581)

### Fixed

- (statusline) read version from CLAUDE_PLUGIN_ROOT not in-tree repo

## [1.141.0] — 2026-05-10

### Added

- surface Val-PASSED stranded-ready stories in /gaia-sprint-status (#577)
- sprint auto-close detection (#576)
- plugin-namespaced subagent dispatch in skill prose (#574)
- substrate-replace stdout-sentinel yield with AskUserQuestion (#569)
- verify /33 AskUserQuestion amendment in PRD shard (#567)
- bats stdout-sentinel anti-pattern check + SKILL.md auto-mode clause (#566)
- add re-validation audit-trail bats day-1 self-test (#565)
- remove priority_flag next-sprint auto-setter from gaia-add-feature (#564)
- wire in-place amendment + traceability matrix rege (#563)
- bats anti-pattern check on assessment-doc emissions (#562)
- harden SKILL.md prose to forbid auto-judge and inline-Val patterns (#561)
- sentinel checkpoint primitive + AskUserQuestion precondition

### Changed

- verify user-as-attendee + row (#568)

### Fixed

- closeout-skill scanner hardening (recursive-glob + set -u guard) (#573)
- reword Step 2 anti-pattern warning to satisfy static check

## [1.140.0] — 2026-05-09

### Added

- gaia-statusline-enable and /gaia-statusline-disable toggle skills (#556)
- background update-check fetcher + 7d stale-fence (#555)

## [1.139.0] — 2026-05-09

### Added

- mirror per-story status into per-epic shard atomically
- close subagent dispatch contract for /gaia-meeting (#549)
- script-side yield-gate enforcement with YIELD-STOP sentinel (#548)
- wire No-fabricated-user-turns invariant (#547)
- wire /gaia-init Step 2.2 project-shape enum relabel + plug (#546)

### Changed

- name new public functions in coverage anchors

### Fixed

- teach validate-gate.sh traceability_exists to accept strategy/ placement (#550)

## [1.138.0] — 2026-05-08

### Added

- interactive checkpoint mode for /gaia-meeting (#541)

### Changed

- retire stale -release-cut-readiness.bats (#543)

## [1.137.0] — 2026-05-08

### Added

- wire guardrails and cost-reporting refinements (#535)
- add eight non-decide modes with default invitees + bias plumbing (#534)
- scratchpad pin + auto-organized extraction (#533)
- close-review + action-items v2 + memory write-through + dual-schema routing (#532)
- wire Research phase + cite-or-flag + raise-hand — sideca (#531)
- migration script — backfill legacy flat stories + flat story-index.yaml (#530)
- make all story-file readers recursive (#528)
- transition-story-status.sh — write per-epic story-index.yaml (#527)
- wire `/gaia-create-story` — write to canonical nested pa (#525)
- scaffold /gaia-meeting seven-phase peer-to-peer skill
- lift epic-slug resolver into a shared script (#523)

### Fixed

- (tests) bump version-pinned literals after v1.136.0 release (#538)
- scaffold-story frontmatter token gap and gaia-atdd recurring quirks (#536)
- (gaia-run-all-reviews) resolve canonical-nested story paths (#526)

## [1.136.0] — 2026-05-07

### Added

**Sprint-39** (117 pts, 22 stories, 100% completion + 100% velocity + 100% first-pass review rate). Two epics shipped end-to-end: Plugin Project Shape (16 stories, 88 pts) + Plugin Distribution (6 stories, 29 pts).

- **Plugin Project Shape** — GAIA can now be authored as a Claude Code plugin.
 - add `project_kind` field to project-config schema and resolver (#498)
 - add claude-code-plugin stack file (#499)
 - tri-state tool-availability probe (#500)
 - sub-rubric loader pipeline migration with byte-identical contract test — high-risk XL (#501)
 - Tier 1 `plugin-code` sub-rubric (#502)
 - Tier 1 `plugin-security` sub-rubric (#503)
 - Tier 1 `plugin-frontmatter-validator` adapter (#504)
 - Tier 1 `plugin-manifest-validator` adapter (#505)
 - `/gaia-init` option 6 — Claude Code plugin (#506)
 - mobile dual-path coexistence amendment — docs-only
 - Tier 2 shellcheck adapter (#507)
 - Tier 2 bats adapter dual-mode with day-1 spike fallback — high-risk (#508)
 - Tier 2 jsonschema, markdownlint, yamllint adapters (#509)
 - Tier 2 `plugin-test` sub-rubric (#510)
 - Tier 2 `plugin-qa` + `plugin-nfr` sub-rubrics (#511)
 - plugin CI template + bats-budget-watch + brownfield detection + plugin-aware `/gaia-trace` — high-risk XL (#512)
- **Plugin Distribution** — marketplace publication chain end-to-end.
 - `marketplace-publish` adapter (#513)
 - `distribution.channels[]` schema (#514)
 - `/gaia-deploy` `health_check.mode: skip` (#515)
 - `/gaia-deploy` `deployment.adapter` dispatch (#516)
 - `/gaia-deploy` empty `smoke_suites` handling with manual-checklist evidence (#517)
 - `plugin-versioning` semver rubric + `adapter.schema.json` enum hygiene (#518)

### Fixed

- (skills) correct project-config.yaml path resolution in /gaia-config-* editors (#497)

### Changed

- (ci) commitlint: ignore historical `release:` and `Merge ...` subjects so resolution-merge PRs aren't blocked by commits already on main (#520)
- (ci) commitlint: limit linting to PR HEAD via `commitDepth: 1` (#520)
- merge origin/main into staging — resolve sprint-39 / PR #519 conflicts (#520)

### Maintenance

- 22 distinct stories shipped across one sprint; 21 squash-merge feature commits (#498–#518) + #497 path-fix + #520 fixup PR.
- Three high-risk stories landed without spike fallback. The MITIGATION 4 prerequisite gate (contract.bats green before ship) worked as designed.
- Sprint-envelope discipline restored at 117 pts after sprint-36→37→38 expansion (73 → 174 → 271 pts).
- 33 findings triaged into 17 backlog stories (15 new TDs, 2 dedup'd into existing). 7 retro action items captured.

## [1.135.0] — 2026-05-06

### Added

- **Sprint-37** (174 pts, 34 stories): GAIA Review System v2 foundation + critical-gaps + configuration system + naming reorg
 - Foundation: review-common shared library, agent-overlay.sh, verdict-resolver.sh parameterization, tool-availability-probe.sh three-state probe, /gaia-review-all composite verdict GATING , gaia-security-review V2 reference migration, evidence-judgment-parity bats across 12 verdict-producing skills
 - Critical Gaps: /gaia-review-test Phase 3A scripts (smell-detector, flakiness-analyzer, fixture-analyzer, tag-conformance-detector), /gaia-test-automate skeleton-fix + placeholder-test-detector + coverage-delta verdict input, /gaia-review-qa Phase 3C TC generation + project-config-driven test execution, /gaia-review-security privacy/data-protection scanners (PII detector, data-handling lint, retention-policy check)
 - Configuration System: project-config schema extension (11 new top-level sections), layered rubric loader + rubric-merger.sh + rubric.schema.json, six base rubrics + nine regime rubrics (GDPR/HIPAA/PCI-DSS/SOX/CCPA/SOC2/ISO-27001/WCAG-AA/WCAG-AAA)
 - Naming & Reorg: 8 review commands renamed to gaia-{verb}-{noun} canonical form with one-sprint deprecation aliases, /gaia-review-a11y three-phase reorganization, /gaia-test-strategy collapse, utility reviews wired as sub-routines, /gaia-perf-deepdive anytime variant rename
- **Sprint-38** (271 pts, 48 stories): Tool Adapter Framework + Configuration UX + Action Skills + Deployment-Phase + Mobile Platform + Polish
 - Tool Adapter Framework: adapter pattern formalization (adapter.schema.json + run-contract), 5-tool migration (Semgrep/gitleaks/radon/gocyclo/eslint-plugin-sonarjs) + backward-compat aliases, SonarQube adapter (container profile), OWASP Dependency-Check adapter, /gaia-list-tools + /gaia-tool-info + /gaia-validate-rubric query skills, probe-state-to-check-status helper
 - Configuration UX: /gaia-init greenfield conversational setup, /gaia-brownfield detection-driven config extension, /gaia-config-* editor family (env/test/tool/compliance/stack/rubric/show/validate), /gaia-config-ci --regenerate backup-and-prompt UX
 - Action Skills: /gaia-test-run manual any-environment runner, /gaia-test-automate sub-commands (--status/--add-scenario/--scaffold), custom-scenario tracking, per-stack tag conventions + tag-conformance-detector
 - Deployment-Phase Skills: /gaia-test-e2e (Playwright + Cypress), /gaia-test-perf (k6 + Lighthouse), /gaia-test-dast (OWASP ZAP), /gaia-test-a11y (axe-core + pa11y + Lighthouse), /gaia-deploy Pattern A skill
 - Mobile Platform Support (11 stories): project-config schema extension (platforms + device_targets), four mobile stacks (swift/kotlin/react-native/flutter), base mobile.json + sub-rubrics, apple-app-store + google-play-store + COPPA regime rubrics, seven mobile static adapters, /gaia-review-mobile skill, mobile dynamic adapters + device-farm dispatch (detox/maestro/appium/xcuitest/espresso + Firebase/BrowserStack/Sauce Labs), /gaia-test-mobile-e2e + /gaia-test-device-matrix, /gaia-config-platform + /gaia-config-device-target editors
 - Polish: BOUNDARIES.md top-level scope-edges document, parity bats per skill, persona-overlay agent-wiring documentation, framework README updates

### Fixed

- gaia-dev-story promotion-chain ABSENT false-flag — config-discovery ladder mirrors resolve-config.sh
- post-step push-verification added to /gaia-dev-story finalize
- story-template enforces 3-column Review Gate at validation
- dev-story tooling cleanup — transition-story-status path fixes, sharded-layout resolver, EXIT/INT/TERM trap, orphan-tmp sweep, lint-err tempfile registration
- document non-git docs/ workspace + degrade git ops gracefully
- docs reorganization continued — H3 sub-sharding, code-block-aware H2 detection, classify legacy files, type-table polish, reconcile, monolith-vs-shard sync contract, cascade-skill auto-reshard, broken markdown link cleanup
- (CI) bump bats-tests timeout 5m → 8m to absorb sprint-37/sprint-38 suite growth (3300+ tests)

### Maintenance

- 60 distinct stories shipped across two sprints; 65 individual feature commits + 5 hotfix PRs (#419, #427, #433, #455, #477)
- Tech-debt resolved: 18 items closed across both sprints (sprint-37: 12, sprint-38: 6); debt ratio reduced from 18% (sprint-36 end) to 13% (sprint-38 end)

## [1.134.1] — 2026-05-04

### Fixed

- accept legacy epics/index.md sharded layout in validate-gate.sh

## [1.134.0] — 2026-05-03

### Added

- teach validate-gate.sh to accept sharded planning-artifact layouts (#408)
- add inject subcommand to sprint-state.sh (#405)

### Fixed

- substitute {project-root} placeholder in v1->v2 migrator (#406)
- add placeholder-detection guard to resolve-config.sh (#407) — defense-in-depth companion to ; auto-classifier missed this entry because the squash commit's title didn't conform to Conventional Commits prefix; manually added.

### Maintenance

- (chore) remove misfiled story artifacts and {project-root} shim (#404) — sprint-36 cleanup of two production incidents from the {project-root} placeholder bug; companion to the four fixes above.

## [1.133.0] — 2026-05-03

### Added

- add sidecar schema-drift detection to gaia-migrate (#398)
- extend dead-reference-scan allowlist for skill setup.sh / finalize.sh (#394)
- extract safe_grep_log shell helper (#393)
- absorb severity rubric format into gaia-code-review-standards (#392)
- migrate gaia-performance-review to seven-phase Evidence/Judgment template (#391)
- migrate gaia-test-review to seven-phase Evidence/Judgment template (#390)
- migrate gaia-test-automate to hybrid seven-phase + template (#389)
- migrate gaia-qa-tests to seven-phase Evidence/Judgment template (#388)
- migrate gaia-security-review to seven-phase Evidence/Judgment template (#387)
- resolve-config.sh --all batch mode + session-scoped cache (#384)
- require reproduction snippet in triage findings (#383)
- wire Fix workspace-guard hole in e45-s8-adr-finalize-che (#382)
- wire Refresh C9-FIXTURE-fake.md frozen-date li (#381)
- add claude-opus-4-7 to _SCHEMA.md model enum (#379)
- slugify.sh --help emits canonical Usage block (fix (#378)
- (e65-s1) review-skill template foundation with shared scripts, schema, and severity rubric (#377)

### Changed

- sweep legacy _memory/tier2-results paths and document Step 14 (#397)
- document bun test:bats vs bare bats fallback

### Fixed

- dedup story-file resolver matches by realpath (#401)
- support epic-grouped story file layout (#400)
- tighten dod-check.sh test resolver and subtask scope (#396)

## [1.132.0] — 2026-04-29

### Added

- (create-story) thin-orchestrator rewrite + e2e + token-savings benchmark (#374)
- (create-story) migrate SKILL.md + setup.sh to resolve-config.sh (#366)
- (create-story) add scaffold-story.sh + bats (#363)
- (create-story) add append-edge-case-tests.sh + bats (#362)
- (create-story) add append-edge-case-acs.sh + bats (#361)
- (create-story) add validate-frontmatter.sh + bats (#360)
- (create-story) add validate-ac-format.sh + bats (#359)
- (create-story) add validate-canonical-filename.sh + bats (#358)
- (create-story) add generate-frontmatter.sh + bats (#357)
- (create-story) add next-story-id.sh + bats
- (create-story) add deterministic slugify.sh and bats coverage (#355)
- pin validator.md model to claude-opus-4-7 + document Val opus-pin contract
- pin model claude-opus-4-7 + effort high in 10 Val-dispatching skills (#353)
- add four flat artifact-path keys to project-config.yaml (#351)
- wire gaia-create-story Step 4 to read sizing_map for points derivation (#350)
- add sizing_map block to project-config.yaml + reclassify in MIGRATION (#349)
- wire Dev-story tooling quirks cleanup (#345)
- (dev-story) rewrite gaia-run-all-reviews skill as thin orchestrator with --force flag (#342)
- (dev-story) wire script invocations into SKILL.md Steps 1/10/11 (#341)
- (dev-story) review-runner.sh true orchestration harness (#339)
- (dev-story) add pr-body.sh and commit-msg.sh (#336)
- (dev-story) add promotion-chain-guard.sh and check-deps.sh (#335)
- (dev-story) add tdd-review-gate.sh decision script (#334)
- (dev-story) add story-parse.sh and detect-mode.sh (#331)
- (agents) add tdd-reviewer fork-context subagent (#330)

### Changed

- (e38-s1-reconcile-risk) migrate CATALOG fixture to per-test TEST_TMP path (#371)
- (retro) swap action-items-increment.sh for shared writer delegation (#370)
- (skills) reconcile action-items.yaml path to planning-artifacts (#369)
- (resolve-config) replace frozen-date literals with sentinel (#368)
- (config) document four artifact-path keys in migration doc (#367)
- (skills,claude-md) add status-edit discipline critical rule (#365)
- bats coverage for the four artifact-path keys (#352)
- delete update-story-status.sh deprecation wrappers (#348)
- update bats tests for wrapper removal (#347)

### Fixed

- (dev-story) close ac4 integration smoke gap (e57-s8) (#344)
- (dev-story) close ac5 absence-assertion gap (e57-s8) (#343)

## [1.131.0] — 2026-04-28

### Added

- (dev-story) step 6b conditional-check advisory hints (#325)
- (dev-story) auto-reviews YOLO-only step 16 + 4 helper scripts + bats coverage (#323)
- (dev-story) val-in-tdd single post-refactor pass (#322)
- (dev-story) atdd gate + plan-structure validator + figma graceful-degrade (#321)
- (dev-story) non-YOLO three-option planning gate (approve/revise/validate) (#320)
- (dev-story) yolo val auto-validation loop with 3-iter cap and audit file (#319)
- (dev-story) hard-halt planning gate via AskUserQuestion (#317)

### Changed

- (yolo) add ..5 conformance bats for disambiguation guard (#324)

### Fixed

- (dev-story) emit step6b_gate stderr log + extend bats coverage

## [1.130.0] — 2026-04-28

### Added

- (create-story) add YOLO param + non-YOLO [u]/[a] routing prompt (#311)
- (create-story) restore V1 edge-case pipeline Steps 3b/3c/3d (#310)
- (create-story) conditional ux-designer routing + parallel spawn (#309)
- (scripts) unified transition-story-status.sh (#308)

## [1.129.0] — 2026-04-27

### Added

- (teach-testing) operationalize JIT discipline + progressive gating
- (mobile-testing) add 90% device coverage rule and cloud config
- (scripts) producer-side token_estimate emit for val auto-fix loop
- (skills) canonical document-rulesets for Phase 1 artifact types (#289)
- (skills) inline-ask + scan-depth doc in /gaia-index-docs (#287)
- (skills) inline confirm + slug algorithm in /gaia-merge-docs (#286)
- (skills) inline-ask on empty arguments in /gaia-shard-doc (#285)
- (skills) inline-ask + Next-Steps clarification in /gaia-summarize (#284)
- (skills) per-dimension justification + migration trigger in /gaia-nfr (#283)
- (skills) empty-context fallback interrogation in /gaia-problem-solving (#282)
- (skills) severity prompt + rule table + fallback warning in /gaia-fill-test-gaps (#281)
- (skills) explicit WCAG-level prompt + criterion mapping in /gaia-a11y-testing (#280)
- (skills) inline AC linkage + pinned schemas in /gaia-test-gap-analysis (#279)
- (skills) brownfield test-env pause + per-subagent scan diagnostics (#278)
- (skills) add threat-model linkage to /gaia-review-security (#277)
- (skills) plumb threat-model context into Zara dispatch (#276)
- (skills) restore Val gate + assessment-doc in /gaia-add-feature (#275)
- (skills) add /gaia-innovation native skill (#274)
- (skills) add /gaia-design-thinking native skill
- narrow product-brief INDEX_GUIDED scope to brainstorm
- add /gaia-product-brief plugin template and analyst assignment
- restore /gaia-create-ux Import mode + read-only audit (#270)
- restore /gaia-create-ux Generate mode + audit
- readiness-check priority/schedule + compliance + self-contradiction (#268)
- document /gaia-adversarial Step 4 invocation contract
- add /gaia-ci-setup schema validation retry loop (#266)
- add /gaia-create-arch tech-stack pause + ADR sidecar write
- add /gaia-edit-test-plan orchestrator trigger inheritance
- add /gaia-atdd batch mode, red-phase, and graceful exit
- add / scope-boundary regression test
- add token-budget verification harness
- document Val auto-fix iteration log format and witness
- wire Val auto-review into 3 Phase 3 Testing artifact skills
- wire Val auto-review into 6 Phase 3 Solutioning artifact skills
- wire Val auto-review into 3 Phase 2 + product-brief skills
- wire Val auto-review into 4 Phase 1 artifact skills (#252)
- auto-save session memory at finalize for 24 Phase 1-3 skills (#251)
- static `## Next Steps` sections for 10 lifecycle skills (#250)
- declare discover-inputs strategy on 6 lifecycle skills
- quality gates pre_start/post_complete in setup.sh/finalize.sh
- yolo mode contract helper + framework lint
- open-question detection helper + wire into 18 skills
- add SIGINT/SIGTERM trap handler to gaia-migrate.sh
- port /gaia-test-framework + /gaia-atdd + /gaia-ci-setup checklists to V2
- port /gaia-edit-test-plan and /gaia-test-design checklists to V2
- port /gaia-readiness-check 65-item checklist to V2
- port /gaia-infra-design 25-item checklist to V2
- port /gaia-threat-model 25-item checklist to V2 (#235)
- port /gaia-create-epics 31-item checklist to V2 (#234)
- port /gaia-edit-arch 25-item checklist to V2
- port /gaia-create-arch 33-item checklist to V2
- port /gaia-create-ux 26-item checklist to V2
- port /gaia-create-prd 36-item checklist to V2
- port /gaia-product-brief 27-item checklist to V2
- port /gaia-tech-research 22-item checklist to V2
- port /gaia-domain-research 22-item checklist to V2
- port /gaia-market-research 28-item checklist to V2
- port /gaia-brainstorm 24-item checklist to V2
- gaia-resume JSON consumption contract
- checkpoint failure-mode handling (corruption, partial writes)
- wire checkpoint writes into 8 Phase 3 Testing skills
- wire checkpoint writes into 8 Phase 3 Solutioning skills
- (checkpoint) wire write-checkpoint.sh into Phase 2 skills
- (checkpoint) wire write-checkpoint.sh into Phase 1 skills
- (checkpoint) add write-checkpoint.sh schema v1 helper
- (release) automate plugin release on staging-to-main merge

### Changed

- (skills) review-deps runtime-first ordering + tier collapse
- (skills) perf-testing baseline mandate + CRP techniques
- (skills) memory-hygiene token recovery + cross-agent matrix
- (skills) ci-edit cascade targets + failure surfacing
- (skills) performance-review percentiles + file logging
- (skills) project-context TRUNCATED marker + inference
- (skills) document-project manifest entries + counts
- (skills) changelog version validation + excluded commits
- (skills) refresh-ground-truth budget check + entry schema
- (skills) editorial-structure doc-type conventions
- (skills) document editorial-prose default save behaviour
- (sprint-state) add wrapper-sync invariant bats test
- allowlist V1 checkpoint deletion plan fixture in dead-reference-scan
- add V1 checkpoint deletion plan + sunset window
- scrub V1-engine references from fixture for guard
- pin canonical finalize-checklist.sh contract in
- add bats wall-clock budget-watch invariant
- implement Val auto-fix loop pattern
- formalize /gaia-val-validate upstream integration contract
- add direct unit tests for canonical_states_hint and assert_canonical_state
- complete public-function coverage signal
- add coverage signal for resume-discovery.sh public functions
- (bats-tests) bump job timeout from 2m to 5m for growing bats suite
- consolidate per-skill step-count tests to fit 2-min CI cap
- (checkpoint) declare coverage signal for helper functions
- (checkpoint) harden AC-EC7 PATH isolation for Linux CI
- (changelog) note pivot to PR-based release model

### Fixed

- (skills) scrub legacy core/engine ref from refresh-ground-truth
- (tests) stabilize flaky perf test (#290)
- (skills) align tech-research artifact_type slug with filename (#288)
- rename contract heading to avoid Step-N count inflation
- keep gaia-create-arch checkpoint count at 13 (sub-steps no-emit)
- replace BSD/mawk-incompatible awk word boundaries with portable form
- skip test-plan.md row checks when project-root is unavailable
- seed brainstorm fixture in audit and e2e harnesses
- mark yolo-lint internal helpers private
- mark detect-open-questions internal helpers private
- sprint-state transition emits canonical enum hint and guards writers
- tighten sprint-state reconcile glob to require story frontmatter
- scrub legacy-engine path refs from finalize.sh comments
- make finalize.sh opt-in and tests self-contained
- (checkpoint) scrub workflow.xml reference from write-checkpoint.sh header

## [1.128.0] — 2026-04-23

### Added

- (release) pivot release.yml to PR model

## [1.127.2] — 2026-04-23

### Added

- Release automation pipeline . The first automated release will land in v1.128.0.

### Changed

- **Release-pipeline amendment (2026-04-23):** `release.yml` pivoted from direct-bot-push to a PR-based model. Branch protection on `main` requires PR + status checks, which the original direct-push design could not satisfy. The workflow now has two modes — `prepare` (opens a `release/vX.Y.Z` PR on qualifying commits to main) and `publish` (cuts tag + GitHub Release when the release PR merges). Manual work per release: one click to merge the release PR.
- **2026-05-13 — squash-merge interaction with `release.yml`:** observed that staging→main PRs merged via `--squash` collapse the underlying `feat(...)` commits into a single squash commit whose subject ("staging → main: ...") fails `classify-commits.js`'s Conventional Commit regex. Result: `bump_size=none` and no release PR opens. Workaround until `merge.sh` is changed to use `--merge` for staging→main: cut a recovery PR with a `feat:` subject + a path change under `plugins/gaia/**` to re-trigger the `prepare` job. Follow-up story to wire `merge.sh` for `--merge` on staging→main.
- **2026-05-14 — empty-commit publish-trigger interaction with path-filtered `release.yml`:** during the v1.152.0 republish recovery, observed that empty commits (used to satisfy `detect-mode`'s publish-regex via subject-only signaling) do NOT trigger `release.yml` because the workflow's `paths: ['plugins/gaia/**', '.github/workflows/release.yml']` filter rejects path-empty pushes. Fix: any commit intended to fire `release.yml` MUST touch at least one path matching the filter. This 1-line CHANGELOG note IS that path-touching change for the v1.152.0 republish.

Initial changelog seeded by . Prior history available via `git log --oneline -- plugins/gaia/`.
