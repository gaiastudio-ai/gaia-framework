<div align="center">

<a href="https://gaiastudio-ai.github.io/gaia-framework/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/Logo.png">
    <source media="(prefers-color-scheme: light)" srcset="./assets/Logo-light.png">
    <img alt="GAIA Framework" src="./assets/Logo-light.png" width="440">
  </picture>
</a>

### Your AI software team, inside Claude Code.

GAIA turns Claude Code into a full agile delivery team — 25 specialist agents that take you from a raw idea to merged, reviewed, tested code, with the rigor of a real engineering org and the speed of one operator.

<p align="center">
  <a href="https://github.com/gaiastudio-ai/gaia-framework/releases/latest"><img src="https://img.shields.io/github/v/release/gaiastudio-ai/gaia-framework?style=for-the-badge&labelColor=000000&color=6e56cf&label=release" alt="Latest release"></a>
  <a href="https://github.com/gaiastudio-ai/gaia-framework/actions/workflows/plugin-ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/gaiastudio-ai/gaia-framework/plugin-ci.yml?branch=main&style=for-the-badge&labelColor=000000&label=CI" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/gaiastudio-ai/gaia-framework?style=for-the-badge&labelColor=000000&color=3fb950" alt="License"></a>
  <a href="https://github.com/gaiastudio-ai/gaia-framework"><img src="https://img.shields.io/badge/Claude%20Code-plugin-d97757?style=for-the-badge&labelColor=000000" alt="Claude Code plugin"></a>
  <a href="https://github.com/gaiastudio-ai/gaia-framework/stargazers"><img src="https://img.shields.io/github/stars/gaiastudio-ai/gaia-framework?style=for-the-badge&labelColor=000000&color=e3b341" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="https://gaiastudio-ai.github.io/gaia-framework/"><b>Documentation</b></a>
  &nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#-quickstart">Quickstart</a>
  &nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#-how-it-works">How it works</a>
  &nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#-meet-the-team">Agents</a>
  &nbsp;&nbsp;•&nbsp;&nbsp;
  <a href="#%EF%B8%8F-gaia-vs-prompting-alone">Why GAIA</a>
</p>

</div>

---

## What is GAIA?

**GAIA (Generative Agile Intelligence Architecture) is an agile delivery platform for Claude Code.** Instead of prompting a single assistant and hoping for the best, you direct a coordinated team of specialist agents — a product manager, an architect, stack-specific developers, QA, security, and more — each an expert in their lane, each handing off to the next exactly like a real software org.

You bring the idea. GAIA runs the process: discovery, requirements, architecture, sprint planning, test-driven implementation, multi-angle review, and ceremony close — every artifact written to disk, every decision traceable, every story shipped behind a green pull request.

Think of it as **the agile SDLC, encoded as agents** — so a team of one moves like a team of twenty.

## ✨ Why GAIA

- 🧠 **A team, not a chatbot** — 25 named specialist agents (PM, architect, devs, QA, security, UX, SRE…) that collaborate and hand off like real colleagues.
- 🔄 **The full lifecycle** — idea → PRD → architecture → epics → sprint → TDD implementation → review → retro → close, all driven by slash commands.
- ✅ **Test-driven by default** — every story moves Red → Green → Refactor, then through a composite review gate before it can merge.
- 🛡️ **Six-angle review gate** — code, QA, security, test, performance, and accessibility reviewers must all sign off before a story reaches `done`.
- 🔍 **Independent validation** — a dedicated validator agent fact-checks every artifact against your actual codebase, so plans never drift from reality.
- 📐 **Everything is traceable** — PRDs, ADRs, stories, and tests are written to disk and cross-linked, giving you an auditable trail from requirement to merge.
- ⚡ **Two speeds** — full ceremony for real features, or `quick-spec` → `quick-dev` for small changes when you don't need the whole process.
- 🧩 **Greenfield or brownfield** — bootstrap a fresh project in minutes, or onboard an existing codebase with deep gap analysis.

## ⚖️ GAIA vs. prompting alone

|  | 💬 Plain Claude Code | 🌍 With GAIA |
|---|---|---|
| **Who's working** | One general assistant | 25 specialist agents, each an expert |
| **Process** | Ad-hoc, prompt-by-prompt | Structured SDLC: PRD → arch → sprint → dev → review |
| **Requirements** | Live in the chat, then vanish | Written to disk as PRDs, ADRs & stories — traceable |
| **Implementation** | "Write me X" | Test-driven: Red → Green → Refactor, on a branch |
| **Quality gate** | You eyeball the diff | Six reviewers (code/QA/security/test/perf/a11y) must pass |
| **Accuracy** | Plans can drift from the code | A validator fact-checks every artifact vs. your repo |
| **Shipping** | Copy-paste, hope it merges | Green PR, CI, merge — the loop closes itself |

## 🚀 Quickstart

Install the plugin from inside Claude Code:

```text
/plugin marketplace add gaiastudio-ai/gaia-framework
/plugin install gaia@gaiastudio-ai-gaia-framework
/reload-plugins
```

> `/reload-plugins` is required after install — it registers the agents and skills in your current session.

Then meet your team:

```text
/gaia
```

The orchestrator (Gaia) greets you, reads your project state, and routes you to the right next step. Starting something brand new? Run:

```text
/gaia-init
```

…and answer a short discovery questionnaire. GAIA scaffolds your config and you're ready to build.

**→ Full guide at [the documentation site](https://gaiastudio-ai.github.io/gaia-framework/).**

## 🔄 How it works

GAIA mirrors how a high-functioning team actually ships software. Each step is a slash command; each command is driven by the specialist who owns that work.

```text
  IDEA
   │
   ▼
  /gaia-brainstorm ───► /gaia-create-prd ───► /gaia-create-arch ───► /gaia-create-epics
   (explore)             (Derek · PM)         (Theo · Architect)     (epics + stories)
                                                                          │
                                                                          ▼
                                              /gaia-sprint-plan ◄───  /gaia-create-story
                                              (Nate · Scrum Master)   (detailed spec)
                                                          │
                                                          ▼
                                              /gaia-dev-story
                                              Red ► Green ► Refactor ► validate ► PR ► merge
                                                          │
                                                          ▼
                                              /gaia-review-all
                                              code · qa · security · test · perf · a11y
                                                          │
                                                          ▼
                                  /gaia-sprint-review ──► /gaia-retro ──► /gaia-sprint-close
```

In a brownfield repo, swap the front of the funnel for **`/gaia-brownfield`**, which scans your codebase, finds the gaps, and generates the missing artifacts. Need a small change without the full ceremony? **`/gaia-quick-spec`** → **`/gaia-quick-dev`** gets you there in two commands.

## 👥 Meet the team

GAIA ships **25 specialist agents** — each a named persona with deep domain expertise. The orchestrator (**Gaia**) routes work to whoever should own it. Here are the core players:

| Role | Agent | What they own |
|------|-------|---------------|
| 🧭 Orchestrator | **Gaia** | Routes you to the right agent or workflow |
| 📋 Product Manager | **Derek** | PRDs, requirements discovery, stakeholder alignment |
| 🏛️ Architect | **Theo** | System design, technical decisions, API contracts |
| 🏃 Scrum Master | **Nate** | Sprint planning, story prep, agile ceremonies |
| 📊 Business Analyst | **Elena** | Market research, competitive & requirements analysis |
| 🔬 Validator | **Val** | Independent fact-checking of every artifact vs. the codebase |
| 🧪 QA Engineer | **Vera** | Test generation, API & E2E testing, coverage |
| 🛡️ Security | **Zara** | Threat modeling, OWASP reviews, STRIDE/DREAD |
| 🏗️ Test Architect | **Sable** | Risk-based test strategy, CI quality gates, ATDD |
| ⚡ Performance | **Juno** | Load testing, profiling, Core Web Vitals, P99 |
| 🎨 UX Designer | **Christy** | User research, interaction design, IA |
| ⚙️ DevOps / SRE | **Soren** | Infrastructure, CI/CD, deploys, rollback plans |
| 🧰 Data Engineer | **Milo** | Schema design, ETL/ELT pipelines, analytics |
| 🔴 TDD Reviewer | **Tex** | Red/Green/Refactor diff review |
| 😈 Adversarial Reviewer | **Sage** | Devil's-advocate critique that stress-tests your plans |
| ✍️ Tech Writer | **Iris** | Documentation, diagrams, editorial reviews |

**Stack specialists** implement your stories in their native idioms: **Cleo** (TypeScript/React/Next.js), **Ravi** (Python/Django/FastAPI), **Hugo** (Java/Spring), **Kai** (Go), **Lena** (Angular), **Freya** (Flutter), **Talia** (Mobile / React Native / Swift / Kotlin).

**Strategy & facilitation** round out the team: **Orion** (business-model innovation), **Nova** (systematic problem-solving), **Rex** (brainstorming), **Lyra** (design thinking), **Elara** (storytelling), **Vermeer** (presentation design).

## 📚 Documentation

The complete guide — every command, agent, configuration option, and workflow — lives at:

**→ [gaiastudio-ai.github.io/gaia-framework](https://gaiastudio-ai.github.io/gaia-framework/)**

Once installed, `/gaia-help` gives you context-aware guidance based on your current project state, and `/gaia` routes you to the right command for whatever you're trying to do.

## 🤝 Contributing

Issues and pull requests are welcome. Please file bugs and feature requests on the [issue tracker](https://github.com/gaiastudio-ai/gaia-framework/issues) with clear reproduction steps.

## 📄 License

[AGPL-3.0](LICENSE) © gaiastudio.ai
