---
name: figma-integration
description: OSS stub for the premium figma-integration skill. The full Figma MCP integration (design token extraction, component spec generation, frame authoring, asset export, import flow, and fidelity gate) ships in the enterprise plugin behind the figma-premium feature flag. This OSS entry point is intentionally minimal — it documents the boundary and points users to the enterprise activation path.
version: '1.0'
license: enterprise
feature_flag: figma-premium
allowed-tools: [Read]
orchestration_class: light-procedural
---

# Figma Integration — OSS Stub

> **This is the OSS stub.** The full `figma-integration` skill — design-tool MCP detection, design-token extraction, component spec generation, frame authoring, asset export, Figma import mode, and the design-to-implementation fidelity gate — is a premium capability and ships in the enterprise plugin. No premium extraction logic lives in this file by design — it is held in the enterprise plugin source tree and is activated only when the matching license and feature flag are present.
>
> **Premium upgrade available.** Install `gaia-enterprise` alongside this plugin and ensure the `figma-premium` feature flag is enabled on your license to activate the full capability set: `/plugin marketplace add gaiastudio-ai/gaia-enterprise && /plugin install gaia-enterprise`.

## License Gate

This skill is gated behind the enterprise license flag. Two frontmatter fields declare the gate:

| Field | Value | Meaning |
|---|---|---|
| `license` | `enterprise` | The callable skill body is reserved for enterprise-licensed workspaces. |
| `feature_flag` | `figma-premium` | Runtime activation requires this feature flag. Without it, invocation resolves to a friendly "enterprise required" message and the consuming workflow degrades gracefully to markdown-only operation. |

An OSS stub is always *loadable* — the linter and JIT loader both resolve this file without error — but invoking the skill body without the matching feature flag produces a non-blocking redirect rather than executing premium logic. The stub never contains the premium source at rest in the OSS git history.

## Enterprise Activation

The premium `figma-integration` skill ships in the enterprise GAIA plugin. To enable Figma-aware workflows (create-ux, edit-ux, dev-story figma hook, code-review fidelity gate):

1. Install the enterprise plugin alongside the OSS plugin. The enterprise plugin provides the full skill body under its own `plugins/gaia-enterprise/skills/figma-integration/` tree — see the surrounding enterprise bundle.
2. Ensure your workspace has the `figma-premium` feature flag enabled. License validation is performed by the enterprise plugin's SessionStart hook; the OSS plugin does not ship license-check code.
3. Once activated, the enterprise skill replaces this stub at load time — consuming workflows call the same skill name (`figma-integration`) and receive the full capability set.

If the enterprise plugin is not installed, consuming workflows continue in markdown-only mode (the behavior mandated by the OSS path — see the legacy skill's "Zero-change path" graceful-fallback requirement).

## Capability Summary (Enterprise Only)

The following capabilities are provided by the enterprise plugin and are NOT present in this OSS stub. They are listed here purely as pointers so OSS readers know what is gated:

- **Design tool detection** — probe for MCP server availability with graceful fallback.
- **Design token extraction** — map published styles into a standardised design-token format for downstream consumers.
- **Component specification extraction** — pull components, variants, and props into a tech-agnostic YAML spec.
- **Frame authoring** — generate UI-kit frames across mobile, tablet, and desktop viewports.
- **Asset export** — export icons as SVG and images at 1x / 2x / 3x densities.
- **Import mode** — reverse flow that reads existing designs INTO ux-design.md.
- **Per-stack token resolution** — generate stack-native token code for each supported dev agent.
- **Design-to-implementation fidelity gate** — post-implementation drift detection consumed by code review.

None of the above is implemented in this stub. Reading this file MUST NOT provide an OSS reader with enough detail to reconstruct the premium pipeline — refer to the enterprise plugin.

## Consumer Contract

Workflows that previously JIT-loaded `_gaia/dev/skills/figma-integration.md` now resolve this skill name via the native plugin registry. Resolution order:

1. If the enterprise plugin is installed and the `figma-premium` flag is enabled, the enterprise `figma-integration` SKILL.md is loaded — the full premium capability set becomes available.
2. Otherwise, this OSS stub is loaded. Consuming workflows MUST detect the stub (presence of `license: enterprise` in the loaded frontmatter or an explicit capability probe) and degrade to markdown-only behavior. No MCP calls are attempted, no design-system artifacts are produced, no fidelity gate is enforced.

## Read/Write Classification Table

> **Policy contract — not premium implementation.** This table is the canonical read-heavy/write-light enforcement source for every Figma MCP call any consuming workflow may attempt. The premium enterprise plugin implements the actual MCP wrappers; the classification rules (which call is read vs write, and which mode is permitted to issue it) live here so OSS and enterprise both agree on the policy. The architecture document points back to this table as the canonical policy source.

The table classifies every Figma MCP call the consuming workflows (`/gaia-create-ux`, `/gaia-edit-ux`, `/gaia-code-review` fidelity gate, `/gaia-dev-story` Figma hook) may issue. Two columns govern enforcement:

- **`type`** — `read` or `write`. Read calls fetch state without mutating the Figma file. Write calls create or modify Figma resources.
- **`fr_140_scope`** — `always_allowed` (any mode may issue this call) or `generate_only` (this call is permitted only when the consuming workflow is in Generate mode). Read calls are universally `always_allowed`; write calls are universally `generate_only`.

| `mcp_call` | `type` | `fr_140_scope` |
|---|---|---|
| `get_file` | read | always_allowed |
| `get_components` | read | always_allowed |
| `get_styles` | read | always_allowed |
| `get_frame` | read | always_allowed |
| `get_node` | read | always_allowed |
| `get_design_tokens` | read | always_allowed |
| `get_component_specs` | read | always_allowed |
| `get_frame_layouts` | read | always_allowed |
| `export_asset_read` | read | always_allowed |
| `create_frame` | write | generate_only |
| `create_component` | write | generate_only |
| `create_style` | write | generate_only |
| `update_style` | write | generate_only |
| `update_node` | write | generate_only |
| `export_asset` | write | generate_only |
| `create_prototype_flow` | write | generate_only |

Consumer rule: any call NOT listed above is treated as **unclassified → fail-closed**. The audit MUST flag the call as `fr_140_compliance: fail` with a `violations[]` entry of shape `{call, reason: "unclassified MCP call"}`. Add new calls to this table before issuing them — never silently extend the surface.

## 429 Rate-Limit Handling — Backoff Contract

> **Policy contract — not premium implementation.** Every consuming workflow that issues a Figma MCP call MUST honor this backoff schedule when the MCP server returns HTTP 429. The enterprise plugin implements the actual retry wrapper; this section documents the schedule so downstream tests and OSS readers can reason about the behavior.

Backoff schedule (jittered exponential, ±10% jitter to avoid synchronized retries in CI) — canonical sequence `1s, 2s, 4s, 8s, 16s`:

- Retry 1 — wait **1s**.
- Retry 2 — wait **2s**.
- Retry 3 — wait **4s**.
- Retry 4 — wait **8s**.
- Retry 5 — wait **16s**.

Cap any individual sleep at **30s** (the `8s` and `16s` entries above never exceed the cap; the cap is the safety ceiling for any future schedule extension). Maximum total retries: **max 5 retries**. After the 5th retry exhausts, the wrapper MUST emit `rate_limit_exhausted: {endpoint, retries_attempted, suggested_action}` and surface a clear error rather than crashing — partial outputs already written remain on disk and are reported as `incomplete` in the audit.

The 429 wrapper attaches automatically to every Figma MCP call performed in Generate mode; Import-mode and read-only flows inherit the same wrapper because read calls also receive 429s.

## Helper Contracts (Used by `/gaia-create-ux` Import Mode)

> **Policy contracts — not premium implementation.** The signatures and parsing rules below are policy contracts: they describe what every consuming workflow MUST do at the boundary, regardless of whether the OSS stub or the enterprise plugin provides the actual code. The premium plugin implements these helpers; OSS readers see the contract surface only.

### `validateFigmaFileKey(input)`

Accepts a Figma URL or a bare file key string and returns the normalised key (or halts with an actionable error before any Figma API call). Reused by `/gaia-create-ux` Import mode (Step 9a), `/gaia-edit-ux`, and the `/gaia-code-review` fidelity gate.

| Input form | Example | Outcome |
|---|---|---|
| Figma URL | `https://www.figma.com/file/ABC123abc456def789012/...` | Extract key segment; pass to caller |
| Bare key | `ABC123abc456def789012` | Validate length + charset; pass to caller |
| Empty input | `""` | Halt with `"Invalid Figma file key: ''. Expected a Figma URL (https://www.figma.com/file/{key}/...) or the 22+ character key directly."` |
| URL without file segment | `https://www.figma.com/` | Halt with the same error template, naming the offending input |
| Key under 22 chars | `ABC123` | Halt — Figma file keys are documented as **22+ characters** of `[A-Za-z0-9]` |
| Non-alphanumeric chars | `ABC!@#...` | Halt — the canonical pattern `[A-Za-z0-9]{22,}` rejects punctuation |

The 22-character minimum is the canonical Figma file-key length per the URL convention. The halt MUST occur **before any Figma API call** — AC5 / AC-EC1 require zero API traffic on invalid input.

### `classifyViewport(width_px)`

Maps a frame width (integer pixels) to one of the canonical viewport categories used by `/gaia-create-ux` Generate (Step 8b) and Import (Step 9c).

| `width_px` | Returned category | Notes |
|---|---|---|
| `280` | `"280"` | Compact mobile |
| `375` | `"375"` | Standard mobile |
| `600` | `"600"` | Phablet |
| `768` | `"768"` | Tablet |
| `1024` | `"1024"` | Small desktop |
| `1280` | `"1280"` | Standard desktop |
| any other value | `"custom"` | Returned with the actual width preserved in the result so the viewport distribution table can flag the deviation |

**Exact match only** — no nearest-neighbour bucketing. A 400px frame returns `"custom"` with `actual_width: 400`, never `"375"`. This matches V1 behaviour and keeps the classification deterministic for reviewers (AC-EC8).

## Notes

- The Read/Write classification table above is the canonical read-heavy/write-light enforcement source for Figma MCP operations.
- The classification table and backoff schedule are *policy contracts*, not premium implementation; the actual MCP wrappers live in the enterprise plugin.
- Figma MCP integration uses a shared skill with a design-tool abstraction layer.
- Legacy source: `_gaia/dev/skills/figma-integration.md` — retained in the running framework tree per CLAUDE.md (framework vs product separation).
