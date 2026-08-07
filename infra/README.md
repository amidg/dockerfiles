# Infra Services

Local infrastructure containers for Hermes Agent research capabilities.
Run from this directory with `podman-compose`.

## Services

### Firecrawl (web scraping / crawling)

| Item | Detail |
|------|--------|
| Image | `ghcr.io/firecrawl/firecrawl:latest` |
| Host port | **3002** (API) |
| Internal network | `firecrawl` (self-contained) |
| Health check | None on the API; depends on RabbitMQ health |
| Data dirs | Named volumes: `firecrawl_redis`, `firecrawl_postgres` |
| Env file | `firecrawl.env` (copy of ai/firecrawl.env) |

**Composition** (5 containers):

| Container | Image | Port | Role |
|-----------|-------|------|------|
| firecrawl_redis | redis:7-alpine | 6379 (internal) | Cache & rate limiting |
| firecrawl_playwright | ghcr.io/firecrawl/playwright-service:latest | 3000 (internal) | Headless browser scraping |
| firecrawl_rabbitmq | rabbitmq:3-management-alpine | 5672 internal, 15672 mgmt | Job queue |
| firecrawl_postgres | postgres:16-alpine | 5432 (internal) | Job persistence |
| firecrawl_api | ghcr.io/firecrawl/firecrawl:latest | 3002 (host) | Main API — scrape, search, extract |

### SearXNG (private search aggregator)

| Item | Detail |
|------|--------|
| Image | `searxng/searxng:latest` |
| Host port | **8888** |
| Config | `searxng-config/settings.yml` |
| No external deps | Single container, no Redis/Postgres needed |

## Quick Start

```bash
cd /var/home/dmitrii/Projects/dockerfiles/infra

# Firecrawl
podman-compose -f firecrawl.yaml up -d

# SearXNG
podman-compose -f searxng.yaml up -d
```

## Verification

```bash
# Firecrawl API
curl -s http://localhost:3002/ | head -5

# SearXNG
curl -s http://localhost:8888/ | head -5
```

## Hermes Integration

Firecrawl and SearXNG are used by Hermes for online research. Both are supported
natively by Hermes — no plugin needed.

### Service endpoints

| Service | URL | Purpose |
|---------|-----|---------|
| Firecrawl API | `http://localhost:3002` | Web scraping, structured extraction, search |
| SearXNG | `http://localhost:8888` | Private search aggregation |

### Connecting Firecrawl to SearXNG

Uncomment and set in `firecrawl.env`:

```
SEARXNG_ENDPOINT=http://searxng:8080
```

This lets Firecrawl's `/search` API use SearXNG as its search backend instead of
Google. The internal URL points at the SearXNG container on port 8080 (the container
port, not the host port 8888).

### Hermes config mapping

Hermes supports both services natively. Configure them in two places:

**1. `.env` — env vars for URLs and keys:**

| Env var | Value | Purpose |
|---------|-------|---------|
| `SEARXNG_URL` | `http://localhost:8888` | SearXNG instance URL |
| `FIRECRAWL_API_URL` | `http://localhost:3002` | Self-hosted Firecrawl URL |
| `FIRECRAWL_API_KEY` | (empty or any string) | Self-hosted Firecrawl auth key |

**2. `config.yaml` — web backend selection:**

| Config key | Value | Purpose |
|------------|-------|---------|
| `web.search_backend` | `searxng` or `firecrawl` | Which backend to use for `web_search` |
| `web.extract_backend` | `firecrawl` | Which backend to use for `web_extract` |
| `web.backend` | (shared fallback) | Applies to both search and extract when set |

### Applying the mapping

To use Firecrawl for both search and extract:

```bash
# Add to ~/.hermes/.env:
echo 'SEARXNG_URL=http://localhost:8888' >> ~/.hermes/.env
echo 'FIRECRAWL_API_URL=http://localhost:3002' >> ~/.hermes/.env
echo 'FIRECRAWL_API_KEY=' >> ~/.hermes/.env

# Set web backends:
hermes config set web.search_backend firecrawl
hermes config set web.extract_backend firecrawl
```

To use SearXNG for search only (keep default extract):

```bash
hermes config set web.search_backend searxng
```

After any config change, restart Hermes or use `/reset` to reload.

## Stopping & Cleanup

```bash
# Stop all
podman-compose -f firecrawl.yaml down
podman-compose -f searxng.yaml down

# Stop and remove volumes (WARNING: deletes all data)
podman-compose -f firecrawl.yaml down -v
podman-compose -f searxng.yaml down -v
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Port 3002 already in use | Check `ai/firecrawl.yaml` — may still be running |
| Port 8888 already in use | Another service may be using it |
| Firecrawl API not responding | Check `podman-compose -f firecrawl.yaml logs firecrawl_api` |
| RabbitMQ not healthy | `podman exec firecrawl_rabbitmq rabbitmq-diagnostics check_running` |
| SearXNG returns 0 results | Check `searxng-config/settings.yml` engines section; SearXNG needs time to initialize |
