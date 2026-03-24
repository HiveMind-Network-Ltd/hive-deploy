# hive-deploy

Lightweight webhook server for triggering project deploys via HTTP POST.

Uses **systemd socket activation** — the kernel holds the socket open but no process runs between deploys. Zero idle resource usage.

## How it works

```
GitHub push
  → GitHub Actions: curl POST /deploy/{project-slug} with secret header
  → Nginx/Apache2 (port 443, already open) proxies to localhost:5678
  → systemd socket wakes hive_deploy.py
  → Secret validated
  → Deploy commands run (git pull, npm build, copy to serve dir)
  → Process exits until next deploy
```

No SSH. No open ports beyond 443. No always-running process.

---

## Install on a new server (one command)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/HiveMind-Network-Ltd/hive-deploy/main/setup/bootstrap.sh)
```

The bootstrap script will:

1. Clone this repo to `~/hive-deploy`
2. Walk you through configuring one or more deploy projects (slug, secret, repo path, commands)
3. Write `config.json`
4. Install and start the systemd socket unit
5. Auto-detect Nginx or Apache2 and insert the proxy location block into your active site config
6. Print GitHub Actions snippets for each project you configured

**Requirements:** `git`, `python3`, `sudo`, `openssl` — all present by default on Ubuntu.

---

## Manual server setup

If you prefer to configure things step by step:

### 1. Clone onto the server

```bash
cd ~
git clone https://github.com/HiveMind-Network-Ltd/hive-deploy.git
cd hive-deploy
```

### 2. Run the installer

```bash
bash setup/install.sh
```

### 3. Edit config.json

```bash
nano ~/hive-deploy/config.json
```

Add your projects, paths, and secrets (see `config.example.json`).

### 4. Add the web server proxy block

**Nginx** — add the contents of `setup/nginx-location.conf` inside your existing `server {}` block:

```bash
sudo nano /etc/nginx/sites-enabled/your-site.conf
# then:
sudo nginx -t && sudo systemctl reload nginx
```

**Apache2** — add the contents of `setup/apache2-proxy.conf` inside your `<VirtualHost>` block:

```bash
sudo a2enmod proxy proxy_http
sudo nano /etc/apache2/sites-enabled/your-site.conf
# then:
sudo apache2ctl configtest && sudo systemctl reload apache2
```

### 5. Clone your project source onto the server

```bash
cd ~
git clone https://github.com/your-org/your-project.git my_project_src
```

---

## Adding a project to a GitHub repo

In `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches:
      - master

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger deploy webhook
        run: |
          curl -s -o /dev/null -w "%{http_code}" \
            -X POST https://your-domain.com/deploy/your-project-slug \
            -H "X-Hive-Secret: ${{ secrets.DEPLOY_WEBHOOK_SECRET }}"
```

Store the project secret as `DEPLOY_WEBHOOK_SECRET` in GitHub repo Settings → Secrets.

---

## Adding a new project

1. Add an entry to `config.json` on the server
2. Clone the project source onto the server
3. Add `deploy.yml` to the project repo
4. Add the secret to the repo's GitHub secrets

---

## Logs

```bash
tail -f /home/ubuntu/hive-deploy/deploy.log
```

## Status

```bash
systemctl status hive-deploy.socket
systemctl status hive-deploy.service
```
