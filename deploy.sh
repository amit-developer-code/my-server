#!/usr/bin/env bash
#
# deploy.sh - Deploy a Next.js app from Git into one app folder.
#
# Reads its settings from deploy.conf (written by server-setup.sh) in the base
# folder. Layout:
#
#   /var/www/example.com/
#     deploy.conf
#     shared/.env               saved .env (chmod 600), copied into app/ as .env.production.local
#     deploy.log                one line per deploy
#     app/                      the code: git clone on the first deploy,
#                               updated in place (pull, rebuild) after that
#
# The app is started with 'next start -p PORT', PORT taken from deploy.conf.
#
# Optional deploy.conf key (add by hand):
#   START_MODE="next"           next = run 'next start -p PORT' (default); script = run package.json "start" with PORT set
#
# Usage:
#   ./deploy.sh                   clone (first time) or pull, install, delete .next, build, restart
#   ./deploy.sh --dir /srv/app    base folder, if it cannot be auto-detected
#
# Run on the server as the same user that ran server-setup.sh (root or a
# normal user) - that user owns deploy.conf and has nvm/Node installed.

set -euo pipefail

BASE=""

# deploy.conf keys and their defaults. KEEP_RELEASES is accepted but no longer
# used (left over from the old release-folder layout).
CONF_KEYS="DOMAIN PORT NODE_VERSION APP_NAME REPO_URL BRANCH KEEP_RELEASES START_MODE"
DOMAIN=""
PORT=""
NODE_VERSION=""
APP_NAME=""
REPO_URL=""
BRANCH="main"
KEEP_RELEASES=""
START_MODE="next"

# Never let git hang on a hidden username/password prompt.
export GIT_TERMINAL_PROMPT=0
# Let corepack fetch pnpm/yarn without asking.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

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
      --dir PATH           base folder containing deploy.conf
  -h, --help               show this help
Clones the repo into app/ on the first deploy; after that pulls the latest
commit, reinstalls, deletes .next, rebuilds and restarts the app.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      need "$1" "${2:-}"; BASE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) c_die "Unknown option: $1 (see --help)" ;;
  esac
done

# ------------------------------------------------------------- deploy.conf ---
load_conf() {
  local line n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
      case " $CONF_KEYS " in
        *" ${BASH_REMATCH[1]} "*) printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}" ;;
        *) c_warn "deploy.conf line $n: unknown key ${BASH_REMATCH[1]} (ignored)" ;;
      esac
    else
      c_die "deploy.conf line $n is not KEY=\"value\": $line"
    fi
  done < "$CONF"
}

# set_conf KEY VALUE - update (or append) one key in deploy.conf.
set_conf() {
  local key="$1" val="$2" line found=0 tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*$key= ]]; then
      printf '%s="%s"\n' "$key" "$val"; found=1
    else
      printf '%s\n' "$line"
    fi
  done < "$CONF" > "$tmp"
  (( found )) || printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$CONF"
  rm -f "$tmp"
}

RUN_USER="$(id -un)"

if [[ -z "$BASE" ]]; then
  if [[ -f "./deploy.conf" ]]; then
    BASE="$PWD"
  else
    FOUND=()
    for f in /var/www/*/deploy.conf; do [[ -f "$f" ]] && FOUND+=("$f"); done
    if (( ${#FOUND[@]} == 1 )); then
      BASE="$(dirname "${FOUND[0]}")"
    else
      ask BASE "Base folder with deploy.conf (e.g. /var/www/example.com)"
    fi
  fi
fi
BASE="${BASE%/}"
CONF="$BASE/deploy.conf"
[[ -f "$CONF" ]] || c_die "$CONF not found - run server-setup.sh first (or pass --dir)."
# nvm/Node and pm2 live under the user that ran server-setup.sh (the owner of deploy.conf).
CONF_OWNER="$(stat -c %U "$CONF")"
[[ "$CONF_OWNER" == "$RUN_USER" ]] \
  || c_die "$CONF belongs to '$CONF_OWNER' (the user that ran server-setup.sh) - run this script as '$CONF_OWNER', not '$RUN_USER'."
load_conf

[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || c_die "deploy.conf: DOMAIN '$DOMAIN' is not a valid domain."
[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || c_die "deploy.conf: PORT '$PORT' is not a valid port."
PORT=$((10#$PORT))
[[ "$NODE_VERSION" =~ ^(v?[0-9]+(\.[0-9]+){0,2}|lts/.+|node)$ ]] || c_die "deploy.conf: NODE_VERSION '$NODE_VERSION' is not valid."
[[ -n "$APP_NAME" ]] || APP_NAME="$DOMAIN"
[[ "$START_MODE" == "next" || "$START_MODE" == "script" ]] || c_die "deploy.conf: START_MODE must be \"next\" or \"script\"."

SHARED="$BASE/shared"
ENV_FILE="$SHARED/.env"
APP_DIR="$BASE/app"

# Only one deploy at a time per base folder.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BASE/.deploy.lock"
  flock -n 9 || c_die "Another deploy is already running for $BASE."
fi

# --------------------------------------------------------------- functions ---
load_node() {
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] || c_die "nvm not found in $NVM_DIR - run server-setup.sh first."
  # nvm.sh is not written for `set -u`; relax it while nvm runs.
  set +u
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  nvm ls "$NODE_VERSION" >/dev/null 2>&1 || nvm install "$NODE_VERSION"
  nvm use "$NODE_VERSION" >/dev/null
  set -u
  c_ok "node $(node -v) / npm $(npm -v)"
}

ensure_pm2() {
  if ! command -v pm2 >/dev/null 2>&1; then
    c_info "Installing pm2"
    npm install -g pm2
  fi
  c_ok "pm2 $(pm2 -v)"
  if ! systemctl is-enabled "pm2-$RUN_USER" >/dev/null 2>&1; then
    # Register the systemd hook so pm2 restores saved apps on reboot.
    local startup_cmd
    if (( EUID == 0 )); then
      # As root, pm2 installs the hook itself instead of printing a sudo command.
      if pm2 startup systemd -u "$RUN_USER" --hp "$HOME" >/dev/null; then
        c_ok "pm2 boot hook registered"
      else
        c_warn "Could not register pm2 boot hook - run 'pm2 startup' and follow its output"
      fi
      return 0
    fi
    startup_cmd="$(pm2 startup systemd -u "$RUN_USER" --hp "$HOME" | grep -E "^sudo " || true)"
    if [[ -n "$startup_cmd" ]]; then
      eval "$startup_cmd"
      c_ok "pm2 boot hook registered"
    else
      c_warn "Could not register pm2 boot hook - run 'pm2 startup' and follow its output"
    fi
  fi
}

ensure_repo_url() {
  if [[ -z "$REPO_URL" ]]; then
    ask REPO_URL "Git repo HTTPS URL (e.g. https://github.com/you/app.git)"
    SAVE_REPO_URL="true"
  fi
  [[ "$REPO_URL" =~ ^https://[^[:space:]\"]+$ ]] || c_die "Repo URL must start with https:// (got '$REPO_URL')."
  if [[ "$REPO_URL" =~ ^https://[^/]*:[^/]*@ ]]; then
    c_die "Do not put the token in the URL - it would be saved in plain text. This script asks for it separately."
  fi
  [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || c_die "deploy.conf: BRANCH '$BRANCH' is not a valid branch name."
  if [[ "${SAVE_REPO_URL:-}" == "true" ]]; then
    set_conf REPO_URL "$REPO_URL"
    c_ok "saved REPO_URL to $CONF"
  fi
}

# Make sure git can read the private repo; ask for an HTTPS token if not.
git_auth() {
  local host user token
  if ! git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1; then
    host="${REPO_URL#https://}"; host="${host%%/*}"; host="${host#*@}"
    [[ -n "$(git config --global credential.helper || true)" ]] || git config --global credential.helper store
    c_warn "Git cannot access $REPO_URL - enter an HTTPS access token (saved in ~/.git-credentials)."
    [[ -t 0 ]] || c_die "Need a terminal to enter the token."
    read -rp "Git username: " user
    read -rsp "Access token (hidden): " token; echo
    [[ -n "$user" && -n "$token" ]] || c_die "Username and token are required."
    printf 'protocol=https\nhost=%s\n\n' "$host" | git credential reject
    printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n\n' "$host" "$user" "$token" | git credential approve
    git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1 \
      || c_die "Still cannot access $REPO_URL - check the URL and the token's scope/expiry."
  fi
  [[ -n "$(git ls-remote --heads "$REPO_URL" "$BRANCH" 2>/dev/null)" ]] \
    || c_die "Branch '$BRANCH' does not exist in $REPO_URL (change BRANCH in $CONF)."
  c_ok "git access to $REPO_URL ($BRANCH)"
}

# Ask for the .env content the first time; afterwards offer to keep it.
env_step() {
  mkdir -p "$SHARED"
  chmod 700 "$SHARED"
  if [[ -f "$ENV_FILE" ]]; then
    echo "Saved .env has these variables (values hidden):"
    grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" \
      | sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/  \2/' \
      || echo "  (none)"
    local keep=""
    read -rp "Keep existing .env? [Y/n] " keep || true
    case "$keep" in
      n|N|no|NO) ;;
      *) c_ok "keeping $ENV_FILE"; return 0 ;;
    esac
  fi
  [[ -t 0 ]] || c_die "Need a terminal to paste the .env content."
  echo "Paste your .env content below, then press Ctrl+D on an empty line:"
  local tmp count
  tmp="$(mktemp "$SHARED/.env.XXXXXX")"
  tr -d '\r' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
  count="$(grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" || true)"
  c_ok "saved $count variable(s) to $ENV_FILE"
}

# get_code - clone into app/ on the first deploy, otherwise fetch the latest commit.
get_code() {
  if [[ -d "$APP_DIR/.git" ]]; then
    c_info "Pulling latest $BRANCH into $APP_DIR"
    # Follow REPO_URL if it was changed in deploy.conf.
    git -C "$APP_DIR" remote set-url origin "$REPO_URL"
    git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH" || c_die "git fetch failed - app untouched."
    git -C "$APP_DIR" reset --hard FETCH_HEAD
  else
    c_info "Cloning $BRANCH into $APP_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR" || c_die "git clone failed."
  fi
  c_ok "code at commit $(git -C "$APP_DIR" rev-parse --short HEAD)"
}

# detect_pm DIR - sets PM and INSTALL from the lockfile in DIR.
detect_pm() {
  local dir="$1"
  if [[ -f "$dir/pnpm-lock.yaml" ]]; then
    PM="pnpm"; INSTALL=(pnpm install --frozen-lockfile)
  elif [[ -f "$dir/yarn.lock" ]]; then
    PM="yarn"
    if [[ -f "$dir/.yarnrc.yml" ]]; then INSTALL=(yarn install --immutable); else INSTALL=(yarn install --frozen-lockfile); fi
  elif [[ -f "$dir/package-lock.json" ]]; then
    PM="npm"; INSTALL=(npm ci)
  else
    PM="npm"; INSTALL=(npm install)
  fi
  if [[ "$PM" != "npm" ]]; then
    corepack enable "$PM" || return 1
  fi
}

# build_in DIR - copy .env, install deps, delete .next and build.
# Called from `if`, where set -e is off, so every step checks its own result.
build_in() {
  local dir="$1"
  cd "$dir" || return 1
  [[ -f package.json ]] || { c_warn "No package.json in $dir"; return 1; }
  # Highest-priority env file for Next.js in production, normally git-ignored.
  install -m 600 "$ENV_FILE" "$dir/.env.production.local" || return 1
  detect_pm "$dir" || return 1
  c_info "Installing dependencies (${INSTALL[*]})"
  "${INSTALL[@]}" || return 1
  c_info "Deleting old .next and building ($PM run build)"
  rm -rf .next || return 1
  "$PM" run build || return 1
  [[ -f .next/BUILD_ID ]] || { c_warn "Build finished but .next/BUILD_ID is missing"; return 1; }
}

# start_app DIR - (re)start pm2 on DIR and wait for the app to answer.
start_app() {
  local dir="$1" code="000" i
  c_info "Starting $APP_NAME on port $PORT"
  pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  if [[ "$START_MODE" == "script" ]]; then
    detect_pm "$dir" || return 1
    PORT="$PORT" pm2 start "$PM" --name "$APP_NAME" --cwd "$dir" -- run start || return 1
  else
    local next_bin="$dir/node_modules/next/dist/bin/next"
    if [[ ! -f "$next_bin" ]]; then
      c_warn "$next_bin not found - set START_MODE=\"script\" in $CONF if this app has a custom server."
      return 1
    fi
    pm2 start "$next_bin" --name "$APP_NAME" --cwd "$dir" -- start -p "$PORT" || return 1
  fi
  pm2 save >/dev/null
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
    [[ "$code" =~ ^[1-4] ]] && { c_ok "app answered HTTP $code"; return 0; }
    sleep 1
  done
  c_warn "App did not answer properly on port $PORT within 30s (last HTTP code: $code)."
  c_warn "Check: pm2 logs $APP_NAME"
  return 1
}

log_deploy() {  # RESULT DETAIL
  printf '%s  %-10s %s\n' "$(date '+%F %T')" "$1" "$2" >> "$BASE/deploy.log"
}

# ------------------------------------------------------------------- main ---
ensure_repo_url

# Checked before anything changes: clone needs an empty (or missing) app/.
if [[ ! -d "$APP_DIR/.git" && -e "$APP_DIR" ]] && [[ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
  c_die "$APP_DIR exists but is not a git checkout - move it away, then rerun."
fi

if [[ -d "$APP_DIR/.git" ]]; then
  ACTION="update $APP_DIR in place (git pull, rebuild, restart - the site may error during the build)"
else
  ACTION="first deploy: clone into $APP_DIR, build, start"
fi

cat <<SUMMARY

------------------------------------------------------------
  Base        : $BASE
  Action      : $ACTION
  Repo        : $REPO_URL ($BRANCH)
  pm2 app     : $APP_NAME on port $PORT
  Node        : $NODE_VERSION
------------------------------------------------------------
SUMMARY
CONFIRM=""
read -rp "Proceed? [y/N] " CONFIRM || true
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

load_node
ensure_pm2
git_auth
env_step
get_code
COMMIT="$(git -C "$APP_DIR" rev-parse --short HEAD)"

if ! build_in "$APP_DIR"; then
  log_deploy "build-fail" "$COMMIT"
  c_die "Build failed at commit $COMMIT - fix it and rerun $0 (visitors see the maintenance page if the app is down)."
fi

if ! start_app "$APP_DIR"; then
  log_deploy "start-fail" "$COMMIT"
  c_die "The app is not answering on port $PORT - see: pm2 logs $APP_NAME"
fi
log_deploy "ok" "$COMMIT"

cat <<DONE

============================================================
  DEPLOY COMPLETE
  Commit    : $COMMIT ($BRANCH)
  Code      : $APP_DIR
  Site      : https://$DOMAIN  (or http:// if SSL was skipped)
  Logs      : pm2 logs $APP_NAME
  History   : $BASE/deploy.log
============================================================
DONE
