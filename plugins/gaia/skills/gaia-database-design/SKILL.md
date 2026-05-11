---
name: gaia-database-design
description: Schema design conventions, forward-only migrations, index optimization, and ORM patterns including N+1 prevention. Shared dev skill JIT-loaded by dev-story and stack dev agents.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/database-design.md` skill. Preserves the four sectioned-loading IDs (`schema-design`, `migrations`, `indexing`, `orm-patterns`) verbatim.

- ADR-041 — Native execution model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM. Prose and pattern guidance only.
- ADR-046 — Hybrid memory. Shared content skill; no sidecar loading.

> **Applicable to:** java-dev, python-dev (primary); any stack dev agent touching schema or ORM code. The legacy `applicable_agents` frontmatter field is dropped per the E28-S19 schema.

<!-- SECTION: schema-design -->
## Schema Design

### Naming Conventions
- Tables: `snake_case`, plural: `users`, `order_items`, `payment_methods`
- Columns: `snake_case`, singular: `first_name`, `created_at`, `is_active`
- Primary keys: `id` (auto-increment or UUID)
- Foreign keys: `{singular_table}_id`: `user_id`, `order_id`
- Junction tables: `{table1}_{table2}`: `user_roles`, `product_categories`
- Indexes: `idx_{table}_{columns}`: `idx_users_email`
- Constraints: `{type}_{table}_{columns}`: `uq_users_email`, `chk_orders_amount`

### Normalization
- **1NF**: No repeating groups, atomic values
- **2NF**: No partial dependencies (every non-key depends on whole key)
- **3NF**: No transitive dependencies (non-key depends only on key)
- Normalize to 3NF by default; denormalize only with measured justification

### Denormalization
When to denormalize:
- Read-heavy queries with complex joins (measure first)
- Reporting tables / materialized views
- Caching computed values that rarely change

Techniques:
- Materialized views for complex aggregations
- Computed columns for derived values
- Denormalized read models (CQRS pattern)

### Standard Columns
Every table should include:
```sql
id          BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
created_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
updated_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
```
Add `deleted_at TIMESTAMP` for soft deletes when needed.

<!-- SECTION: migrations -->
## Migrations

### Forward-Only Strategy
- Prefer forward-only migrations in production environments
- Rollback via compensating migrations rather than reversing schema changes
- Keep a `down` script for development/testing but never rely on it in production

### Versioned Migrations
- One migration per change set
- Timestamp-based ordering: `20260303120000_create_users_table`
- Each migration has `up` (apply) and `down` (rollback)

### Migration Template
```sql
-- Migration: 20260303120000_create_users_table
-- Description: Create users table with authentication fields

-- UP
CREATE TABLE users (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(100),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_users_email ON users (email);

-- DOWN
DROP TABLE IF EXISTS users;
```

### Migration Safety Rules
- Every migration MUST have a working rollback for dev/staging
- Test rollbacks in staging before production
- Data migrations need special care -- backup before running
- Never drop columns in the same release they stop being used
- Use expand-contract pattern: add new column, migrate data, remove old column

### Seed Data
- Keep seed data separate from schema migrations
- Use seed files for development/testing reference data
- Never seed production with test data
- Idempotent seeds: check existence before inserting

<!-- SECTION: indexing -->
## Indexing

### Index Types
| Type | Use Case |
|------|----------|
| B-tree (default) | Equality and range queries |
| Hash | Equality-only lookups |
| GIN | Full-text search, JSONB, arrays |
| GiST | Geometric, spatial data |
| Partial | Subset of rows matching condition |

### Query Plan Analysis
```sql
EXPLAIN ANALYZE SELECT * FROM users WHERE email = 'test@example.com';
```
- Look for `Seq Scan` on large tables -- usually needs an index
- `Index Scan` or `Index Only Scan` is the goal
- Check `actual time` vs `estimated time` for accuracy

### Composite Indexes
- Column order matters: most selective column first
- Follow the "left prefix" rule: `(a, b, c)` covers queries on `a`, `(a, b)`, and `(a, b, c)`
- Do not create single-column indexes that are prefixes of existing composites

### Index Guidelines
- Index all foreign keys
- Index columns used in WHERE, ORDER BY, GROUP BY
- Do not over-index: each index slows writes
- Monitor unused indexes and remove them
- Use partial indexes for common filtered queries: `WHERE is_active = true`

<!-- SECTION: orm-patterns -->
## ORM Patterns

### Repository Pattern
```
Repository (data access) -> Service (business logic) -> Controller (HTTP)
```
- Repositories encapsulate query logic
- Services orchestrate business rules
- Controllers handle HTTP concerns only

### N+1 Prevention
The N+1 problem: loading a list, then loading related data one-by-one.

Prevention strategies:
- **Eager loading**: Load related data in the initial query
- **Batch loading**: Collect IDs, load all related in one query
- **Join queries**: Use SQL joins for single-query loading
- **DataLoader pattern**: Batch and cache within a request

Example of N+1 (bad):
```python
users = db.query(User).all()           # 1 query
for user in users:
    orders = user.orders                # N queries
```

Fixed with eager loading:
```python
users = db.query(User).options(
    joinedload(User.orders)
).all()                                 # 1 query with JOIN
```

### ORM Best Practices
- Use query builders for complex queries instead of raw SQL
- Map database types to domain types explicitly
- Use database transactions for multi-table operations
- Log generated SQL in development to catch inefficiencies
- Avoid putting business logic in ORM models
- Prefer explicit loading strategies over global defaults

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array (per E28-S19 schema).

| Scenario | Expected |
|----------|----------|
| Table naming convention | Table names are snake_case, plural |
| Migration file creation | Migration includes up and down methods with version timestamp |
| Index optimization | Indexes cover frequently queried columns and composite patterns |
