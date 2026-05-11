---
name: gaia-testing-patterns
description: Red-Green-Refactor TDD cycle, Arrange-Act-Assert unit tests, integration test isolation, and test doubles (stub, mock, spy, fake). Shared dev skill JIT-loaded by dev-story and stack dev agents.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/testing-patterns.md` skill. Preserves the four sectioned-loading IDs (`tdd-cycle`, `unit-testing`, `integration-testing`, `test-doubles`) verbatim. This skill is the primary source of the TDD cycle that `gaia-dev-story` JIT-loads during Steps 6-8.

- ADR-041 — Native execution model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM. Prose and pattern guidance only.
- ADR-046 — Hybrid memory. Shared content skill; no sidecar loading.

> **Applicable to:** all 6 stack dev agents (typescript, angular, flutter, java, python, mobile). The legacy `applicable_agents` frontmatter field is dropped per the E28-S19 schema.

<!-- SECTION: tdd-cycle -->
## TDD Cycle

### Red-Green-Refactor
1. **Red**: Write a failing test that defines the desired behavior
2. **Green**: Write the minimum code to make the test pass
3. **Refactor**: Improve the code while keeping all tests green

### TDD Rules
- Never write production code without a failing test
- Write only enough test to fail (compilation failures count)
- Write only enough production code to pass the failing test
- Refactor only when all tests are green

### Test Pyramid
```
        /  E2E  \          Few, slow, expensive
       /----------\
      / Integration \      Moderate count
     /----------------\
    /    Unit Tests     \  Many, fast, cheap
```

- **Unit tests** (70%): Test individual functions and classes in isolation
- **Integration tests** (20%): Test component interactions and external boundaries
- **E2E tests** (10%): Test critical user journeys through the full stack

### When to Use TDD
- New features with clear acceptance criteria
- Bug fixes (write test that reproduces bug first)
- Complex business logic with edge cases
- API contracts (test expected inputs/outputs)

### When TDD May Not Fit
- Exploratory prototyping (write tests after design stabilizes)
- Pure UI layout work (use visual regression tests instead)
- Generated code (test the generator, not every output)

<!-- SECTION: unit-testing -->
## Unit Testing

### Arrange-Act-Assert (AAA)
```typescript
describe('OrderService', () => {
  it('should apply 10% discount for orders over $100', () => {
    // Arrange
    const order = new Order([
      new LineItem('Widget', 60.00),
      new LineItem('Gadget', 50.00),
    ]);
    const service = new OrderService();

    // Act
    const total = service.calculateTotal(order);

    // Assert
    expect(total).toBe(99.00); // 110 - 10% = 99
  });
});
```

### Naming Conventions
Use descriptive names that document behavior:
```
should_[expected behavior]_when_[condition]
```
Examples:
- `should_reject_order_when_cart_is_empty`
- `should_apply_discount_when_total_exceeds_threshold`
- `should_send_notification_when_payment_succeeds`

### Test Organization
- One test file per source file: `user.service.ts` -> `user.service.spec.ts`
- Group related tests with `describe` blocks
- Keep each test focused on a single behavior
- Avoid logic in tests (no if/else, loops, or try/catch)

### Edge Cases to Cover
- Empty inputs (null, undefined, empty string, empty array)
- Boundary values (min, max, zero, negative)
- Error conditions (invalid input, network failure, timeout)
- Concurrent access (if applicable)

### Test Independence
- Tests must not depend on execution order
- Each test sets up its own state and tears it down
- No shared mutable state between tests
- Use `beforeEach` for common setup, not `beforeAll` with mutations

<!-- SECTION: integration-testing -->
## Integration Testing

### What to Integration Test
- Database queries and transactions
- HTTP API endpoints (request/response cycle)
- Message queue producers and consumers
- External service integrations (with contract tests)
- Authentication and authorization flows

### Database Integration Tests
```typescript
describe('UserRepository', () => {
  let db: TestDatabase;

  beforeAll(async () => {
    db = await TestDatabase.create(); // isolated test DB
  });

  afterAll(async () => {
    await db.destroy();
  });

  beforeEach(async () => {
    await db.truncateAll(); // clean state per test
  });

  it('should find user by email', async () => {
    await db.seed('users', { email: 'test@example.com', name: 'Test' });
    const repo = new UserRepository(db.connection);

    const user = await repo.findByEmail('test@example.com');

    expect(user).toBeDefined();
    expect(user.name).toBe('Test');
  });
});
```

### API Integration Tests
```typescript
describe('POST /api/users', () => {
  it('should create a user and return 201', async () => {
    const response = await request(app)
      .post('/api/users')
      .send({ email: 'new@example.com', name: 'New User' })
      .expect(201);

    expect(response.body.data.email).toBe('new@example.com');
  });

  it('should return 422 for invalid email', async () => {
    const response = await request(app)
      .post('/api/users')
      .send({ email: 'not-an-email', name: 'Bad User' })
      .expect(422);

    expect(response.body.errors[0].field).toBe('email');
  });
});
```

### Isolation Strategies
- Use test containers (Testcontainers) for databases, Redis, etc.
- Truncate tables between tests, not between suites
- Use separate database schemas or databases per test suite
- Never run integration tests against shared environments

<!-- SECTION: test-doubles -->
## Test Doubles

### Types of Test Doubles
| Type | Purpose | Verifies |
|------|---------|----------|
| **Stub** | Returns pre-configured responses | State (return values) |
| **Mock** | Records and verifies interactions | Behavior (method calls) |
| **Spy** | Wraps real object, records calls | Both state and behavior |
| **Fake** | Simplified working implementation | State via simplified logic |
| **Dummy** | Fills a parameter, never actually used | Nothing |

### When to Use Each
- **Stub**: Replace a dependency to control inputs to the system under test
- **Mock**: Verify the system under test calls a dependency correctly
- **Spy**: Keep real behavior but verify interactions happened
- **Fake**: Replace complex infrastructure (in-memory DB, fake HTTP server)
- **Dummy**: Satisfy a function signature for a parameter you do not care about

### Stub Example
```typescript
const priceService = {
  getPrice: jest.fn().mockReturnValue(25.00),
};
const calculator = new OrderCalculator(priceService);
const total = calculator.calculate(['item-1', 'item-2']);
expect(total).toBe(50.00);
```

### Mock Example
```typescript
const emailService = { send: jest.fn() };
const registration = new RegistrationService(emailService);

await registration.register({ email: 'user@example.com' });

expect(emailService.send).toHaveBeenCalledWith(
  expect.objectContaining({ to: 'user@example.com', template: 'welcome' })
);
```

### Fake Example
```typescript
class FakeUserRepository implements UserRepository {
  private users: Map<string, User> = new Map();

  async save(user: User): Promise<void> {
    this.users.set(user.id, user);
  }

  async findById(id: string): Promise<User | null> {
    return this.users.get(id) ?? null;
  }
}
```

### Test Double Guidelines
- Prefer stubs over mocks -- test behavior outcomes, not implementation
- Do not mock what you do not own (wrap third-party libs in adapters)
- If you need more than 3 mocks in a test, the class has too many dependencies
- Fakes are the best choice for repositories and external services
- Reset all mocks/stubs in `beforeEach` to prevent test pollution

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array (per E28-S19 schema).

| Scenario | Expected |
|----------|----------|
| Unit test structure | Test follows Arrange-Act-Assert pattern with descriptive naming |
| Integration test isolation | Test uses dedicated database/container and cleans up after execution |
| Test double selection | Appropriate double type chosen (mock for behavior, stub for state, fake for complex deps) |
