---
name: gaia-teach-testing
description: Teach testing progressively through structured sessions based on user skill level. Use when "teach me testing" or /gaia-teach-testing.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-teach-testing/scripts/setup.sh

## Mission

Teach testing progressively through structured, interactive learning sessions. Assess the user's skill level (beginner, intermediate, or expert) and deliver a tailored lesson with concepts, examples, exercises, and a summary. Use the user's project stack for code examples when possible.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/teach-me-testing` workflow (E28-S89, Cluster 11). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step. JIT (just-in-time) load discipline: knowledge fragments MUST NOT be pre-loaded at skill activation; they MUST be loaded only when Step 2 selects the corresponding topic or Step 3 references the fragment. Future fragments added under `knowledge/` inherit this discipline — never introduce a global pre-load list at the top of this SKILL.md.
- Assess the user's experience level BEFORE teaching — never assume a level.
- Load knowledge progressively — do not overwhelm with advanced topics for beginners. Progressive lessons are gated by the Step 1 skill assessment: advanced topics (property-based testing, mutation testing, contract testing) MUST NOT be presented to beginner-level users; the Step 2 topic ladder offers only the block(s) matching the assessed skill level (beginner → Beginner only; intermediate → Beginner + Intermediate; expert → all three blocks).
- Use the user's project stack for code examples when possible (detect from project files).
- Lessons must follow a consistent structure: objective, concepts, examples, exercises, summary.
- This is a single-prompt interactive session — no subagent invocation needed.

## Steps

### Step 1 — Assess Level

Ask the user about their testing experience and goals:

1. What is your current testing experience? (beginner / intermediate / expert)
2. What language or framework are you working with?
3. What specific testing topics interest you?

Determine the skill level based on their response. If the user does not specify, default to beginner.

### Step 2 — Select Topic

Present a learning path based on the assessed skill level. **Skill-level gating (gated by the Step 1 assessment):** Present ONLY the topic block(s) matching the assessed skill level from Step 1. For beginner sessions: present ONLY the Beginner topics block — do NOT present the Intermediate or Expert/advanced blocks as selectable options. For intermediate sessions: present the Beginner and Intermediate blocks. For expert sessions: present all three blocks. This rule operationalises the progressive Critical Rule above and ensures advanced topics (property-based testing, mutation testing, contract testing) are never surfaced to beginners.

**Beginner topics:**
- Test pyramid — unit, integration, E2E layers and when to use each (load knowledge fragment: `knowledge/test-pyramid.md`)
- Unit testing basics — what is a unit test, isolation, deterministic results
- Test structure — the AAA pattern (Arrange, Act, Assert)
- Assertions — common assertion patterns and matchers
- Test runners — how test frameworks discover and execute tests

**Intermediate topics:**
- Mocking and test doubles — stubs, spies, fakes, and when to use each
- Integration testing — testing component boundaries and real dependencies
- Fixtures and test data — factory functions, builders, and setup/teardown
- Coverage analysis — what coverage metrics mean and their limitations
- Test isolation — preventing test coupling and shared state

**Expert / advanced topics:**
- Property-based testing — generative testing with random inputs
- Mutation testing — measuring test effectiveness by injecting faults
- Test architecture — organizing tests at scale, test pyramids for microservices
- Contract testing — consumer-driven contracts for API boundaries
- Performance testing patterns — load testing, benchmarking, and regression detection
- Risk-based testing — prioritizing tests by business risk and failure impact

Let the user pick a specific topic or proceed with the recommended path for their level.

### Step 3 — Deliver Interactive Lesson

Walk through the selected topic using this structured lesson format:

1. **Objective** — What the user will learn in this session
2. **Concepts** — Core concepts explained with clear definitions
3. **Examples** — Code examples using the user's project stack when possible. If the stack is unknown, use TypeScript/JavaScript as the default example language.
4. **Exercises** — A hands-on exercise the user can try in their own codebase
5. **Summary** — Key takeaways and what to learn next

Use the user's project stack for code examples when possible — detect from `package.json`, `requirements.txt`, `build.gradle`, `pubspec.yaml`, `go.mod`, or other project configuration files.

### Step 4 — Practice and Feedback

Provide a hands-on exercise related to the lesson topic:

1. Describe the exercise clearly with expected inputs and outputs
2. Let the user attempt it in their codebase
3. Review their solution and provide constructive feedback
4. Suggest improvements or alternative approaches
5. Recommend the next topic to explore based on their progress

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-teach-testing/scripts/finalize.sh
