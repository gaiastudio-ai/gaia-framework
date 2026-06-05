---
name: gaia-api-design
description: REST conventions, GraphQL schema patterns, OpenAPI specification, API versioning, and RFC 7807 error standards. Shared dev skill JIT-loaded by dev-story and stack dev agents.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/api-design.md` skill. Preserves the five sectioned-loading IDs (`rest-conventions`, `graphql`, `openapi`, `versioning`, `error-standards`) verbatim.

- Native execution model via Claude Code Skills + Subagents + Plugins + Hooks.
- Scripts-over-LLM. This skill is prose and pattern guidance only; no inline scripts.
- Hybrid memory. This is a shared content skill and does NOT load agent memory sidecars.

> **Applicable to:** all 6 stack dev agents (typescript, angular, flutter, java, python, mobile). The legacy `applicable_agents` frontmatter field is dropped under the current schema.

<!-- SECTION: rest-conventions -->
## REST Conventions

### Resource Naming
- Use plural nouns: `/users`, `/orders`, `/products`
- Use lowercase with hyphens: `/order-items`, `/user-profiles`
- Nest for relationships: `/users/{id}/orders`
- Max 3 levels of nesting; beyond that, use query params or separate resources
- No verbs in URLs (use HTTP methods instead)

### HTTP Methods
| Method | Use | Idempotent | Safe |
|--------|-----|------------|------|
| GET | Retrieve resource(s) | Yes | Yes |
| POST | Create resource | No | No |
| PUT | Full update/replace | Yes | No |
| PATCH | Partial update | No | No |
| DELETE | Remove resource | Yes | No |

### Status Codes
| Code | Meaning | Use When |
|------|---------|----------|
| 200 | OK | Successful GET, PUT, PATCH |
| 201 | Created | Successful POST creating resource |
| 204 | No Content | Successful DELETE |
| 400 | Bad Request | Invalid input/validation failure |
| 401 | Unauthorized | Missing or invalid authentication |
| 403 | Forbidden | Authenticated but not authorized |
| 404 | Not Found | Resource does not exist |
| 409 | Conflict | Duplicate resource or state conflict |
| 422 | Unprocessable | Valid syntax but semantic error |
| 429 | Too Many Requests | Rate limit exceeded |
| 500 | Server Error | Unexpected server failure |

### Pagination
```json
{
  "data": [...],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 150,
    "total_pages": 8
  }
}
```
- Use `?page=1&per_page=20` for offset pagination
- Use `?cursor=abc123&limit=20` for cursor pagination (preferred for large datasets)
- Always include pagination metadata in response

<!-- SECTION: graphql -->
## GraphQL Design

### Schema Design
- Use descriptive type names: `User`, `OrderItem`, `PaymentMethod`
- Prefer input types for mutations: `input CreateUserInput { ... }`
- Use enums for fixed value sets: `enum OrderStatus { PENDING, SHIPPED, DELIVERED }`
- Add descriptions to all types and fields

### Query and Mutation Patterns
```graphql
type Query {
  user(id: ID!): User
  users(filter: UserFilter, pagination: PaginationInput): UserConnection!
}

type Mutation {
  createUser(input: CreateUserInput!): CreateUserPayload!
  updateUser(id: ID!, input: UpdateUserInput!): UpdateUserPayload!
}

type CreateUserPayload {
  user: User
  errors: [UserError!]!
}
```
- Return payload types from mutations (not raw entities)
- Include an `errors` field in payloads for domain-level errors
- Use Relay-style connections for paginated lists

### Resolvers
- Keep resolvers thin -- delegate to service layer
- Use DataLoader for batching to prevent N+1 queries
- Return typed errors, not generic messages

### Subscriptions
- Use for real-time updates only (chat, notifications, live data)
- Prefer polling for infrequently changing data
- Always implement authentication on subscription connections
- Handle connection lifecycle (connect, disconnect, reconnect)

<!-- SECTION: openapi -->
## OpenAPI Specification

### Spec Structure
```yaml
openapi: 3.0.3
info:
  title: API Name
  version: 1.0.0
  description: Brief API description
paths:
  /resources:
    get:
      summary: List resources
      operationId: listResources
      tags: [resources]
      parameters:
        - name: page
          in: query
          schema:
            type: integer
            default: 1
      responses:
        '200':
          description: Successful response
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/ResourceList'
        '401':
          $ref: '#/components/responses/Unauthorized'
components:
  schemas: {}
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
```

### Best Practices
- Every endpoint needs `operationId`, `summary`, `tags`
- Use `$ref` for shared schemas -- never inline complex types
- Document all possible response codes per endpoint
- Include request/response examples for non-trivial endpoints

### Code Generation
- Generate server stubs from spec (spec-first development)
- Generate client SDKs for frontend consumers
- Validate requests/responses against spec in tests
- Keep spec in sync with implementation via CI checks

<!-- SECTION: versioning -->
## API Versioning

### URL Versioning (Recommended)
```
/api/v1/users
/api/v2/users
```
- Simple, explicit, visible in logs and documentation
- Easy to route at load balancer level

### Header Versioning (Alternative)
```
Accept: application/vnd.api+json;version=2
```
- Cleaner URLs but harder to test in browser
- Requires custom middleware to parse

### Breaking vs Non-Breaking Changes
A change is **breaking** if it:
- Removes or renames a field
- Changes a field's type
- Adds a required field to a request body
- Changes authentication mechanism
- Changes error response format

A change is **non-breaking** if it:
- Adds an optional field to request or response
- Adds a new endpoint
- Adds a new optional query parameter

### Deprecation Policy
1. Announce deprecation with timeline (minimum 6 months)
2. Add `Sunset` header: `Sunset: Sat, 01 Jan 2027 00:00:00 GMT`
3. Add `Deprecation` header: `Deprecation: true`
4. Log usage of deprecated endpoints for migration tracking
5. Remove only after sunset date passes

<!-- SECTION: error-standards -->
## Error Standards (RFC 7807)

### Problem Details Structure
```json
{
  "type": "https://api.example.com/errors/validation-error",
  "title": "Validation Error",
  "status": 422,
  "detail": "The 'email' field must be a valid email address.",
  "instance": "/users/registration",
  "trace_id": "req-abc-123-def",
  "errors": [
    {
      "field": "email",
      "message": "Must be a valid email address",
      "code": "INVALID_FORMAT"
    }
  ]
}
```

### Error Codes
- Use machine-readable error codes: `INVALID_FORMAT`, `NOT_FOUND`, `RATE_LIMITED`
- Document all error codes in API reference
- Keep codes stable across API versions
- Group by category: `AUTH_*`, `VALIDATION_*`, `RESOURCE_*`

### Error Handling Rules
- Never expose stack traces in production
- Log full error details server-side with correlation ID
- Return consistent error format across all endpoints
- Include `trace_id` for debugging and support requests
- Localize `detail` field using `Accept-Language` header when needed
- Error codes remain stable across locales

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array.

| Scenario | Expected |
|----------|----------|
| REST endpoint naming | Resource names are plural nouns, lowercase, hyphenated |
| Error response format | Response follows RFC 7807 problem details structure |
| API versioning | Version strategy is documented and consistently applied |
