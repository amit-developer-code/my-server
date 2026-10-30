#!/usr/bin/env bash
#
# nest-deploy.sh - Deploy a NestJS app from Git into versioned release folders.
#
# Reads its settings from deploy.conf (written by server-setup.sh) in the base
# folder. Layout:
#
#   /var/www/api.example.com/
#     deploy.conf
#     shared/.env               saved .env (chmod 600), copied into each release as .env
#     release-1.1/
#     release-1.2/
#     current -> release-1.2    the release pm2 is running
#
# The app gets PORT from deploy.conf as an env var (overrides PORT in .env), so
# main.ts must listen on process.env.PORT.
#
# Optional deploy.conf keys (add by hand):
#   START_MODE="node"           node = run 'node ENTRY' (default); script = run package.json "start:prod"
#   ENTRY="dist/main.js"        build output started in node mode (default)
#
# Usage:
#   ./nest-deploy.sh --release 1.2     clone + fresh build into release-1.2, switch to it
#   ./nest-deploy.sh                   update the live release in place (pull, delete dist, rebuild)
#   ./nest-deploy.sh --rollback 1.1    switch back to an existing release
#   ./nest-deploy.sh --list            show releases
#   ./nest-deploy.sh --dir /srv/api    base folder, if it cannot be auto-detected
#
# Run on the server as the same user that ran server-setup.sh (root or a
# normal user) - that user owns deploy.conf and has nvm/Node installed.

set -euo pipefail

MODE="update"
VERSION=""
BASE=""

# deploy.conf keys and their defaults.
CONF_KEYS="DOMAIN PORT NODE_VERSION APP_NAME REPO_URL BRANCH KEEP_RELEASES START_MODE ENTRY"
DOMAIN=""
PORT=""
NODE_VERSION=""
APP_NAME=""
REPO_URL=""
BRANCH="main"
KEEP_RELEASES="5"
START_MODE="node"
ENTRY="dist/main.js"

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

set_mode() {
  [[ "$MODE" == "update" ]] || c_die "Use only one of --release, --rollback, --list."
  MODE="$1"
}

usage() {
  cat <<USAGE
Usage: $0 [options]
      --release VERSION    clone + fresh build into release-VERSION and switch to it
      --rollback VERSION   switch back to the existing release-VERSION
      --list               list releases
      --dir PATH           base folder containing deploy.conf
  -h, --help               show this help
No option: update the live release in place (git pull, delete dist, rebuild).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)  need "$1" "${2:-}"; set_mode "release";  VERSION="$2"; shift 2 ;;
    --rollback) need "$1" "${2:-}"; set_mode "rollback"; VERSION="$2"; shift 2 ;;
    --list)     set_mode "list"; shift ;;
    --dir)      need "$1" "${2:-}"; BASE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) c_die "Unknown option: $1" ;;
  esac
done

if [[ -n "$VERSION" ]]; then
  [[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || c_die "'$VERSION' is not a valid version (letters, digits, . _ -)."
fi

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
[[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || c_die "deploy.conf: KEEP_RELEASES must be a number >= 1."
[[ "$START_MODE" == "node" || "$START_MODE" == "script" ]] || c_die "deploy.conf: START_MODE must be \"node\" or \"script\"."
[[ "$ENTRY" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*\.c?js$ && "$ENTRY" != *..* ]] \
  || c_die "deploy.conf: ENTRY '$ENTRY' must be a relative .js path inside the project (e.g. dist/main.js)."

SHARED="$BASE/shared"
ENV_FILE="$SHARED/.env"
LIVE="$(readlink -f "$BASE/current" 2>/dev/null || true)"
[[ -d "$LIVE" ]] || LIVE=""

# Only one deploy at a time per base folder.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BASE/.deploy.lock"
  flock -n 9 || c_die "Another deploy is already running for $BASE."
fi

# --------------------------------------------------------------- functions ---
list_releases() {
  local d name info
  echo "Releases in $BASE (newest first):"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    name="${d##*/release-}"
    info=""
    [[ -f "$d/.release-info" ]] && info="$(grep -E '^(commit|built)=' "$d/.release-info" | cut -d= -f2- | paste -sd' ' - || true)"
    if [[ "$d" == "$LIVE" ]]; then
      printf '  * %-15s %s  (live)\n' "$name" "$info"
    else
      printf '    %-15s %s\n' "$name" "$info"
    fi
  done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -name 'release-*' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

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

# build_in DIR - copy .env, install deps, delete dist and build.
# Called from `if`, where set -e is off, so every step checks its own result.
build_in() {
  local dir="$1"
  cd "$dir" || return 1
  [[ -f package.json ]] || { c_warn "No package.json in $dir"; return 1; }
  # @nestjs/config reads .env from the working directory by default.
  install -m 600 "$ENV_FILE" "$dir/.env" || return 1
  detect_pm "$dir" || return 1
  c_info "Installing dependencies (${INSTALL[*]})"
  "${INSTALL[@]}" || return 1
  c_info "Deleting old dist and building ($PM run build)"
  rm -rf dist || return 1
  "$PM" run build || return 1
  if [[ ! -f "$ENTRY" ]]; then
    c_warn "Build finished but $ENTRY is missing."
    [[ -f dist/src/main.js ]] && c_warn "Found dist/src/main.js - set ENTRY=\"dist/src/main.js\" in $CONF."
    return 1
  fi
}

write_info() {  # DIR VERSION
  local commit
  commit="$(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'version=%s\nbranch=%s\ncommit=%s\nbuilt=%s\n' "$2" "$BRANCH" "$commit" "$(date '+%F %T')" > "$1/.release-info"
}

switch_current() {  # DIR - atomic symlink swap
  ln -sfn "$1" "$BASE/current.tmp"
  mv -Tf "$BASE/current.tmp" "$BASE/current"
  LIVE="$1"
  c_ok "current -> $(basename "$1")"
}

# start_app DIR - (re)start pm2 on DIR and wait for the app to answer.
start_app() {
  local dir="$1" code="000" i
  c_info "Starting $APP_NAME on port $PORT"
  pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  if [[ "$START_MODE" == "script" ]]; then
    detect_pm "$dir" || return 1
    PORT="$PORT" pm2 start "$PM" --name "$APP_NAME" --cwd "$dir" -- run start:prod || return 1
  else
    if [[ ! -f "$dir/$ENTRY" ]]; then
      c_warn "$dir/$ENTRY not found - check ENTRY in $CONF."
      return 1
    fi
    PORT="$PORT" pm2 start "$dir/$ENTRY" --name "$APP_NAME" --cwd "$dir" || return 1
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

prune_releases() {
  local old
  find "$BASE" -mindepth 1 -maxdepth 1 -type d -name 'release-*' -printf '%T@ %p\n' \
    | sort -rn | tail -n +"$((KEEP_RELEASES + 1))" | cut -d' ' -f2- \
    | while IFS= read -r old; do
        [[ -n "$old" && "$old" != "$LIVE" ]] || continue
        rm -rf -- "$old" && c_ok "removed old release $(basename "$old")"
      done
}

log_deploy() {  # RESULT DETAIL
  printf '%s  %-8s %-14s %s\n' "$(date '+%F %T')" "$MODE" "$1" "$2" >> "$BASE/deploy.log"
}

# ------------------------------------------------------------------- main ---
if [[ "$MODE" == "list" ]]; then
  list_releases
  exit 0
fi

case "$MODE" in
  release)
    TARGET="$BASE/release-$VERSION"
    [[ -e "$TARGET" ]] && c_die "$TARGET already exists - pick a new version (see --list)."
    ACTION="new release release-$VERSION (fresh clone + build)"
    ensure_repo_url ;;
  update)
    [[ -n "$LIVE" ]] || c_die "No live release yet. First deploy: $0 --release 1.0"
    TARGET="$LIVE"
    ACTION="update $(basename "$LIVE") in place (site may error during the build)"
    ensure_repo_url ;;
  rollback)
    TARGET="$BASE/release-$VERSION"
    [[ -f "$TARGET/$ENTRY" ]] || c_die "release-$VERSION not found or never built (see --list)."
    [[ "$TARGET" == "$LIVE" ]] && c_die "release-$VERSION is already live."
    ACTION="roll back to release-$VERSION" ;;
esac

LIVE_NAME="(none)"
[[ -n "$LIVE" ]] && LIVE_NAME="$(basename "$LIVE")"

cat <<SUMMARY

------------------------------------------------------------
  Base        : $BASE
  Action      : $ACTION
  Live now    : $LIVE_NAME
  Repo        : ${REPO_URL:-(not needed)} ($BRANCH)
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
PREV="$LIVE"

if [[ "$MODE" == "rollback" ]]; then
  switch_current "$TARGET"
  if start_app "$TARGET"; then
    log_deploy "ok" "release-$VERSION"
    c_ok "rolled back to release-$VERSION"
  else
    log_deploy "start-fail" "release-$VERSION"
    c_die "release-$VERSION did not start cleanly."
  fi
  exit 0
fi

git_auth
env_step

if [[ "$MODE" == "release" ]]; then
  c_info "Cloning $BRANCH into $(basename "$TARGET")"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET" || { rm -rf "$TARGET"; c_die "git clone failed."; }
  if ! build_in "$TARGET"; then
    rm -rf "$TARGET"
    log_deploy "build-fail" "release-$VERSION"
    c_die "Build failed - live site untouched, removed $(basename "$TARGET")."
  fi
  write_info "$TARGET" "$VERSION"
  switch_current "$TARGET"
  if start_app "$TARGET"; then
    log_deploy "ok" "release-$VERSION $(git -C "$TARGET" rev-parse --short HEAD)"
    prune_releases
  else
    log_deploy "start-fail" "release-$VERSION"
    [[ -n "$PREV" ]] && c_warn "Roll back with: $0 --rollback ${PREV##*/release-}"
    c_die "release-$VERSION is live but not answering."
  fi
else
  c_info "Pulling latest $BRANCH into $(basename "$TARGET")"
  cd "$TARGET"
  git fetch --depth 1 origin "$BRANCH" || c_die "git fetch failed - live site untouched."
  git reset --hard FETCH_HEAD
  c_warn "Building in place - the site may show errors until the build finishes."
  if ! build_in "$TARGET"; then
    log_deploy "build-fail" "$(basename "$TARGET")"
    c_die "Build failed - $(basename "$TARGET") is now broken. Fix and rerun, or: $0 --rollback <older version> (see --list)"
  fi
  write_info "$TARGET" "${TARGET##*/release-}"
  if start_app "$TARGET"; then
    log_deploy "ok" "$(basename "$TARGET") $(git -C "$TARGET" rev-parse --short HEAD)"
  else
    log_deploy "start-fail" "$(basename "$TARGET")"
    c_die "$(basename "$TARGET") is not answering after the update."
  fi
fi

cat <<DONE

============================================================
  DEPLOY COMPLETE
  Live      : $(basename "$LIVE")  ($(git -C "$LIVE" rev-parse --short HEAD))
  Site      : https://$DOMAIN  (or http:// if SSL was skipped)
  Logs      : pm2 logs $APP_NAME
  Releases  : $0 --list
  History   : $BASE/deploy.log
============================================================
DONE
