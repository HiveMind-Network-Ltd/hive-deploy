# hive-deploy — Functionality

## Core Features

### Webhook Server (`hive_deploy.py`)
- HTTP server listening on `127.0.0.1:5678`
- Supports **systemd socket activation** — process only runs when a request arrives
- Falls back to standalone mode when run directly (no systemd)
- All activity logged to `deploy.log` with timestamps

### Endpoints
- `GET /` or `GET /deploy/*` — health check, returns `hive-deploy ok`
- `POST /deploy/{project-slug}` — triggers a deploy for the named project

### Authentication
- Each project has its own secret string in `config.json`
- Incoming requests must provide `X-Hive-Secret: <secret>` header
- Mismatched or missing secrets return `403 Forbidden` and log a warning
- Invalid project slugs return `404 Not found`

### Deploy Execution
- Deploy commands run in a **background thread** so the HTTP response (202) is returned immediately
- Commands run sequentially via `bash --login -c` to ensure nvm/PATH is available
- If any command exits with a non-zero code, the sequence stops and the failure is logged
- stdout and stderr from each command are captured and written to `deploy.log`

### Configuration (`config.json`)
- JSON format, gitignored (never committed)
- `config.example.json` provided as template
- Per-project fields:
  - `secret` — authentication token
  - `repo_path` — absolute path to the source repo on the server
  - `commands` — ordered list of shell commands to run on deploy

## Infrastructure

### Systemd Socket Activation
- `setup/hive-deploy.socket` — kernel-level socket listener, always active, near-zero resources
- `setup/hive-deploy.service` — spawned on incoming request, exits when done
- Socket persists between service restarts — no dropped connections

### Nginx Integration
- `setup/nginx-location.conf` — location block proxying `/deploy/` to `127.0.0.1:5678`
- Deploy endpoint exposed via existing HTTPS (port 443) — no new ports required

### Installer
- `setup/install.sh` — installs and enables systemd units, copies example config
