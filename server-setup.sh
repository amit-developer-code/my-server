#!/usr/bin/env bash
#
# server-setup.sh - One-shot Ubuntu server setup for a Node app (Next.js or
# NestJS) behind Nginx.
#
# Installs/configures: nginx + ufw, base folder with deploy.conf, reverse-proxy
# vhost with a fallback page, nvm + Node, certbot SSL. Does NOT deploy or start
# the app - run deploy.sh (Next.js) or nest-deploy.sh (NestJS) for that; both
# read deploy.conf.
#
# Run it once per app; a port already used by another site's nginx config is
# refused.
#
# Usage:
#   ./server-setup.sh                          # asks for every value
#   ./server-setup.sh -d example.com -p 8080 -e me@example.com
#
# Any value not given as a flag is asked for; press Enter to keep the
# default shown in [brackets].
#
# Run as root or as a normal user with sudo rights. nvm/Node are installed
# under that user, so run the deploy scripts as the same user.
#
# Needs maintenance.html next to this script: it is copied (on every run) to
# /var/www/DOMAIN-static/ and shown while the app is down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE_SRC="$SCRIPT_DIR/maintenance.html"

DEFAULT_PORT="8080"
DEFAULT_NODE_VERSION="v24.13.0"
DEFAULT_BRANCH="main"
DEFAULT_REDIRECT_URL="https://www.loopbitstudio.com/"
NVM_VERSION="v0.40.3"
CATCH_ALL="/etc/nginx/sites-available/000-catch-all"
SWAP_FILE="/swapfile"
SWAP_MB="2048"           # created only if the server has no swap at all

# Empty = not given as a flag, so the user is asked for it.
DOMAIN=""
PORT=""
APP_DIR=""
EMAIL=""
NODE_VERSION=""
REPO_URL=""
BRANCH=""
REDIRECT_URL=""
SKIP_SSL="false"

# ---------------------------------------------------------------- helpers ---
c_info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
c_ok()    { printf '\033[1;32m  [OK] %s\033[0m\n' "$*"; }
c_warn()  { printf '\033[1;33m  [!!] %s\033[0m\n' "$*"; }
c_die()   { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" [default] - prompts only if VAR is still empty.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  [[ -n "${!__var}" ]] && return 0
  if [[ -n "$__default" ]]; then
    read -rp "$__prompt [$__default]: " __reply || true
  else
    read -rp "$__prompt: " __reply || true
  fi
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

# need OPTION VALUE - fail clearly when a flag is missing its value.
need() { [[ -n "${2:-}" && "$2" != -* ]] || c_die "Option $1 needs a value (see --help)."; }

# A fresh server often runs automatic updates at first boot and holds the apt
# lock for a few minutes; wait for it instead of failing.
apt_wait() {
  local i
  command -v fuser >/dev/null 2>&1 || return 0
  for i in $(seq 1 60); do
    sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 || return 0
    if (( i == 1 )); then c_warn "Another apt process is running (often automatic updates on a fresh server) - waiting..."; fi
    sleep 5
  done
  c_die "apt is still locked after 5 minutes - check: ps aux | grep -E 'apt|dpkg'"
}

# apt_get ARGS - non-interactive apt-get that waits for the apt lock.
# sudo resets the environment, so the variables are passed per call.
apt_get() {
  apt_wait
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get -o DPkg::Lock::Timeout=300 "$@"
}

usage() {
  cat <<USAGE
Usage: $0 [options]
  -d, --domain    DOMAIN     e.g. example.com
  -p, --port      PORT       app port nginx proxies to (default: $DEFAULT_PORT)
  -a, --app-dir   PATH       base folder for deploy.conf + app/ (default: /var/www/DOMAIN)
  -e, --email     EMAIL      email for Let's Encrypt certificate
  -v, --node      VERSION    node version (default: $DEFAULT_NODE_VERSION)
  -r, --repo      URL        Git repo HTTPS URL (saved to deploy.conf)
  -b, --branch    BRANCH     Git branch to deploy (default: $DEFAULT_BRANCH)
      --redirect  URL        where requests by IP / unknown domains go, first run only
                             (default: $DEFAULT_REDIRECT_URL)
      --skip-ssl             do not run certbot
  -h, --help                 show this help
Anything not passed is asked for interactively.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)  need "$1" "${2:-}"; DOMAIN="$2";       shift 2 ;;
    -p|--port)    need "$1" "${2:-}"; PORT="$2";         shift 2 ;;
    -a|--app-dir) need "$1" "${2:-}"; APP_DIR="$2";      shift 2 ;;
    -e|--email)   need "$1" "${2:-}"; EMAIL="$2";        shift 2 ;;
    -v|--node)    need "$1" "${2:-}"; NODE_VERSION="$2"; shift 2 ;;
    -r|--repo)    need "$1" "${2:-}"; REPO_URL="$2";     shift 2 ;;
    -b|--branch)  need "$1" "${2:-}"; BRANCH="$2";       shift 2 ;;
    --redirect)   need "$1" "${2:-}"; REDIRECT_URL="$2"; shift 2 ;;
    --skip-ssl)   SKIP_SSL="true";       shift   ;;
    -h|--help)    usage; exit 0 ;;
    *) c_die "Unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ sanity check ---
# Works as root or as a normal user with sudo. As root, `sudo` just runs the
# command (minimal images may not even have sudo installed).
if (( EUID == 0 )); then
  sudo() { while [[ "${1:-}" == -* ]]; do shift; done; if (( $# )); then "$@"; fi; }
else
  command -v sudo >/dev/null 2>&1 || c_die "sudo is not installed."
fi
RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn 2>/dev/null || id -g)"
[[ -f /etc/debian_version ]] || c_warn "Not a Debian/Ubuntu system - apt steps may fail."
[[ -f "$PAGE_SRC" ]] || c_die "maintenance.html not found next to server-setup.sh ($PAGE_SRC) - copy it there and rerun."

ask DOMAIN "Domain (e.g. example.com)"
[[ -z "$DOMAIN" ]] && c_die "Domain is required."
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || c_die "'$DOMAIN' does not look like a valid domain."

ask PORT "App port nginx should proxy to" "$DEFAULT_PORT"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || c_die "'$PORT' is not a valid port (1-65535)."
PORT=$((10#$PORT))

# Stop if another site's nginx config already proxies to this port.
if [[ -d /etc/nginx/sites-available ]]; then
  for f in /etc/nginx/sites-available/*; do
    [[ -f "$f" && "$(basename "$f")" != "$DOMAIN" && "$f" != *.bak.* ]] || continue
    if grep -qE "proxy_pass[[:space:]]+http://(localhost|127\.0\.0\.1):$PORT[;/]" "$f"; then
      c_die "Port $PORT is already used by $f - pick another port (-p)."
    fi
  done
fi

ask APP_DIR "Base folder (deploy.conf + app/)" "/var/www/$DOMAIN"
[[ "$APP_DIR" == /* ]] || c_die "Base folder must be an absolute path (got '$APP_DIR')."
APP_DIR="${APP_DIR%/}"

ask NODE_VERSION "Node version" "$DEFAULT_NODE_VERSION"
[[ "$NODE_VERSION" =~ ^(v?[0-9]+(\.[0-9]+){0,2}|lts/.+|node)$ ]] \
  || c_die "'$NODE_VERSION' is not a Node version nvm understands (e.g. v24.13.0, 24, lts/*)."

ask REPO_URL "Git repo HTTPS URL (blank = ask at first deploy)"
if [[ -n "$REPO_URL" ]]; then
  [[ "$REPO_URL" =~ ^https://[^[:space:]\"]+$ ]] || c_die "Repo URL must start with https:// (got '$REPO_URL')."
  [[ "$REPO_URL" =~ ^https://[^/]*:[^/]*@ ]] && c_die "Do not put the token in the URL - the deploy script asks for it separately."
fi
ask BRANCH "Git branch to deploy" "$DEFAULT_BRANCH"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || c_die "'$BRANCH' is not a valid branch name."

# The catch-all is server-wide: only asked for (and created) on the first run.
if [[ -f "$CATCH_ALL" ]]; then
  REDIRECT_LABEL="already set up ($CATCH_ALL) - left untouched"
else
  ask REDIRECT_URL "Redirect requests by IP / unknown domains to" "$DEFAULT_REDIRECT_URL"
  [[ "$REDIRECT_URL" =~ ^https?://[^[:space:]\;\'\"\$]+$ ]] || c_die "Redirect must be a full http(s):// URL without spaces, quotes, ; or \$ (got '$REDIRECT_URL')."
  REDIRECT_LABEL="$REDIRECT_URL"
fi

# Add www. only for a root domain (exactly one dot, e.g. example.com).
if [[ "$DOMAIN" =~ ^[^.]+\.[^.]+$ ]]; then
  DOMAINS=("$DOMAIN" "www.$DOMAIN")
else
  DOMAINS=("$DOMAIN")
fi
CERTBOT_DOMAINS=()
for d in "${DOMAINS[@]}"; do CERTBOT_DOMAINS+=(-d "$d"); done

FALLBACK_DIR="/var/www/$DOMAIN-static"

if [[ "$SKIP_SSL" != "true" ]]; then
  ask EMAIL "Email for SSL certificate (blank = skip SSL)"
  if [[ -z "$EMAIL" ]]; then
    SKIP_SSL="true"
  else
    [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || c_die "'$EMAIL' does not look like a valid email."
  fi
fi

SSL_LABEL="certbot ($EMAIL)"
[[ "$SKIP_SSL" == "true" ]] && SSL_LABEL="skipped"

cat <<SUMMARY

------------------------------------------------------------
  Domain(s)   : ${DOMAINS[*]}
  Base dir    : $APP_DIR (deploy.conf + app/)
  Fallback    : $FALLBACK_DIR/maintenance.html (copy of $PAGE_SRC)
  App port    : $PORT
  Node        : $NODE_VERSION (via nvm $NVM_VERSION)
  Repo        : ${REPO_URL:-(asked at first deploy)} ($BRANCH)
  Unknown/IP  : $REDIRECT_LABEL
  Run as      : $RUN_USER
  SSL         : $SSL_LABEL
------------------------------------------------------------
SUMMARY
CONFIRM=""
read -rp "Proceed? [y/N] " CONFIRM || true
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

# Prime sudo once so later steps do not stall on a password prompt. Skipped
# when sudo needs no password (e.g. the default user on AWS/cloud images) -
# some sudo versions still ask for one on `sudo -v` in that case.
if ! sudo -n true 2>/dev/null; then
  sudo -v || c_die "sudo authentication failed."
fi

# ------------------------------------------------------- 1. system packages ---
c_info "1/7  Updating packages and installing nginx"
apt_get update -y
apt_get install -y nginx curl ca-certificates git
c_ok "nginx + git installed"

# ---------------------------------------------------------------- 2. swap ---
# Small servers (e.g. 1-2 GB AWS instances) have no swap, and npm install /
# builds then get killed for lack of memory. Add a swap file only if there is
# no swap at all; existing swap is left alone.
c_info "2/7  Checking swap"
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  c_ok "swap already present - leaving it alone"
elif [[ -e "$SWAP_FILE" ]]; then
  c_warn "$SWAP_FILE exists but is not active - not touching it (enable with: sudo swapon $SWAP_FILE)"
else
  FREE_MB="$(df --output=avail -m / | tail -n 1 | tr -d ' ')"
  if (( FREE_MB < SWAP_MB + 1024 )); then
    c_warn "Only ${FREE_MB} MB free disk - not creating ${SWAP_MB} MB swap (needs 1 GB spare). npm install may run out of memory."
  else
    sudo fallocate -l "${SWAP_MB}M" "$SWAP_FILE" \
      || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=none
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE" >/dev/null
    sudo swapon "$SWAP_FILE" || c_die "Could not enable swap on $SWAP_FILE - check: sudo swapon $SWAP_FILE"
    # Keep it after reboot.
    grep -qE "^$SWAP_FILE[[:space:]]" /etc/fstab \
      || echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    c_ok "created ${SWAP_MB} MB swap at $SWAP_FILE (kept after reboot)"
  fi
fi

# ----------------------------------------------------------------- 3. ufw ---
c_info "3/7  Configuring firewall (ufw)"
if command -v ufw >/dev/null 2>&1; then
  if sudo ufw allow OpenSSH; then
    sudo ufw allow 'Nginx Full' || c_warn "Could not add Nginx Full rule"
    if ! sudo ufw status | grep -qi "^Status: active"; then
      sudo ufw --force enable
    fi
    sudo ufw status verbose
    c_ok "firewall configured (SSH + HTTP/HTTPS allowed)"
  else
    c_warn "Could not add OpenSSH rule - NOT enabling ufw (it would cut off SSH)"
  fi
else
  c_warn "ufw not present - skipping firewall step"
fi

# -------------------------------------------------------------- 4. folders ---
c_info "4/7  Creating base folder, deploy.conf and fallback page"
# The deploy script clones the code into app/ here on the first deploy.
sudo mkdir -p "$APP_DIR"
sudo chown "$RUN_USER":"$RUN_GROUP" "$APP_DIR"
sudo chmod 755 "$APP_DIR"

CONF="$APP_DIR/deploy.conf"
if [[ -f "$CONF" ]]; then
  c_warn "$CONF already exists - leaving it untouched."
else
  cat > "$CONF" <<EOF_CONF
# deploy.conf - written by server-setup.sh, read by deploy.sh / nest-deploy.sh.
# Format: KEY="value" (values must stay in double quotes).
DOMAIN="$DOMAIN"
PORT="$PORT"            # must match proxy_pass in /etc/nginx/sites-available/$DOMAIN
NODE_VERSION="$NODE_VERSION"
APP_NAME="$DOMAIN"      # pm2 process name
REPO_URL="$REPO_URL"    # HTTPS URL; asked on first deploy if empty
BRANCH="$BRANCH"
EOF_CONF
  c_ok "wrote $CONF"
fi

sudo mkdir -p "$FALLBACK_DIR"
# Copied on every run, so editing maintenance.html and rerunning updates it.
sudo install -m 644 "$PAGE_SRC" "$FALLBACK_DIR/maintenance.html"
c_ok "base folder $APP_DIR and fallback page ready"

# --------------------------------------------------------- 5. nginx vhost ---
c_info "5/7  Writing nginx server block"

# Requests by IP or for domains not set up here: redirect instead of showing
# the "Welcome to nginx!" page. Replaces nginx's default site (first run only).
# Only one site may be the default; if another (not nginx's own) already is, leave it.
OTHER_DEFAULT="$(grep -lE 'listen[^;]*default_server' /etc/nginx/sites-enabled/* 2>/dev/null | grep -v '/default$' || true)"
if [[ ! -f "$CATCH_ALL" && -n "$OTHER_DEFAULT" ]]; then
  c_warn "Not adding the catch-all redirect: $OTHER_DEFAULT already handles unknown domains / IP."
elif [[ ! -f "$CATCH_ALL" ]]; then
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo tee "$CATCH_ALL" >/dev/null <<NGINX
# Written by server-setup.sh: requests by IP or for unknown domains.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 302 $REDIRECT_URL;
}
NGINX
  sudo ln -sfn "$CATCH_ALL" "/etc/nginx/sites-enabled/000-catch-all"
  c_ok "nginx default site disabled; unknown domains / IP -> $REDIRECT_URL"
fi

VHOST="/etc/nginx/sites-available/$DOMAIN"
if [[ -f "$VHOST" ]]; then
  # Never overwrite: it may already hold certbot's HTTPS settings.
  c_warn "$VHOST already exists - leaving it untouched."
  c_warn "Delete it and rerun if you want it regenerated."
else
  sudo tee "$VHOST" >/dev/null <<NGINX
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAINS[*]};

    client_max_body_size 20M;

    # Shown when the app is not running / not reachable. Sent as 503 so
    # proxies like Cloudflare pass this page through instead of their own.
    error_page 502 503 504 =503 /maintenance.html;
    location = /maintenance.html {
        root $FALLBACK_DIR;
        internal;
    }

    location / {
        proxy_pass http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGINX

  sudo ln -sfn "$VHOST" "/etc/nginx/sites-enabled/$DOMAIN"

  # Long domain names need a bigger hash bucket; uncomment it if present.
  if grep -qE "^[[:space:]]*#[[:space:]]*server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
    sudo sed -i "s/^\([[:space:]]*\)#[[:space:]]*server_names_hash_bucket_size\(.*\)/\1server_names_hash_bucket_size\2/" /etc/nginx/nginx.conf
    c_ok "enabled server_names_hash_bucket_size in nginx.conf"
  fi
fi

sudo nginx -t || c_die "nginx config test failed - review $VHOST and $CATCH_ALL (only one site may use default_server)"
sudo systemctl enable nginx >/dev/null 2>&1 || true
# Starts nginx if it is not running yet (reload alone fails then).
sudo systemctl reload-or-restart nginx \
  || c_die "nginx did not start - check: sudo journalctl -u nginx -n 50 (is another web server using port 80?)"
c_ok "nginx running and enabled at boot"

# ---------------------------------------------------------- 6. nvm + node ---
c_info "6/7  Installing nvm + Node $NODE_VERSION"
export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash
else
  c_ok "nvm already installed"
fi
# nvm.sh is not written for `set -u`; relax it while nvm runs.
set +u
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
  nvm install "$NODE_VERSION"
fi
nvm alias default "$NODE_VERSION" >/dev/null
nvm use default >/dev/null
set -u
c_ok "node $(node -v) / npm $(npm -v)"

# ------------------------------------------------------------------ 7. ssl ---
SCHEME="http"
if [[ "$SKIP_SSL" == "true" ]]; then
  c_info "7/7  SSL skipped"
  c_warn "Run later: sudo certbot --nginx ${CERTBOT_DOMAINS[*]}"
else
  c_info "7/7  Issuing SSL certificate with certbot"
  apt_get install -y certbot python3-certbot-nginx
  if sudo certbot --nginx --non-interactive --agree-tos \
        -m "$EMAIL" --redirect "${CERTBOT_DOMAINS[@]}"; then
    SCHEME="https"
    c_ok "HTTPS enabled (auto-renewal via certbot.timer)"
  else
    c_warn "certbot failed - point ${DOMAINS[*]} at this server IP, then rerun:"
    c_warn "  sudo certbot --nginx ${CERTBOT_DOMAINS[*]}"
  fi
fi

cat <<DONE

============================================================
  SERVER SETUP COMPLETE
  Site      : $SCHEME://$DOMAIN   (fallback page until the app runs)
  Base dir  : $APP_DIR   (nginx proxies to port $PORT)
  Config    : $CONF
  Nginx     : sudo nginx -t && sudo systemctl reload nginx
  NEXT      : ./deploy.sh        (Next.js)
              ./nest-deploy.sh   (NestJS)
  NOTE      : open a new shell (or run: source ~/.bashrc) to get node on PATH
============================================================
DONE
