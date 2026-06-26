# Environment Variable Reference

Canonical reference for environment variables that gate behavior, override
paths, or control framework strictness across GAIA scripts.

<!-- SECTION: path-resolution -->
## Path Resolution

These variables control where the framework locates its directories.
Most are set by `scripts/lib/gaia-paths.sh` (auto-sourced) or by the
Claude Code substrate.

| Variable | Purpose | Default |
|---|---|---|
| `CLAUDE_PROJECT_ROOT` | Absolute path to the project root; set by the Claude Code substrate. Primary anchor for all path resolution. | *(substrate-provided)* |
| `CLAUDE_PLUGIN_ROOT` | Absolute path to the installed GAIA plugin directory; set by the Claude Code substrate. Used to locate schemas, knowledge, and scripts shipped with the plugin. | *(substrate-provided)* |
| `CLAUDE_SKILL_DIR` | Absolute path to the currently executing skill directory; set by the substrate during slash-command dispatch. | *(substrate-provided)* |
| `GAIA_CONFIG_DIR` | Path to `.gaia/config/`. Overridable via `GAIA_CONFIG_PATH`. | `${CLAUDE_PROJECT_ROOT}/.gaia/config` |
| `GAIA_ARTIFACTS_DIR` | Path to `.gaia/artifacts/`. Overridable via `GAIA_ARTIFACTS_PATH`. | `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts` |
| `GAIA_STATE_DIR` | Path to `.gaia/state/`. Overridable via `GAIA_STATE_PATH`. | `${CLAUDE_PROJECT_ROOT}/.gaia/state` |
| `GAIA_MEMORY_DIR` | Path to `.gaia/memory/`. Overridable via `GAIA_MEMORY_PATH`. | `${CLAUDE_PROJECT_ROOT}/.gaia/memory` |
| `GAIA_CUSTOM_DIR` | Path to `.gaia/custom/`. Overridable via `GAIA_CUSTOM_PATH`. | `${CLAUDE_PROJECT_ROOT}/.gaia/custom` |
| `GAIA_KNOWLEDGE_DIR` | Path to `.gaia/knowledge/` (Brain layer). Overridable via `GAIA_KNOWLEDGE_PATH`. | `${CLAUDE_PROJECT_ROOT}/.gaia/knowledge` |
| `GAIA_CHECKPOINT_DIR` | Path to the checkpoint subdirectory under memory. | `${GAIA_MEMORY_DIR}/checkpoints` |
| `GAIA_PROJECT_ROOT` | Legacy alias for `CLAUDE_PROJECT_ROOT`; honored as a fallback when the substrate variable is unset. | `${PWD}` |
| `GAIA_PROJECT_PATH` | Alternate fallback for project root used by some older scripts. | `${CLAUDE_PROJECT_ROOT}` |

### Legacy per-bucket overrides

These bare-name variables are consumed by scripts that predate the `gaia-paths.sh`
consolidation. They override individual artifact bucket paths.

| Variable | Purpose | Default |
|---|---|---|
| `PLANNING_ARTIFACTS` | Override path to planning-artifacts bucket. | `${GAIA_ARTIFACTS_DIR}/planning-artifacts` |
| `IMPLEMENTATION_ARTIFACTS` | Override path to implementation-artifacts bucket. | `${GAIA_ARTIFACTS_DIR}/implementation-artifacts` |
| `TEST_ARTIFACTS` | Override path to test-artifacts bucket. | `${GAIA_ARTIFACTS_DIR}/test-artifacts` |
| `PROJECT_CONFIG` | Override path to `project-config.yaml`. | `${GAIA_CONFIG_DIR}/project-config.yaml` |
| `SPRINT_STATUS_YAML` | Override path to `sprint-status.yaml`. | `${GAIA_STATE_DIR}/sprint-status.yaml` |

<!-- SECTION: lifecycle-strictness -->
## Lifecycle and Strictness

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_STRICT_LIFECYCLE` | When `1`, enforce strict lifecycle transition rules (no skipping statuses). When `0`, allow loose transitions. Resolved via `lib/lifecycle-strict-mode.sh`, which also reads the config file. | *(config-driven; unset = check config)* |
| `GAIA_NEXT_STEP_STRICT` | When `1`, enforce that the next-step prompt is always displayed. | `0` (off) |
| `GAIA_TEST_STRICT` | When `1`, enforce stricter test-policy checks. | `0` (off) |
| `GAIA_TEST_TAGGING_STRICT` | When `1`, require all bats tests to carry component tags. | `0` (off) |
| `GAIA_HELP_STRICT` | When `1`, strict help routing (error on ambiguous queries). | `0` (off) |
| `GAIA_NONINTERACTIVE` | When `1`, suppress interactive prompts (CI mode). | unset (interactive) |

<!-- SECTION: sprint-state -->
## Sprint State

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_STATE_YAML` | Path to `sprint-status.yaml`; consumed by the sprint-status dashboard. | `${GAIA_STATE_DIR}/sprint-status.yaml` |
| `GAIA_YOLO_SENTINEL` | Override path to the `.yolo-active` sentinel file. | `${GAIA_STATE_DIR}/.yolo-active` |
| `GAIA_YOLO_FLAG` | Set to `1` to force YOLO mode on. | unset |
| `GAIA_YOLO_MODE` | Set to `1` to force YOLO mode on (alternate spelling). | unset |
| `GAIA_YOLO_OVERRIDE` | When `1`, override the YOLO session-binding check. | unset |
| `GAIA_ESCALATION_HALT` | When `1`, halt on review escalation. | unset |
| `GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE` | When `1`, permit review-to-done transition without passing the review gate. | unset (gate enforced) |
| `GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL` | When `1`, permit sprint close without the sprint-review sentinel. | unset (sentinel required) |

<!-- SECTION: test-execution -->
## Test Execution

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_BRIDGE_INVOKE` | When `1`, invoke the test-execution bridge adapter. | unset |
| `GAIA_TESTS_CONFIG` | Override path to test-execution configuration. | *(config-driven)* |
| `GAIA_TEST_ENV_CALLER` | Identifies the caller context for test environment setup. | unset |
| `GAIA_DEVICE_FARM_MOCK` | When `1`, mock device-farm interactions in test mode. | unset |

<!-- SECTION: brownfield-tools -->
## Brownfield and Deterministic Tools

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_BROWNFIELD_DETERMINISTIC_TOOLS` | When `1`, enable the deterministic-tools adapter layer. | unset |
| `GAIA_BROWNFIELD_GRYPE_ENABLED` | When `1`, enable Grype vulnerability scanning. | unset |
| `GAIA_BROWNFIELD_DEDUP_ENABLED` | When `1`, enable SARIF dedup in brownfield scans. | unset |
| `GAIA_BROWNFIELD_SARIF_MERGE_ENABLED` | When `1`, enable SARIF merge across brownfield adapters. | unset |
| `GAIA_BROWNFIELD_SBOM_COMPLETENESS_ENABLED` | When `1`, enable SBOM completeness check. | unset |
| `GAIA_BROWNFIELD_PREWARM_ENABLED` | When `1`, enable brownfield prewarm cache. | unset |
| `GAIA_BROWNFIELD_AUDIT_DIR` | Override the brownfield audit output directory. | *(derived from artifacts dir)* |
| `GAIA_BROWNFIELD_DEFECTDOJO_ENABLED` | When `1`, enable DefectDojo integration. | unset |
| `GAIA_BROWNFIELD_DEFECTDOJO_API_URL` | DefectDojo API URL. | unset |
| `GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN` | DefectDojo API token. **Secret** — provide via CI secret store or gitignored `.env`; never commit to version control. | unset |
| `GAIA_BROWNFIELD_DEFECTDOJO_ENGAGEMENT_ID` | DefectDojo engagement ID. | unset |
| `GAIA_TOOLS_RUNNER` | Container runner for deterministic tools (`docker` or `podman`). | `docker` |
| `GAIA_TOOLS_IMAGE` | Docker image for deterministic tools. | *(built-in default)* |
| `GAIA_TOOLS_TIMEOUT` | Timeout in seconds for tool execution. | `600` |
| `GAIA_TOOLS_NETWORK` | Docker network mode for tool containers. | `none` |
| `GAIA_GRYPE_DB_FILE` | Path to a pre-downloaded Grype database file. | unset |
| `GAIA_GRYPE_DEBUG` | When `1`, enable debug output for Grype adapter. | unset |

<!-- SECTION: deploy-release -->
## Deploy and Release

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_DEPLOY_BIN` | Override path to the deploy adapter binary/script. | *(adapter-resolved)* |
| `GAIA_DEPLOY_EVIDENCE_DIR` | Directory for deployment evidence artifacts. | *(derived from artifacts dir)* |
| `GAIA_RELEASE_BIN` | Override path to the release adapter binary/script. | *(adapter-resolved)* |
| `GAIA_VERSION_BUMP_BIN` | Override path to the version-bump script. | *(adapter-resolved)* |

<!-- SECTION: ci-config -->
## CI and Configuration

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_RESOLVE_CONFIG` | Override path to the config resolver script. | *(plugin-shipped)* |
| `GAIA_SHARED_CONFIG` | Path to a shared (org-level) configuration overlay. | unset |
| `GAIA_LOCAL_CONFIG` | Path to a local-only configuration overlay. | unset |
| `GAIA_CONFIG_CACHE` | When `1`, cache resolved configuration. | unset |
| `GAIA_RUBRIC_SCHEMA` | Override path to rubric schema. | *(plugin-shipped)* |
| `GAIA_RUBRICS_ROOT` | Override path to rubrics directory. | *(plugin-shipped)* |
| `GAIA_COMPLIANCE_REGIMES` | Comma-separated compliance regime identifiers (e.g. `soc2,hipaa`). | unset |
| `GAIA_NO_PROJECT_WALKUP` | When `1`, disable upward config-file walk (strict CWD). | unset |
| `GAIA_AFFECTED_SET_BIN` | Override path to the affected-set resolver script. | *(plugin-shipped)* |
| `GAIA_PROTECTED_JOBS_LIST` | Comma-separated list of CI job names that must never be skipped by affected-only narrowing. | unset |

<!-- SECTION: version-framework -->
## Version and Framework Identity

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_VERSION` | Current framework version string (read from `.plugin-version`). | *(plugin-shipped)* |
| `GAIA_VERSION_CACHED` | Cached version string to avoid repeated file reads. | unset |
| `GAIA_FRAMEWORK_VERSION` | Alias for the framework version; used by reconciliation and migration scripts. | *(plugin-shipped)* |
| `GAIA_SKIP_VERSION_CHECK` | When `1`, skip the framework version check at startup. | unset |
| `GAIA_FW_VER_IN_RESOLVER` | When `1`, embed the framework version in config-resolver output. | unset |

<!-- SECTION: session-identity -->
## Session and Identity

| Variable | Purpose | Default |
|---|---|---|
| `CLAUDE_CODE_SESSION_ID` | Session identifier set by the Claude Code substrate. Used by YOLO sentinel session-binding. | *(substrate-provided)* |
| `GAIA_SESSION_ID` | Legacy session ID; fallback when substrate ID is unavailable. | unset |
| `GAIA_SESSION_DIR` | Directory for per-session state. | *(derived from state dir)* |
| `GAIA_SESSION_TRANSCRIPT` | Path to the session transcript file. | unset |

<!-- SECTION: ground-truth -->
## Ground Truth and Validation

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_GT_FILENAME` | Override the ground-truth filename (default `ground-truth.md`). | `ground-truth.md` |
| `GAIA_GT_IMPL_ROOT` | Override path to implementation root for ground-truth scanning. | *(project-root-derived)* |
| `GAIA_GT_PLANNING_ROOT` | Override path to planning root for ground-truth scanning. | *(project-root-derived)* |
| `GAIA_GT_SESSION_REF` | Session reference tag for ground-truth provenance. | unset |
| `GAIA_GT_SIDECAR_AGENT` | Agent name for the ground-truth sidecar. | unset |

<!-- SECTION: misc -->
## Miscellaneous

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_OFFLINE` | When `1`, skip all network calls (fully offline mode). | unset |
| `GAIA_RICH` | When `1`, enable rich terminal output (color, Unicode). | unset |
| `GAIA_CONTEXT` | Free-form context string passed through to scripts. | unset |
| `GAIA_EXECUTION_CONTEXT` | Identifies the execution context (e.g. `ci`, `local`, `agent`). | unset |
| `GAIA_MARKER` | Marker string used by framework instrumentation. | unset |
| `GAIA_PROVENANCE_LOG` | Path to the provenance log file for artifact lineage tracking. | unset |
| `GAIA_MIGRATE_ALLOW_FORCE` | When `1`, allow force mode during V1-to-V2 migration. | unset |
| `GAIA_SKIP_ORPHAN_SWEEP` | When `1`, skip the orphan-artifact sweep during cleanup. | unset |
| `GAIA_DISCOVERY_NOW` | Timestamp override for discovery-board entries. | unset |
| `GAIA_DSSI_PROTECTED_BRANCHES` | Comma-separated protected branch names for DSSI (secret scanning). | unset |
| `GAIA_DSSI_SECRET_CONTENT_PATTERNS` | Pipe-separated regex patterns for secret content detection. | *(built-in defaults)* |
| `GAIA_GIT_PUSH_BACKOFF` | Back-off seconds between push retries. | `5` |
| `GAIA_PUSH_VERIFY` | When `1`, verify push success via remote ref check. | unset |
| `GAIA_VERIFY_PUSH_REMOTE` | Remote name for push verification. | `origin` |

<!-- SECTION: statusline -->
## Statusline

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_STATUSLINE_THEME` | Statusline theme name. | `rich` |
| `GAIA_STATUSLINE_ASCII` | When `1`, use ASCII-only glyphs (no Unicode). | unset |
| `GAIA_STATUSLINE_NERDFONT` | When `1`, enable Nerd Font glyphs. | unset |
| `GAIA_STATUSLINE_NO_COLOR` | When `1`, disable color in statusline output. | unset |
| `GAIA_STATUSLINE_BRANCH_OVERRIDE` | Override the displayed branch name. | *(git-derived)* |
| `GAIA_STATUSLINE_DIRTY_RECURSE_SUBMODULES` | When `1`, recurse submodules for dirty-state checks. | unset |

<!-- SECTION: brownfield-deadcode -->
## Dead-Code Analysis (Brownfield)

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED` | When `1`, enable Python dead-code detection via Vulture. | unset |
| `GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED` | When `1`, enable JVM dead-code detection via SpotBugs. | unset |
| `GAIA_BROWNFIELD_DEADCODE_GO_ENABLED` | When `1`, enable Go dead-code detection. | unset |

<!-- SECTION: prewarm-cache -->
## Prewarm Cache

| Variable | Purpose | Default |
|---|---|---|
| `GAIA_PREWARM_CACHE_DIR` | Directory for brownfield prewarm caches. | *(derived from artifacts dir)* |
| `GAIA_PREWARM_MAX_AGE_DAYS` | Maximum age in days before a prewarm cache entry is evicted. | `5` |
