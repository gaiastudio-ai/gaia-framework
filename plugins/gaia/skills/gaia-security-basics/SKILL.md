---
name: gaia-security-basics
description: OWASP Top 10 prevention patterns, input validation at system boundaries, environment-based secrets management, and CORS/CSRF configuration. Shared dev skill JIT-loaded by dev-story, security-review, and stack dev agents.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/security-basics.md` skill. Preserves the four sectioned-loading IDs (`owasp-top-10`, `input-validation`, `secrets-management`, `cors-csrf`) verbatim.

- Native execution model via Claude Code Skills + Subagents + Plugins + Hooks.
- Scripts-over-LLM. Prose and pattern guidance only.
- Hybrid memory. Shared content skill; no sidecar loading.

> **Applicable to:** all 9 stack dev agents (typescript, angular, flutter, java, python, mobile, go, bash, embedded) and the security-review skill. The legacy `applicable_agents` frontmatter field is dropped per the current schema.

<!-- SECTION: owasp-top-10 -->
## OWASP Top 10 Prevention

### A01: Broken Access Control
- Deny by default; require explicit grants for each resource
- Enforce ownership checks: users can only access their own data
- Disable directory listing on web servers
- Log and alert on access control failures

```typescript
// Always check resource ownership
async function getOrder(userId: string, orderId: string) {
  const order = await orderRepo.findById(orderId);
  if (!order) throw new NotFoundError('Order not found');
  if (order.userId !== userId) throw new ForbiddenError('Access denied');
  return order;
}
```

### A02: Cryptographic Failures
- Use TLS 1.2+ for all data in transit
- Hash passwords with bcrypt (cost factor >= 12) or argon2
- Never roll your own cryptography
- Encrypt sensitive data at rest (PII, payment info)

### A03: Injection
- Use parameterized queries for all database operations
- Never concatenate user input into queries, commands, or templates
```typescript
// BAD: SQL injection risk
const query = `SELECT * FROM users WHERE id = '${userId}'`;

// GOOD: Parameterized query
const query = 'SELECT * FROM users WHERE id = $1';
const result = await db.query(query, [userId]);
```

### A05: Security Misconfiguration
- Remove default accounts and passwords
- Disable stack traces and debug info in production
- Keep dependencies updated; automate vulnerability scanning
- Use security headers: `Strict-Transport-Security`, `X-Content-Type-Options`

### A07: Identification and Authentication Failures
- Enforce strong passwords (min 12 chars, check against breached lists)
- Implement rate limiting on login endpoints
- Use multi-factor authentication for admin accounts
- Invalidate sessions on password change

### A09: Security Logging and Monitoring
- Log authentication events (success and failure)
- Log authorization failures and input validation rejections
- Never log sensitive data (passwords, tokens, PII)
- Set up alerts for anomalous patterns (brute force, unusual access)

<!-- SECTION: input-validation -->
## Input Validation

### Validate at Boundaries
Apply validation at every entry point into the system:
- HTTP request bodies, query params, path params, headers
- Message queue payloads
- File uploads
- Third-party API responses

### Validation Strategy
```typescript
// Use a schema validation library (e.g., Zod, Joi, class-validator)
import { z } from 'zod';

const CreateUserSchema = z.object({
  email: z.string().email().max(255),
  name: z.string().min(2).max(100).trim(),
  age: z.number().int().min(13).max(150).optional(),
});

// Validate at the controller boundary
function createUser(req: Request, res: Response) {
  const result = CreateUserSchema.safeParse(req.body);
  if (!result.success) {
    return res.status(422).json({
      type: 'validation-error',
      errors: result.error.issues,
    });
  }
  // result.data is typed and safe to use
  return userService.create(result.data);
}
```

### Validation Rules
- **Allowlist over denylist**: Define what is accepted, not what is rejected
- **Type coercion**: Parse strings to expected types explicitly
- **Length limits**: Enforce max length on all string inputs
- **Range checks**: Enforce min/max on numeric inputs
- **Format validation**: Use regex or parsers for emails, URLs, dates
- **Sanitization**: Strip HTML/script tags from text that will be rendered

### File Upload Validation
- Validate MIME type against an allowlist
- Enforce maximum file size
- Generate new filenames; never use user-provided names
- Scan uploaded files for malware if possible
- Store uploads outside the web root

<!-- SECTION: secrets-management -->
## Secrets Management

### Environment-Based Secrets
- Load secrets from environment variables, never from source code
- Use `.env` files for local development only (git-ignored)
- Use a secrets manager in production (AWS Secrets Manager, Vault, GCP Secret Manager)

### .env File Pattern
```bash
# .env.example (committed -- shows structure, no real values)
DATABASE_URL=postgres://user:password@localhost:5432/dbname
JWT_SECRET=replace-with-a-real-secret
STRIPE_API_KEY=sk_test_replace_me
```

```bash
# .env (git-ignored -- contains real local values)
DATABASE_URL=postgres://dev:devpass@localhost:5432/myapp_dev
JWT_SECRET=local-dev-secret-not-for-production
STRIPE_API_KEY=sk_test_abc123
```

### Configuration Loading
```typescript
// Validate required env vars at startup, fail fast if missing
function loadConfig() {
  const required = ['DATABASE_URL', 'JWT_SECRET'];
  const missing = required.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    throw new Error(`Missing required env vars: ${missing.join(', ')}`);
  }
  return {
    databaseUrl: process.env.DATABASE_URL,
    jwtSecret: process.env.JWT_SECRET,
    port: parseInt(process.env.PORT || '3000', 10),
  };
}
```

### Secrets Hygiene
- Rotate secrets on a regular schedule (at minimum annually)
- Use separate secrets per environment (dev, staging, production)
- Never log secrets, even at debug level
- If a secret is leaked, rotate it immediately
- Use short-lived tokens (JWTs, OAuth tokens) where possible
- Use pre-commit hooks (`git-secrets`, `gitleaks`) to prevent accidental commits

<!-- SECTION: cors-csrf -->
## CORS and CSRF

### CORS Configuration
Cross-Origin Resource Sharing controls which domains can call your API.

```typescript
// Express CORS configuration
import cors from 'cors';

app.use(cors({
  origin: ['https://app.example.com', 'https://admin.example.com'],
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true,
  maxAge: 86400, // cache preflight for 24 hours
}));
```

### CORS Rules
- Never use `origin: '*'` with `credentials: true`
- Allowlist specific origins; do not reflect the `Origin` header blindly
- Restrict methods and headers to what the application actually uses
- Use `maxAge` to reduce preflight requests

### CSRF Protection
Cross-Site Request Forgery tricks a user's browser into making unwanted requests.

**Token-based CSRF prevention**:
```typescript
// Server: generate token and set as cookie
import csrf from 'csurf';
app.use(csrf({ cookie: true }));

// Client: include token in request header
fetch('/api/transfer', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-CSRF-Token': getCsrfToken(), // read from cookie or meta tag
  },
  body: JSON.stringify({ amount: 100, to: 'account-456' }),
});
```

### CSRF Prevention Strategies
| Strategy | How It Works |
|----------|--------------|
| Synchronizer token | Server generates token, client sends it back with each state-changing request |
| Double-submit cookie | Token in cookie + token in header; server compares both |
| SameSite cookies | Set `SameSite=Strict` or `Lax` on session cookies |
| Custom request header | Require a custom header (e.g., `X-Requested-With`) that browsers block cross-origin |

### Security Headers Checklist
```
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: default-src 'self'
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
```
- Apply these headers globally via middleware or reverse proxy
- Test header configuration with securityheaders.com

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array.

| Scenario | Expected |
|----------|----------|
| Input validation implementation | All user inputs are validated at the boundary with allowlists and type checks |
| Secrets management setup | Secrets are loaded from environment variables or vault, never hardcoded |
| CORS configuration | CORS allows only specific origins, methods, and headers for the application |
