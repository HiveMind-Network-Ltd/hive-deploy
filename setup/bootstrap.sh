#!/usr/bin/env bash
# hive-deploy bootstrap installer
#
# Run with:
#   bash <(curl -sSL https://raw.githubusercontent.com/HiveMind-Network-Ltd/hive-deploy/main/setup/bootstrap.sh)
#
# The bash <(...) form keeps stdin connected to the terminal so interactive
# prompts work correctly (unlike curl ... | bash which breaks them).

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { printf "${CYAN}▸${RESET} %s\n" "$*"; }
success() { printf "${GREEN}✔${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*"; }
die()     { printf "${RED}✖${RESET} %s\n" "$*" >&2; exit 1; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${RESET}\n" "$*"; }

# ── Constants ──────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/HiveMind-Network-Ltd/hive-deploy.git"
DEPLOY_USER="${USER}"
INSTALL_DIR="${HOME}/hive-deploy"
CONFIG_FILE="${INSTALL_DIR}/config.json"
SYSTEMD_DIR="/etc/systemd/system"

printf "\n${BOLD}${CYAN}"
printf "╔══════════════════════════════════════╗\n"
printf "║        hive-deploy  installer        ║\n"
printf "╚══════════════════════════════════════╝\n"
printf "${RESET}\n"
printf "Installing as user: %s\n" "${DEPLOY_USER}"
printf "Install directory:  %s\n\n" "${INSTALL_DIR}"

# ── 1. Prerequisites ───────────────────────────────────────────────────────────
header "Checking prerequisites"
for cmd in git python3 sudo openssl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    success "$cmd"
  else
    die "$cmd is required but not installed. Please install it and re-run."
  fi
done

# ── 2. Clone or update repo ────────────────────────────────────────────────────
header "Setting up hive-deploy"
if [ -d "${INSTALL_DIR}/.git" ]; then
  info "Existing installation found — pulling latest..."
  git -C "${INSTALL_DIR}" pull origin main
  success "Updated to latest."
else
  info "Cloning into ${INSTALL_DIR}..."
  git clone "${REPO_URL}" "${INSTALL_DIR}"
  success "Cloned."
fi
cd "${INSTALL_DIR}"

# ── 3. Interactive project wizard ──────────────────────────────────────────────
header "Project configuration"

SKIP_CONFIG=0
if [ -f "${CONFIG_FILE}" ]; then
  warn "config.json already exists at ${CONFIG_FILE}."
  read -rp "  Overwrite with new configuration? [y/N]: " _ow
  [[ "${_ow}" =~ ^[Yy]$ ]] || SKIP_CONFIG=1
fi

declare -a PROJECT_SLUGS=()
declare -a PROJECT_SECRETS=()
PROJECT_COUNT=0

# Rocket.Chat notification config (global, optional)
RC_URL="" RC_TOKEN="" RC_USER_ID="" RC_CHANNEL=""

if [ "${SKIP_CONFIG}" -eq 0 ]; then
  echo ""
  info "── Rocket.Chat notifications (optional) ──"
  printf "  Send deploy start / success / failure messages to a Rocket.Chat channel.\n"
  read -rp "  Configure Rocket.Chat notifications? [y/N]: " _rc
  if [[ "${_rc}" =~ ^[Yy]$ ]]; then
    read -rp "  Rocket.Chat URL (e.g. https://rocket.your-domain.com): " RC_URL
    read -rp "  Personal access token (X-Auth-Token): " RC_TOKEN
    read -rp "  User ID (X-User-Id): " RC_USER_ID
    read -rp "  Channel name [github-activities]: " RC_CHANNEL_INPUT
    RC_CHANNEL="${RC_CHANNEL_INPUT:-github-activities}"
    success "Rocket.Chat notifications configured."
  else
    info "Skipping — you can add a 'notifications' block to config.json later."
  fi

  while true; do
    echo ""
    info "── New project ──"

    # Slug
    while true; do
      read -rp "  Project slug (e.g. my-app): " SLUG
      SLUG="${SLUG// /-}"
      [[ -n "${SLUG}" ]] && break
      warn "Slug cannot be empty."
    done

    # Secret
    GEN_SECRET="$(openssl rand -hex 16)"
    printf "  Secret — press Enter to auto-generate, or type your own.\n"
    read -rp "  Secret [${GEN_SECRET}]: " USER_SECRET
    SECRET="${USER_SECRET:-${GEN_SECRET}}"

    # Project type: git or docker
    printf "  Project type:\n"
    printf "    [g] Git  (git pull + build commands)\n"
    printf "    [d] Docker  (docker run or docker compose)\n"
    while true; do
      read -rp "  Type [g/d]: " PROJ_TYPE
      PROJ_TYPE="${PROJ_TYPE,,}"
      [[ "${PROJ_TYPE}" == "g" || "${PROJ_TYPE}" == "d" ]] && break
      warn "Please enter g or d."
    done

    declare -a CMDS=()

    if [[ "${PROJ_TYPE}" == "d" ]]; then
      # ── Docker project ──────────────────────────────────────────────────────
      printf "  Docker deployment style:\n"
      printf "    [r] docker run    — pull image, swap container\n"
      printf "    [c] docker compose — compose pull + up\n"
      printf "    [m] manual        — I'll type the commands myself\n"
      while true; do
        read -rp "  Style [r/c/m]: " DOCKER_STYLE
        DOCKER_STYLE="${DOCKER_STYLE,,}"
        [[ "${DOCKER_STYLE}" == "r" || "${DOCKER_STYLE}" == "c" || "${DOCKER_STYLE}" == "m" ]] && break
        warn "Please enter r, c, or m."
      done

      case "${DOCKER_STYLE}" in
        r)
          while true; do
            read -rp "  Image name (e.g. ghcr.io/your-org/your-app:latest): " DOCKER_IMAGE
            [[ -n "${DOCKER_IMAGE}" ]] && break
            warn "Image name cannot be empty."
          done
          while true; do
            read -rp "  Container name (e.g. ${SLUG}): " DOCKER_CONTAINER
            [[ -n "${DOCKER_CONTAINER}" ]] && break
            warn "Container name cannot be empty."
          done
          read -rp "  Port mapping, blank to skip (e.g. 3000:3000): " DOCKER_PORT
          read -rp "  Working directory [${HOME}]: " REPO_PATH_INPUT
          REPO_PATH="${REPO_PATH_INPUT:-${HOME}}"
          CMDS+=("docker pull ${DOCKER_IMAGE}")
          CMDS+=("docker stop ${DOCKER_CONTAINER} || true")
          CMDS+=("docker rm   ${DOCKER_CONTAINER} || true")
          if [[ -n "${DOCKER_PORT}" ]]; then
            CMDS+=("docker run -d --name ${DOCKER_CONTAINER} --restart unless-stopped -p ${DOCKER_PORT} ${DOCKER_IMAGE}")
          else
            CMDS+=("docker run -d --name ${DOCKER_CONTAINER} --restart unless-stopped ${DOCKER_IMAGE}")
          fi
          ;;
        c)
          while true; do
            read -rp "  Path to directory containing docker-compose.yml: " REPO_PATH
            [[ -n "${REPO_PATH}" ]] && break
            warn "Path cannot be empty."
          done
          CMDS+=("docker compose pull")
          CMDS+=("docker compose up -d --remove-orphans")
          ;;
        m)
          read -rp "  Working directory [${HOME}]: " REPO_PATH_INPUT
          REPO_PATH="${REPO_PATH_INPUT:-${HOME}}"
          printf "  Deploy commands — one per line, blank line when done.\n"
          while IFS= read -rp "    > " CMD_LINE; do
            [[ -z "${CMD_LINE}" ]] && break
            CMDS+=("${CMD_LINE}")
          done
          if [ "${#CMDS[@]}" -eq 0 ]; then
            CMDS=("docker compose pull" "docker compose up -d --remove-orphans")
          fi
          ;;
      esac
    else
      # ── Git project ─────────────────────────────────────────────────────────
      while true; do
        read -rp "  Absolute repo path on this server (e.g. /home/${DEPLOY_USER}/my_app_src): " REPO_PATH
        [[ -n "${REPO_PATH}" ]] && break
        warn "Repo path cannot be empty."
      done
      printf "  Deploy commands — one per line, blank line when done.\n"
      printf "  (Press Enter immediately to use default: git pull origin master)\n"
      while IFS= read -rp "    > " CMD_LINE; do
        [[ -z "${CMD_LINE}" ]] && break
        CMDS+=("${CMD_LINE}")
      done
      if [ "${#CMDS[@]}" -eq 0 ]; then
        CMDS=("git pull origin master")
      fi
    fi

    # Store summary data for the final output
    PROJECT_SLUGS+=("${SLUG}")
    PROJECT_SECRETS+=("${SECRET}")

    # Export per-project data for Python (handles all escaping correctly)
    export "PROJ_${PROJECT_COUNT}_SLUG=${SLUG}"
    export "PROJ_${PROJECT_COUNT}_SECRET=${SECRET}"
    export "PROJ_${PROJECT_COUNT}_PATH=${REPO_PATH}"

    CMD_TMP="$(mktemp)"
    printf '%s\n' "${CMDS[@]}" > "${CMD_TMP}"
    export "PROJ_${PROJECT_COUNT}_CMDS_FILE=${CMD_TMP}"

    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    success "Project '${SLUG}' configured."

    read -rp "  Add another project? [y/N]: " _more
    [[ "${_more}" =~ ^[Yy]$ ]] || break
  done

  # Write config.json via Python so all values are correctly JSON-encoded
  export PROJECT_COUNT _CONFIG_FILE="${CONFIG_FILE}"
  export _RC_URL="${RC_URL}" _RC_TOKEN="${RC_TOKEN}" _RC_USER_ID="${RC_USER_ID}" _RC_CHANNEL="${RC_CHANNEL}"
  info "Writing config.json..."
  python3 - << 'PYEOF'
import json, os

count = int(os.environ['PROJECT_COUNT'])
config = {}

# Notifications block (only written if all fields are set)
rc_url     = os.environ.get('_RC_URL', '')
rc_token   = os.environ.get('_RC_TOKEN', '')
rc_user_id = os.environ.get('_RC_USER_ID', '')
rc_channel = os.environ.get('_RC_CHANNEL', '')
if all([rc_url, rc_token, rc_user_id, rc_channel]):
    config['notifications'] = {
        'rc_url':     rc_url,
        'rc_token':   rc_token,
        'rc_user_id': rc_user_id,
        'rc_channel': rc_channel,
    }

config['projects'] = {}
for i in range(count):
    slug      = os.environ[f'PROJ_{i}_SLUG']
    secret    = os.environ[f'PROJ_{i}_SECRET']
    path      = os.environ[f'PROJ_{i}_PATH']
    cmds_file = os.environ[f'PROJ_{i}_CMDS_FILE']
    with open(cmds_file) as f:
        cmds = [line.rstrip() for line in f if line.strip()]
    config['projects'][slug] = {
        'secret':    secret,
        'repo_path': path,
        'commands':  cmds,
    }

with open(os.environ['_CONFIG_FILE'], 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF

  # Clean up temp command files
  for i in $(seq 0 $((PROJECT_COUNT - 1))); do
    varname="PROJ_${i}_CMDS_FILE"
    rm -f "${!varname}" 2>/dev/null || true
  done

  success "config.json written."
fi

# ── 4. Systemd units ───────────────────────────────────────────────────────────
header "Installing systemd units"

SVC_TMP="$(mktemp)"
sed \
  -e "s|User=ubuntu|User=${DEPLOY_USER}|g" \
  -e "s|Group=ubuntu|Group=${DEPLOY_USER}|g" \
  -e "s|/home/ubuntu/hive-deploy|${INSTALL_DIR}|g" \
  "${INSTALL_DIR}/setup/hive-deploy.service" > "${SVC_TMP}"

sudo cp "${SVC_TMP}" "${SYSTEMD_DIR}/hive-deploy.service"
sudo cp "${INSTALL_DIR}/setup/hive-deploy.socket" "${SYSTEMD_DIR}/hive-deploy.socket"
rm -f "${SVC_TMP}"

sudo systemctl daemon-reload
sudo systemctl enable hive-deploy.socket
sudo systemctl start hive-deploy.socket
success "hive-deploy.socket enabled and started."

# ── 4b. Docker group check ─────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  if groups "${DEPLOY_USER}" 2>/dev/null | grep -qw docker; then
    success "'${DEPLOY_USER}' is already in the docker group."
  else
    warn "Docker is installed but '${DEPLOY_USER}' is not in the docker group."
    warn "Deploy commands that use docker will fail without this."
    read -rp "  Add '${DEPLOY_USER}' to the docker group now? [Y/n]: " _dg
    if [[ ! "${_dg}" =~ ^[Nn]$ ]]; then
      sudo usermod -aG docker "${DEPLOY_USER}"
      success "'${DEPLOY_USER}' added to the docker group."
      warn "Group change takes effect on next login — run 'newgrp docker' to apply now."
    fi
  fi
fi

# ── 5. Web server configuration ────────────────────────────────────────────────
header "Web server configuration"

NGINX_ACTIVE=0
APACHE_ACTIVE=0
TRAEFIK_ACTIVE=0
TRAEFIK_CONTAINER=""
TRAEFIK_DYNAMIC_DIR=""
DEPLOY_URL=""

systemctl is-active --quiet nginx   2>/dev/null && NGINX_ACTIVE=1  || true
systemctl is-active --quiet apache2 2>/dev/null && APACHE_ACTIVE=1 || true

# Detect Traefik running inside Docker
if command -v docker >/dev/null 2>&1; then
  TRAEFIK_CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
    | grep -i traefik | head -1 | awk '{print $1}')" || true
  if [ -n "${TRAEFIK_CONTAINER}" ]; then
    TRAEFIK_ACTIVE=1
    # Find the host path mounted as /dynamic inside the Traefik container
    TRAEFIK_DYNAMIC_DIR="$(docker inspect "${TRAEFIK_CONTAINER}" 2>/dev/null \
      | python3 -c "
import json, sys
mounts = json.load(sys.stdin)[0].get('Mounts', [])
for m in mounts:
    if m.get('Destination') == '/dynamic':
        print(m.get('Source', ''))
        break
" 2>/dev/null)" || true
  fi
fi

# Write a Python patcher script to a temp file and run it with sudo.
# Using a temp file avoids sudo dropping environment variables and avoids
# any shell expansion of nginx/apache config directives like $host.

_pick_site_conf() {
  local sites_dir="$1"
  local label="$2"

  if [ ! -d "${sites_dir}" ]; then
    warn "${label} sites-enabled dir not found: ${sites_dir}"
    echo ""
    return
  fi

  mapfile -t _CONFS < <(find "${sites_dir}" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)
  if [ "${#_CONFS[@]}" -eq 0 ]; then
    warn "No ${label} site configs found in ${sites_dir}."
    echo ""
    return
  fi

  if [ "${#_CONFS[@]}" -eq 1 ]; then
    info "Using ${label} config: ${_CONFS[0]}"
    echo "${_CONFS[0]}"
    return
  fi

  echo "  Multiple ${label} configs found:"
  for i in "${!_CONFS[@]}"; do
    printf "    [%d] %s\n" "$((i+1))" "${_CONFS[$i]}"
  done
  while true; do
    read -rp "  Which file should hive-deploy be added to? [1-${#_CONFS[@]}]: " _choice
    [[ "${_choice}" =~ ^[0-9]+$ ]] && \
      [ "${_choice}" -ge 1 ] && \
      [ "${_choice}" -le "${#_CONFS[@]}" ] && break
    warn "Please enter a number between 1 and ${#_CONFS[@]}."
  done
  echo "${_CONFS[$((_choice-1))]}"
}

if [ "${NGINX_ACTIVE}" -eq 1 ]; then
  info "Nginx detected — auto-configuring..."
  NGINX_CONF="$(_pick_site_conf "/etc/nginx/sites-enabled" "Nginx")"

  if [ -n "${NGINX_CONF}" ]; then
    PATCHER="$(mktemp)"
    # Quoted heredoc delimiter prevents bash expanding $host / $remote_addr
    cat > "${PATCHER}" << 'PYEOF'
import sys

site_conf = sys.argv[1]
with open(site_conf, 'r') as f:
    content = f.read()

if 'location /deploy/' in content:
    print('ALREADY_PATCHED')
    sys.exit(0)

block = (
    "\n"
    "    location /deploy/ {\n"
    "        proxy_pass         http://127.0.0.1:5678;\n"
    "        proxy_http_version 1.1;\n"
    "        proxy_set_header   Host $host;\n"
    "        proxy_set_header   X-Real-IP $remote_addr;\n"
    "        proxy_read_timeout 10s;\n"
    "        proxy_connect_timeout 5s;\n"
    "    }\n"
)

pos = content.rfind('}')
if pos == -1:
    print('NO_CLOSING_BRACE')
    sys.exit(1)

new_content = content[:pos] + block + content[pos:]

with open(site_conf + '.hive-bak', 'w') as f:
    f.write(content)
with open(site_conf, 'w') as f:
    f.write(new_content)
print('PATCHED')
PYEOF

    RESULT="$(sudo python3 "${PATCHER}" "${NGINX_CONF}")"
    rm -f "${PATCHER}"

    case "${RESULT}" in
      ALREADY_PATCHED)
        warn "location /deploy/ already present — skipping." ;;
      PATCHED)
        success "Inserted location /deploy/ block into ${NGINX_CONF}."
        info "Backup saved: ${NGINX_CONF}.hive-bak"
        info "Testing Nginx config..."
        sudo nginx -t && sudo systemctl reload nginx
        success "Nginx reloaded." ;;
      NO_CLOSING_BRACE)
        warn "Could not find closing brace in ${NGINX_CONF}. Add the block manually:"
        printf "\n"; cat "${INSTALL_DIR}/setup/nginx-location.conf"; printf "\n" ;;
      *)
        warn "Unexpected result patching ${NGINX_CONF}. Add the block manually:"
        printf "\n"; cat "${INSTALL_DIR}/setup/nginx-location.conf"; printf "\n" ;;
    esac
  fi
fi

if [ "${APACHE_ACTIVE}" -eq 1 ]; then
  info "Apache2 detected — auto-configuring..."
  APACHE_CONF="$(_pick_site_conf "/etc/apache2/sites-enabled" "Apache2")"

  if [ -n "${APACHE_CONF}" ]; then
    PATCHER="$(mktemp)"
    cat > "${PATCHER}" << 'PYEOF'
import sys

site_conf = sys.argv[1]
with open(site_conf, 'r') as f:
    content = f.read()

if 'ProxyPass /deploy/' in content:
    print('ALREADY_PATCHED')
    sys.exit(0)

block = (
    "\n"
    "    # hive-deploy webhook proxy\n"
    "    ProxyPreserveHost On\n"
    "    ProxyPass        /deploy/ http://127.0.0.1:5678/\n"
    "    ProxyPassReverse /deploy/ http://127.0.0.1:5678/\n"
)

marker = '</VirtualHost>'
pos = content.rfind(marker)
if pos == -1:
    print('NO_VIRTUALHOST')
    sys.exit(1)

new_content = content[:pos] + block + content[pos:]

with open(site_conf + '.hive-bak', 'w') as f:
    f.write(content)
with open(site_conf, 'w') as f:
    f.write(new_content)
print('PATCHED')
PYEOF

    RESULT="$(sudo python3 "${PATCHER}" "${APACHE_CONF}")"
    rm -f "${PATCHER}"

    case "${RESULT}" in
      ALREADY_PATCHED)
        warn "ProxyPass /deploy/ already present — skipping." ;;
      PATCHED)
        success "Inserted ProxyPass block into ${APACHE_CONF}."
        info "Backup saved: ${APACHE_CONF}.hive-bak"
        info "Enabling proxy modules..."
        sudo a2enmod proxy proxy_http
        info "Testing Apache2 config..."
        sudo apache2ctl configtest && sudo systemctl reload apache2
        success "Apache2 reloaded." ;;
      NO_VIRTUALHOST)
        warn "Could not find </VirtualHost> in ${APACHE_CONF}. Add the block manually:"
        printf "\n"; cat "${INSTALL_DIR}/setup/apache2-proxy.conf"; printf "\n" ;;
      *)
        warn "Unexpected result patching ${APACHE_CONF}. Add the block manually:"
        printf "\n"; cat "${INSTALL_DIR}/setup/apache2-proxy.conf"; printf "\n" ;;
    esac
  fi
fi

if [ "${TRAEFIK_ACTIVE}" -eq 1 ]; then
  info "Traefik detected (container: ${TRAEFIK_CONTAINER}) — auto-configuring..."

  # Confirm or override the dynamic config directory
  if [ -n "${TRAEFIK_DYNAMIC_DIR}" ]; then
    info "Found Traefik dynamic config directory: ${TRAEFIK_DYNAMIC_DIR}"
    read -rp "  Use this directory? [Y/n]: " _td
    if [[ "${_td}" =~ ^[Nn]$ ]]; then
      read -rp "  Enter path to Traefik dynamic config directory: " TRAEFIK_DYNAMIC_DIR
    fi
  else
    warn "Could not auto-detect Traefik dynamic config directory."
    read -rp "  Enter path to Traefik dynamic config directory: " TRAEFIK_DYNAMIC_DIR
  fi

  # Subdomain
  while true; do
    read -rp "  Subdomain for deploy endpoint (e.g. deploy.your-domain.com): " TRAEFIK_DOMAIN
    [[ -n "${TRAEFIK_DOMAIN}" ]] && break
    warn "Subdomain cannot be empty."
  done
  DEPLOY_URL="https://${TRAEFIK_DOMAIN}"

  # Docker bridge IP — how Traefik reaches the host
  BRIDGE_IP="$(ip route 2>/dev/null | grep docker0 | awk '{print $9}' | head -1)" || true
  if [ -z "${BRIDGE_IP}" ]; then
    BRIDGE_IP="172.17.0.1"
    warn "Could not auto-detect docker bridge IP, using default ${BRIDGE_IP}."
    warn "Verify with: ip addr show docker0 | grep inet"
  else
    success "Docker bridge IP: ${BRIDGE_IP}"
  fi

  # Write Traefik dynamic config
  HIVE_DYNAMIC="${TRAEFIK_DYNAMIC_DIR}/hive-deploy.yml"
  sudo tee "${HIVE_DYNAMIC}" > /dev/null << YAML
http:
  routers:
    hive-deploy:
      rule: "Host(\`${TRAEFIK_DOMAIN}\`)"
      entrypoints:
        - websecure
      tls:
        certresolver: le-http
      service: hive-deploy-svc

  services:
    hive-deploy-svc:
      loadBalancer:
        servers:
          - url: "http://${BRIDGE_IP}:5678"
YAML
  success "Traefik config written: ${HIVE_DYNAMIC}"
  info "Traefik will hot-reload this automatically (providers.file.watch=true)."

  # Update socket to listen on all interfaces so Docker can reach it
  info "Updating socket binding: 127.0.0.1:5678 → 0.0.0.0:5678 (required for Docker→host traffic)..."
  sudo sed -i 's|ListenStream=127.0.0.1:5678|ListenStream=5678|' "${SYSTEMD_DIR}/hive-deploy.socket"
  sudo systemctl daemon-reload
  sudo systemctl restart hive-deploy.socket
  success "Socket updated and restarted."
fi

if [ "${NGINX_ACTIVE}" -eq 0 ] && [ "${APACHE_ACTIVE}" -eq 0 ] && [ "${TRAEFIK_ACTIVE}" -eq 0 ]; then
  warn "No active web server (nginx, apache2, or Traefik) detected."
  echo ""
  echo "  For Nginx — add to your server {} block:"
  printf "\n"; cat "${INSTALL_DIR}/setup/nginx-location.conf"
  echo ""
  echo "  For Apache2 — add inside your <VirtualHost> block:"
  printf "\n"; cat "${INSTALL_DIR}/setup/apache2-proxy.conf"
  echo ""
  echo "  For Traefik — create traefik/dynamic/hive-deploy.yml:"
  cat << 'YAML'

http:
  routers:
    hive-deploy:
      rule: "Host(`deploy.your-domain.com`)"
      entrypoints:
        - websecure
      tls:
        certresolver: le-http
      service: hive-deploy-svc

  services:
    hive-deploy-svc:
      loadBalancer:
        servers:
          - url: "http://172.17.0.1:5678"
YAML
  echo ""
  warn "If using Traefik, also change ListenStream=127.0.0.1:5678 to ListenStream=5678 in ${SYSTEMD_DIR}/hive-deploy.socket"
fi

# ── 6. Summary ─────────────────────────────────────────────────────────────────
header "All done"
success "hive-deploy is installed and running."
echo ""
info "Service status:"
systemctl status hive-deploy.socket --no-pager -l 2>/dev/null | tail -n 6 || true
echo ""
info "Test a deploy endpoint:"
printf "  curl -s -X POST http://127.0.0.1:5678/deploy/<slug> \\\n"
printf "       -H 'X-Hive-Secret: <secret>'\n"
echo ""
info "View logs:"
printf "  tail -f %s/deploy.log\n" "${INSTALL_DIR}"

if [ "${#PROJECT_SLUGS[@]}" -gt 0 ]; then
  echo ""
  info "GitHub Actions — add to .github/workflows/deploy.yml for each project:"
  for i in "${!PROJECT_SLUGS[@]}"; do
    _slug="${PROJECT_SLUGS[$i]}"
    _secret="${PROJECT_SECRETS[$i]}"
    # Produce a safe uppercase name for the GitHub secret (hyphens → underscores)
    _secret_name="DEPLOY_WEBHOOK_SECRET_${_slug^^}"
    _secret_name="${_secret_name//-/_}"
    echo ""
    printf "${BOLD}  Project: %s${RESET}\n" "${_slug}"
    printf "  GitHub secret name:  %s\n" "${_secret_name}"
    printf "  GitHub secret value: %s\n" "${_secret}"
    echo ""
    # The \$ below outputs a literal $ for the GitHub Actions expression
    _base_url="${DEPLOY_URL:-https://YOUR_DOMAIN}"
    cat << YAML
    - name: Trigger ${_slug} deploy
      run: |
        curl -s -o /dev/null -w "%{http_code}" \
          -X POST ${_base_url}/deploy/${_slug} \
          -H "X-Hive-Secret: \${{ secrets.${_secret_name} }}"
YAML
  done
fi

echo ""
success "Bootstrap complete."
echo ""
