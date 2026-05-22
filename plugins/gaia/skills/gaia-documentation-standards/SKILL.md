---
name: gaia-documentation-standards
description: README structure, ADR (Architecture Decision Record) format, inline code comments (JSDoc / Python docstrings), and API documentation conventions. Shared dev and editorial skill JIT-loaded by dev-story, stack dev agents, and documentation workflows.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/documentation-standards.md` skill. Preserves the four sectioned-loading IDs (`readme-template`, `adr-format`, `inline-comments`, `api-docs`) verbatim.

- ADR-041 — Native execution model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM. Prose and pattern guidance only.
- ADR-046 — Hybrid memory. Shared content skill; no sidecar loading.

> **Applicable to:** all 6 stack dev agents (typescript, angular, flutter, java, python, mobile), the tech-writer, analyst, and pm agents. The legacy `applicable_agents` frontmatter field is dropped per the E28-S19 schema.

<!-- SECTION: readme-template -->
## README Template

### Standard Structure
Every project README should include these sections:

```markdown
# Project Name

Brief one-line description of what this project does.

## Overview

2-3 paragraphs explaining the project's purpose, who it's for,
and the problem it solves.

## Getting Started

### Prerequisites
- Node.js >= 20
- PostgreSQL >= 16
- Docker (optional)

### Installation
1. Clone the repository
2. Install dependencies: `npm install`
3. Copy environment file: `cp .env.example .env`
4. Run migrations: `npm run db:migrate`
5. Start development server: `npm run dev`

### Environment Variables
| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| DATABASE_URL | PostgreSQL connection string | Yes | - |
| PORT | Server port | No | 3000 |
| LOG_LEVEL | Logging verbosity | No | info |

## Usage

Show common usage examples with code snippets.

## Architecture

Brief description of the system architecture, with a link
to detailed ADRs and diagrams if available.

## Testing

How to run the test suite:
- `npm test` -- run all tests
- `npm run test:unit` -- unit tests only
- `npm run test:e2e` -- end-to-end tests

## Contributing

Link to CONTRIBUTING.md or inline contribution guidelines.

## License

Specify the project license.
```

### README Guidelines
- Keep the README under 300 lines; link to detailed docs for depth
- Update the README when setup steps or prerequisites change
- Include a "Quick Start" path that gets developers running in under 5 minutes
- Add badges for CI status, test coverage, and version only if meaningful

<!-- SECTION: adr-format -->
## Architecture Decision Records

### What Is an ADR
An ADR captures a significant architectural decision along with its context and consequences. ADRs form a decision log that helps future team members understand why the system is built the way it is.

### ADR Template
```markdown
# ADR-{NNN}: {Title of Decision}

**Status**: Proposed | Accepted | Deprecated | Superseded by ADR-{NNN}
**Date**: YYYY-MM-DD
**Deciders**: List of people involved

## Context

What is the issue or problem that motivates this decision?
What constraints or requirements apply?

## Decision

What is the change that we are proposing or have agreed to?
State the decision clearly and concisely.

## Consequences

### Positive
- Benefit one
- Benefit two

### Negative
- Trade-off one
- Trade-off two

### Neutral
- Side-effect that is neither good nor bad

## Alternatives Considered

### Alternative A: {Name}
- Description of the alternative
- Why it was rejected

### Alternative B: {Name}
- Description of the alternative
- Why it was rejected
```

### ADR Conventions
- Number ADRs sequentially: `ADR-001`, `ADR-002`, etc.
- Store in `docs/adr/` or `.gaia/artifacts/planning-artifacts/adr/`
- Never delete ADRs; mark as `Deprecated` or `Superseded`
- Write ADRs before or during implementation, not after
- One decision per ADR; split compound decisions into separate records

### When to Write an ADR
- Choosing a framework, library, or language
- Changing the database or data storage approach
- Defining API communication patterns
- Establishing authentication/authorization strategy
- Making infrastructure or deployment decisions
- Any decision that would surprise a new team member

<!-- SECTION: inline-comments -->
## Inline Code Comments

### JSDoc / TSDoc (TypeScript/JavaScript)
```typescript
/**
 * Calculates the total price for an order including applicable discounts.
 *
 * @param items - Line items in the order
 * @param discountCode - Optional promotional discount code
 * @returns The final price after discounts, rounded to 2 decimal places
 * @throws {InvalidDiscountError} If the discount code is expired or invalid
 *
 * @example
 * const total = calculateTotal(items, 'SAVE10');
 * // returns 90.00 for a $100 order with 10% discount
 */
function calculateTotal(items: LineItem[], discountCode?: string): number {
  // ...
}
```

### Python Docstrings
```python
def calculate_total(items: list[LineItem], discount_code: str | None = None) -> Decimal:
    """Calculate the total price for an order including applicable discounts.

    Args:
        items: Line items in the order.
        discount_code: Optional promotional discount code.

    Returns:
        The final price after discounts, rounded to 2 decimal places.

    Raises:
        InvalidDiscountError: If the discount code is expired or invalid.

    Example:
        >>> total = calculate_total(items, 'SAVE10')
        >>> total
        Decimal('90.00')
    """
```

### Comment Guidelines
- Document **why**, not **what** (the code shows what)
- Every public function, class, and module needs a docstring
- Skip docstrings on trivial getters, setters, and one-line functions
- Use `TODO(name):` for planned work and `FIXME(name):` for known issues
- Never leave orphaned TODO comments without an owner
- Remove commented-out code; use version control for history

<!-- SECTION: api-docs -->
## API Documentation

### What to Document
- Every public endpoint with URL, method, and description
- Request parameters (path, query, headers, body) with types and constraints
- Response structure with example payloads for success and error cases
- Authentication requirements per endpoint
- Rate limits and quotas

### API Documentation Tools
| Tool | Best For |
|------|----------|
| OpenAPI / Swagger | REST APIs with auto-generated docs |
| GraphQL Playground | GraphQL APIs with schema introspection |
| Redoc | Beautiful static docs from OpenAPI spec |
| Postman Collections | Interactive request examples |

### Endpoint Documentation Example
```markdown
## Create User

`POST /api/v1/users`

Creates a new user account.

**Authentication**: Bearer token (admin role required)

**Request Body**:
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| email | string | Yes | Valid email address |
| name | string | Yes | Display name (2-100 chars) |
| role | string | No | User role (default: "member") |

**Response 201**:
{
  "data": {
    "id": "usr_abc123",
    "email": "user@example.com",
    "name": "Jane Doe",
    "role": "member",
    "created_at": "2026-03-03T12:00:00Z"
  }
}

**Response 422**:
{
  "type": "https://api.example.com/errors/validation-error",
  "title": "Validation Error",
  "status": 422,
  "errors": [{ "field": "email", "code": "INVALID_FORMAT" }]
}
```

### Documentation Maintenance
- Generate docs from code annotations when possible (keeps docs in sync)
- Include a "last updated" date on manually written docs
- Review API docs as part of the PR review process
- Test documented examples in CI to prevent drift

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array (per E28-S19 schema).

| Scenario | Expected |
|----------|----------|
| README creation for new project | README includes all template sections with project-specific content |
| Architecture Decision Record | ADR follows status/context/decision/consequences format with unique ID |
| Inline code documentation | Public APIs have docstrings with parameter descriptions and return types |
