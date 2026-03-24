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
- Optional top-level `notifications` block for Rocket.Chat (see below)
- Per-project fields:
  - `secret` — authentication token
  - `repo_path` — absolute path / working directory on the server
  - `commands` — ordered list of shell commands to run on deploy (git, docker, npm, etc.)

### Rocket.Chat Notifications
- Optional — only active when `notifications` block is present in `config.json`
- Uses Rocket.Chat REST API (`/api/v1/chat.postMessage`) with personal access token auth
- Required config fields: `rc_url`, `rc_token`, `rc_user_id`, `rc_channel`
- Sends three message types via rich attachments:
  - 🚀 **Deploy Started** — project slug, server hostname, timestamp
  - ✅ **Deploy Complete** — steps completed, completion timestamp (green)
  - ❌ **Deploy FAILED** — steps completed before failure, failed command, last 10 lines of output (red)
- Notification failures are logged as warnings and do not affect the deploy

## Infrastructure

### Systemd Socket Activation
- `setup/hive-deploy.socket` — kernel-level socket listener, always active, near-zero resources
- `setup/hive-deploy.service` — spawned on incoming request, exits when done
- Socket persists between service restarts — no dropped connections
- Default binding: `127.0.0.1:5678` (loopback only)
- Changed to `0.0.0.0:5678` automatically by bootstrap when Traefik is detected

### Web Server Integration
- **Nginx** — `setup/nginx-location.conf`: location block proxying `/deploy/` to `127.0.0.1:5678`
- **Apache2** — `setup/apache2-proxy.conf`: ProxyPass block for `/deploy/`; requires `proxy` + `proxy_http` modules
- **Traefik** — bootstrap auto-generates `traefik/dynamic/hive-deploy.yml` routing a subdomain to `http://<bridge-ip>:5678`; Traefik hot-reloads it automatically

### Bootstrap Installer
- `setup/bootstrap.sh` — single-command interactive installer:
  - Clones or updates the repo
  - Rocket.Chat notification setup (optional)
  - Interactive project wizard: git or Docker (docker run / compose / manual)
  - Writes `config.json` via Python (correct JSON encoding)
  - Installs systemd units with correct user/path substitution
  - Checks docker group membership if Docker is installed
  - Auto-detects and configures Nginx, Apache2, or Traefik
  - Prints GitHub Actions workflow snippets with correct deploy URL
- `setup/install.sh` — minimal installer (systemd units only, manual config)
