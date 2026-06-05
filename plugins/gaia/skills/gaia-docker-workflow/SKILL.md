---
name: gaia-docker-workflow
description: Multi-stage Dockerfile patterns, Docker Compose for local development, and image security scanning with vulnerability triage. Shared dev skill JIT-loaded by dev-story and stack dev agents.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/docker-workflow.md` skill. Preserves the three sectioned-loading IDs (`multi-stage-builds`, `compose`, `security-scanning`) verbatim.

- Native execution model via Claude Code Skills + Subagents + Plugins + Hooks.
- Scripts-over-LLM. Prose only; concrete `docker` invocations belong to calling agents or skill-local scripts.
- Hybrid memory. Shared content skill; no sidecar loading.

> **Applicable to:** typescript-dev, angular-dev, java-dev, python-dev, mobile-dev. The legacy `applicable_agents` frontmatter field is dropped per the current schema.

<!-- SECTION: multi-stage-builds -->
## Multi-Stage Builds

### Why Multi-Stage
- Separate build dependencies from runtime dependencies
- Smaller final images (no compilers, build tools, source code)
- Reduced attack surface in production containers
- Faster deployments due to smaller image size

### Node.js Example
```dockerfile
# Stage 1: Build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --ignore-scripts
COPY . .
RUN npm run build

# Stage 2: Runtime
FROM node:20-alpine AS runtime
WORKDIR /app
RUN addgroup -g 1001 appgroup && adduser -u 1001 -G appgroup -s /bin/sh -D appuser
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
USER appuser
EXPOSE 3000
CMD ["node", "dist/main.js"]
```

### Java Example
```dockerfile
# Stage 1: Build
FROM eclipse-temurin:21-jdk-alpine AS builder
WORKDIR /app
COPY gradle/ gradle/
COPY gradlew build.gradle.kts settings.gradle.kts ./
RUN ./gradlew dependencies --no-daemon
COPY src/ src/
RUN ./gradlew bootJar --no-daemon

# Stage 2: Runtime
FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app
RUN addgroup -g 1001 appgroup && adduser -u 1001 -G appgroup -s /bin/sh -D appuser
COPY --from=builder /app/build/libs/*.jar app.jar
USER appuser
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### Python Example
```dockerfile
# Stage 1: Build
FROM python:3.12-slim AS builder
WORKDIR /app
RUN pip install --no-cache-dir poetry
COPY pyproject.toml poetry.lock ./
RUN poetry export -f requirements.txt -o requirements.txt --without-hashes
COPY . .

# Stage 2: Runtime
FROM python:3.12-slim AS runtime
WORKDIR /app
RUN groupadd -g 1001 appgroup && useradd -u 1001 -g appgroup -s /bin/bash appuser
COPY --from=builder /app/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY --from=builder /app/src ./src
USER appuser
EXPOSE 8000
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Best Practices
- Use specific base image tags, never `latest`
- Copy dependency files first for layer caching
- Run as non-root user in the final stage
- Use `.dockerignore` to exclude unnecessary files

<!-- SECTION: compose -->
## Docker Compose for Development

### Standard Compose File
```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      target: builder
    ports:
      - "3000:3000"
    volumes:
      - .:/app
      - /app/node_modules
    environment:
      - NODE_ENV=development
      - DATABASE_URL=postgres://user:pass@db:5432/appdb
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: pass
      POSTGRES_DB: appdb
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user -d appdb"]
      interval: 5s
      timeout: 3s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

volumes:
  pgdata:
```

### Development Patterns
- Mount source code as volume for hot reload
- Exclude `node_modules` with anonymous volume to avoid host/container conflicts
- Use `depends_on` with health checks to ensure service ordering
- Keep environment variables in `.env` file (git-ignored)
- Use `profiles` to group optional services (e.g., monitoring, mail)

### Useful Commands
```bash
docker compose up -d              # Start all services detached
docker compose logs -f app        # Follow app logs
docker compose exec app sh        # Shell into running container
docker compose down -v            # Stop and remove volumes
docker compose build --no-cache   # Force rebuild
```

<!-- SECTION: security-scanning -->
## Security Scanning

### .dockerignore
Always include a `.dockerignore` to prevent sensitive files from entering the image:
```
.git
.env
.env.*
node_modules
*.md
docker-compose*.yml
.github/
coverage/
tests/
**/*.test.*
**/*.spec.*
```

### Image Scanning
Integrate scanning into your CI pipeline:
```yaml
# GitHub Actions example
- name: Build image
  run: docker build -t myapp:${{ github.sha }} .

- name: Scan image
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: myapp:${{ github.sha }}
    severity: CRITICAL,HIGH
    exit-code: 1
```

### Vulnerability Management
| Severity | Action | Timeline |
|----------|--------|----------|
| Critical | Block deployment, fix immediately | 24 hours |
| High | Fix before next release | 1 week |
| Medium | Plan fix in next sprint | 2 weeks |
| Low | Track and batch fix | Next quarter |

### Secrets Handling
- Never use `ENV` for secrets -- they persist in image layers
- Use Docker BuildKit secrets for build-time secrets:
```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npm_token \
    NPM_TOKEN=$(cat /run/secrets/npm_token) npm ci
```
- Use runtime secrets via orchestrator (Docker Swarm, Kubernetes)
- Mount secrets as files, not environment variables when possible

### Container Hardening
- Use `USER` directive to run as non-root
- Set `read_only: true` in compose for immutable root filesystem
- Drop all capabilities and add only what is needed:
```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
```
- Scan base images regularly for CVEs
- Pin base image digests for reproducible builds in production

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array.

| Scenario | Expected |
|----------|----------|
| Multi-stage Dockerfile creation | Dockerfile uses separate build and runtime stages with minimal final image |
| Docker Compose for local development | Compose file includes app, database, and volume mounts for hot reload |
| Image security scanning | CI pipeline includes image scan step and fails on critical vulnerabilities |
