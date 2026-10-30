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
# Run as a normal user WITH sudo rights (NOT as root - nvm must be
# installed under your own user account).

set -euo pipefail

DEFAULT_PORT="8080"
DEFAULT_NODE_VERSION="v24.13.0"
DEFAULT_BRANCH="main"
NVM_VERSION="v0.40.3"

# Empty = not given as a flag, so the user is asked for it.
DOMAIN=""
PORT=""
APP_DIR=""
EMAIL=""
NODE_VERSION=""
REPO_URL=""
BRANCH=""
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

usage() {
  cat <<USAGE
Usage: $0 [options]
  -d, --domain    DOMAIN     e.g. example.com
  -p, --port      PORT       app port nginx proxies to (default: $DEFAULT_PORT)
  -a, --app-dir   PATH       base folder for releases + deploy.conf (default: /var/www/DOMAIN)
  -e, --email     EMAIL      email for Let's Encrypt certificate
  -v, --node      VERSION    node version (default: $DEFAULT_NODE_VERSION)
  -r, --repo      URL        Git repo HTTPS URL (saved to deploy.conf)
  -b, --branch    BRANCH     Git branch to deploy (default: $DEFAULT_BRANCH)
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
    --skip-ssl)   SKIP_SSL="true";       shift   ;;
    -h|--help)    usage; exit 0 ;;
    *) c_die "Unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ sanity check ---
[[ $EUID -eq 0 ]] && c_die "Do not run as root/sudo. Run as your normal user; the script calls sudo where needed."
command -v sudo >/dev/null 2>&1 || c_die "sudo is not installed."
[[ -f /etc/debian_version ]] || c_warn "Not a Debian/Ubuntu system - apt steps may fail."

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

ask APP_DIR "Base folder (releases + deploy.conf)" "/var/www/$DOMAIN"
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
  Base dir    : $APP_DIR (deploy.conf + release folders)
  Fallback    : $FALLBACK_DIR (shown when the app is down)
  App port    : $PORT
  Node        : $NODE_VERSION (via nvm $NVM_VERSION)
  Repo        : ${REPO_URL:-(asked at first deploy)} ($BRANCH)
  SSL         : $SSL_LABEL
------------------------------------------------------------
SUMMARY
CONFIRM=""
read -rp "Proceed? [y/N] " CONFIRM || true
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

# Prime sudo once so later steps do not stall on a password prompt.
sudo -v || c_die "sudo authentication failed."

# ------------------------------------------------------- 1. system packages ---
c_info "1/6  Updating packages and installing nginx"
# sudo resets the environment, so DEBIAN_FRONTEND must be passed per call.
sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates git
c_ok "nginx + git installed"

# ----------------------------------------------------------------- 2. ufw ---
c_info "2/6  Configuring firewall (ufw)"
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

# -------------------------------------------------------------- 3. folders ---
c_info "3/6  Creating base folder, deploy.conf and fallback page"
# The deploy script creates release-<version> folders and the current symlink here.
sudo mkdir -p "$APP_DIR"
sudo chown "$USER":"$USER" "$APP_DIR"
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
KEEP_RELEASES="5"       # older release-* folders are deleted after a new release
EOF_CONF
  c_ok "wrote $CONF"
fi

sudo mkdir -p "$FALLBACK_DIR"
if [[ ! -e "$FALLBACK_DIR/maintenance.html" ]]; then
  sudo tee "$FALLBACK_DIR/maintenance.html" >/dev/null <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><title>$DOMAIN</title></head>
<body><h1>$DOMAIN is temporarily unavailable</h1><p>Please try again in a few minutes.</p></body></html>
HTML
fi
c_ok "base folder $APP_DIR and fallback page ready"

# --------------------------------------------------------- 4. nginx vhost ---
c_info "4/6  Writing nginx server block"
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

    # Shown when the app is not running / not reachable.
    error_page 502 503 504 /maintenance.html;
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

sudo nginx -t || c_die "nginx config test failed - review $VHOST"
sudo systemctl reload nginx
sudo systemctl enable nginx >/dev/null 2>&1 || true
c_ok "nginx reloaded and enabled at boot"

# ---------------------------------------------------------- 5. nvm + node ---
c_info "5/6  Installing nvm + Node $NODE_VERSION"
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

# ------------------------------------------------------------------ 6. ssl ---
SCHEME="http"
if [[ "$SKIP_SSL" == "true" ]]; then
  c_info "6/6  SSL skipped"
  c_warn "Run later: sudo certbot --nginx ${CERTBOT_DOMAINS[*]}"
else
  c_info "6/6  Issuing SSL certificate with certbot"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
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
  NEXT      : ./deploy.sh --release 1.0        (Next.js)
              ./nest-deploy.sh --release 1.0   (NestJS)
  NOTE      : open a new shell (or run: source ~/.bashrc) to get node on PATH
============================================================
DONE
