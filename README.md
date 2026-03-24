# hive-deploy

Lightweight webhook server for triggering project deploys via HTTP POST.

Uses **systemd socket activation** — the kernel holds the socket open but no process runs between deploys. Zero idle resource usage.

## How it works

```
GitHub push
  → GitHub Actions: curl POST /deploy/{project-slug} with secret header
  → Nginx (port 443, already open) proxies to localhost:5678
  → systemd socket wakes hive_deploy.py
  → Secret validated
  → Deploy commands run (git pull, npm build, copy to serve dir)
  → Process exits until next deploy
```

No SSH. No open ports beyond 443. No always-running process.

## Server setup

### 1. Clone onto the server

```bash
cd /home/ubuntu
git clone https://github.com/HiveMind-Network-Ltd/hive-deploy.git
cd hive-deploy
```

### 2. Run the installer

```bash
bash setup/install.sh
```

### 3. Edit config.json

```bash
nano /home/ubuntu/hive-deploy/config.json
```

Add your projects, paths, and secrets (see `config.example.json`).

### 4. Add Nginx location block

Add the contents of `setup/nginx-location.conf` inside your existing `server {}` block:

```bash
sudo nano /etc/nginx/sites-enabled/your-site.conf
```

Then reload Nginx:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

### 5. Clone your project source onto the server

```bash
cd /home/ubuntu
git clone https://github.com/HiveMind-Network-Ltd/TheHive_Prototype.git live_desk_src
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
