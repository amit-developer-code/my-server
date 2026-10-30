#!/usr/bin/env bash
#
# mongo-setup.sh - Install MongoDB on this Ubuntu server and create users.
#
# First run : installs MongoDB (official apt repo), keeps it on 127.0.0.1 only,
#             creates an admin user, turns on authentication, and creates one
#             app user limited to one database.
# Next runs : MongoDB is already installed - only asks for a new database name
#             and creates an app user for it (uses the saved admin password).
#
# Passwords are generated, printed once, and saved in ~/mongo-credentials.txt
# (chmod 600). Put the printed MONGODB_URI into your app's .env.
#
# Usage:
#   ./mongo-setup.sh                         # asks for every value
#   ./mongo-setup.sh -m 8.0 -d myapp -u myapp_user
#
# Run as a normal user WITH sudo rights (NOT as root).

set -euo pipefail

DEFAULT_MONGO_VERSION="8.0"
DEFAULT_ADMIN_USER="admin"
CRED_FILE="$HOME/mongo-credentials.txt"
MONGOD_CONF="/etc/mongod.conf"
LOCAL_URI="mongodb://127.0.0.1:27017/admin"

# Empty = not given as a flag, so the user is asked for it.
MONGO_VERSION=""
DB_NAME=""
DB_USER=""

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

# 32 random letters/digits - safe inside a connection string without escaping.
gen_pw() {
  local p
  p="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  printf '%s' "${p:0:32}"
}

# mongo_js - run JavaScript from stdin in mongosh against the local server.
# Goes through a chmod 600 temp file so passwords never appear in `ps`.
mongo_js() {
  local tmp rc=0
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  cat > "$tmp"
  mongosh --quiet "$LOCAL_URI" --file "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

wait_for_mongo() {
  local i
  for i in $(seq 1 30); do
    if mongosh --quiet "$LOCAL_URI" --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null | grep -q '^1$'; then
      return 0
    fi
    sleep 1
  done
  c_die "MongoDB did not start within 30s - check: sudo journalctl -u mongod -n 50"
}

cred_get() {  # KEY - read a value from the credentials file
  [[ -f "$CRED_FILE" ]] || return 0
  grep -E "^$1=" "$CRED_FILE" | tail -n 1 | cut -d= -f2- || true
}

usage() {
  cat <<USAGE
Usage: $0 [options]
  -m, --mongo-version VER   MongoDB version for a new install (default: $DEFAULT_MONGO_VERSION)
  -d, --db NAME             database for the app user
  -u, --user NAME           app user name (default: NAME_user)
  -h, --help                show this help
Anything not passed is asked for interactively.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mongo-version) need "$1" "${2:-}"; MONGO_VERSION="$2"; shift 2 ;;
    -d|--db)            need "$1" "${2:-}"; DB_NAME="$2";       shift 2 ;;
    -u|--user)          need "$1" "${2:-}"; DB_USER="$2";       shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) c_die "Unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ sanity check ---
[[ $EUID -eq 0 ]] && c_die "Do not run as root/sudo. Run as your normal user; the script calls sudo where needed."
command -v sudo >/dev/null 2>&1 || c_die "sudo is not installed."
[[ -f /etc/os-release ]] || c_die "Cannot detect the OS (/etc/os-release missing)."
OS_ID="$(. /etc/os-release && echo "${ID:-}")"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
[[ "$OS_ID" == "ubuntu" && -n "$CODENAME" ]] || c_die "This script supports Ubuntu only (found '$OS_ID')."

INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' mongodb-org 2>/dev/null || true)"
AUTH_ON="false"
if [[ -f "$MONGOD_CONF" ]] && grep -qE '^[[:space:]]+authorization:[[:space:]]*enabled' "$MONGOD_CONF"; then
  AUTH_ON="true"
fi

if [[ -z "$INSTALLED_VERSION" ]]; then
  ask MONGO_VERSION "MongoDB version" "$DEFAULT_MONGO_VERSION"
  [[ "$MONGO_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || c_die "'$MONGO_VERSION' is not a version like 8.0."

  # MongoDB 5.0+ needs AVX on x86_64; without it mongod crashes on start.
  if [[ "$(uname -m)" == "x86_64" ]] && ! grep -qw avx /proc/cpuinfo; then
    c_die "This CPU has no AVX support, which MongoDB 5.0+ requires on x86_64. Use a server/VPS plan with AVX."
  fi

  # Check MongoDB publishes this version for this Ubuntu release before changing anything.
  command -v curl >/dev/null 2>&1 || c_die "curl is not installed (run server-setup.sh first, or: sudo apt-get install -y curl)."
  REPO_RELEASE="https://repo.mongodb.org/apt/ubuntu/dists/$CODENAME/mongodb-org/$MONGO_VERSION/Release"
  curl -fsS -o /dev/null "$REPO_RELEASE" 2>/dev/null \
    || c_die "MongoDB $MONGO_VERSION has no package for Ubuntu '$CODENAME' (checked $REPO_RELEASE). Try another version."
  ACTION="install MongoDB $MONGO_VERSION, create admin, enable auth, create app user"
else
  if [[ "$AUTH_ON" == "true" ]]; then
    ACTION="MongoDB $INSTALLED_VERSION already installed - add an app user"
  else
    ACTION="MongoDB $INSTALLED_VERSION already installed - create admin, enable auth, create app user"
  fi
fi

ask DB_NAME "Database name for the app (e.g. myapp)"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || c_die "Database name may use letters, digits, _ and - (max 63 chars)."
[[ "$DB_NAME" == "admin" || "$DB_NAME" == "local" || "$DB_NAME" == "config" ]] && c_die "'$DB_NAME' is a MongoDB system database - pick another name."
ask DB_USER "App user name" "${DB_NAME}_user"
[[ "$DB_USER" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || c_die "User name may use letters, digits, _ . and -."

cat <<SUMMARY

------------------------------------------------------------
  Ubuntu      : $CODENAME
  Action      : $ACTION
  Listens on  : 127.0.0.1:27017 (not reachable from the internet)
  App DB/user : $DB_NAME / $DB_USER (readWrite on $DB_NAME only)
  Credentials : $CRED_FILE
------------------------------------------------------------
SUMMARY
CONFIRM=""
read -rp "Proceed? [y/N] " CONFIRM || true
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

sudo -v || c_die "sudo authentication failed."

# ------------------------------------------------------------- 1. install ---
if [[ -z "$INSTALLED_VERSION" ]]; then
  c_info "1/4  Installing MongoDB $MONGO_VERSION"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg curl openssl
  curl -fsSL "https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc" \
    | sudo gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg"
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu $CODENAME/mongodb-org/$MONGO_VERSION multiverse" \
    | sudo tee "/etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list" >/dev/null
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org
  INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' mongodb-org)"
  c_ok "MongoDB $INSTALLED_VERSION installed"
else
  c_info "1/4  MongoDB $INSTALLED_VERSION already installed - skipping install"
fi

sudo systemctl enable --now mongod >/dev/null 2>&1 || sudo systemctl start mongod
wait_for_mongo
c_ok "mongod running and enabled at boot"

# Must stay local-only; the apps connect via 127.0.0.1.
BIND_IP="$(grep -E '^[[:space:]]*bindIp:' "$MONGOD_CONF" | awk '{print $2}' || true)"
if [[ "$BIND_IP" != "127.0.0.1" ]]; then
  c_warn "bindIp in $MONGOD_CONF is '${BIND_IP:-not set}', not 127.0.0.1 - MongoDB may be reachable from outside."
fi

# --------------------------------------------------- 2. admin user + auth ---
ADMIN_USER="$(cred_get ADMIN_USER)"
ADMIN_PASSWORD="$(cred_get ADMIN_PASSWORD)"

if [[ "$AUTH_ON" != "true" ]]; then
  c_info "2/4  Creating admin user and enabling authentication"
  ADMIN_SAVED="true"
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_SAVED="false"
    ADMIN_USER="$DEFAULT_ADMIN_USER"
    ADMIN_PASSWORD="$(gen_pw)"
  fi
  rc=0
  mongo_js <<JS || rc=$?
const admin = db.getSiblingDB("admin");
if (admin.getUser("$ADMIN_USER")) {
  quit(3);
}
admin.createUser({ user: "$ADMIN_USER", pwd: "$ADMIN_PASSWORD", roles: [{ role: "root", db: "admin" }] });
JS
  if (( rc == 3 )) && [[ "$ADMIN_SAVED" == "true" ]]; then
    # An earlier run created it but stopped before enabling auth.
    c_ok "admin user '$ADMIN_USER' already exists (password from $CRED_FILE)"
  elif (( rc == 3 )); then
    c_die "Admin user '$ADMIN_USER' already exists and its password is not in $CRED_FILE. Add ADMIN_USER=/ADMIN_PASSWORD= lines there, then rerun."
  elif (( rc != 0 )); then
    c_die "Creating the admin user failed."
  fi

  # Save before restarting, so the password is never lost.
  umask 077
  if [[ "$ADMIN_SAVED" == "false" ]]; then
    if [[ ! -f "$CRED_FILE" ]]; then
      printf '# MongoDB credentials - written by mongo-setup.sh. Keep this file private.\n' > "$CRED_FILE"
    fi
    printf 'ADMIN_USER=%s\nADMIN_PASSWORD=%s\nADMIN_URI=mongodb://%s:%s@127.0.0.1:27017/admin?authSource=admin\n' \
      "$ADMIN_USER" "$ADMIN_PASSWORD" "$ADMIN_USER" "$ADMIN_PASSWORD" >> "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    c_ok "admin user '$ADMIN_USER' created (saved in $CRED_FILE)"
  fi

  sudo cp "$MONGOD_CONF" "$MONGOD_CONF.bak.$(date +%Y%m%d%H%M%S)"
  if grep -qE '^[[:space:]]+authorization:' "$MONGOD_CONF"; then
    sudo sed -i -E 's/^([[:space:]]+authorization:).*/\1 enabled/' "$MONGOD_CONF"
  elif grep -qE '^security:' "$MONGOD_CONF"; then
    sudo sed -i '/^security:/a\  authorization: enabled' "$MONGOD_CONF"
  else
    printf '\nsecurity:\n  authorization: enabled\n' | sudo tee -a "$MONGOD_CONF" >/dev/null
  fi
  sudo systemctl restart mongod
  wait_for_mongo
  AUTH_ON="true"
  c_ok "authentication enabled (backup of the old config next to $MONGOD_CONF)"
else
  c_info "2/4  Authentication already enabled"
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    [[ -t 0 ]] || c_die "Admin password not in $CRED_FILE and no terminal to ask for it."
    ask ADMIN_USER "MongoDB admin user" "$DEFAULT_ADMIN_USER"
    read -rsp "MongoDB admin password (hidden): " ADMIN_PASSWORD; echo
    [[ -n "$ADMIN_PASSWORD" ]] || c_die "Admin password is required."
  fi
  c_ok "using admin user '$ADMIN_USER'"
fi

# Check the admin login before going further.
mongo_js <<JS >/dev/null || c_die "Admin login failed - check ADMIN_USER/ADMIN_PASSWORD in $CRED_FILE."
db.getSiblingDB("admin").auth("$ADMIN_USER", "$ADMIN_PASSWORD");
db.getSiblingDB("admin").runCommand({ listDatabases: 1, nameOnly: true });
JS

# ------------------------------------------------------------ 3. app user ---
c_info "3/4  Creating app user '$DB_USER' on database '$DB_NAME'"
APP_PASSWORD="$(gen_pw)"
rc=0
mongo_js <<JS || rc=$?
db.getSiblingDB("admin").auth("$ADMIN_USER", "$ADMIN_PASSWORD");
const appDb = db.getSiblingDB("$DB_NAME");
if (appDb.getUser("$DB_USER")) {
  quit(3);
}
appDb.createUser({ user: "$DB_USER", pwd: "$APP_PASSWORD", roles: [{ role: "readWrite", db: "$DB_NAME" }] });
JS
if (( rc == 3 )); then
  c_die "User '$DB_USER' already exists on '$DB_NAME' - pick another user name (or use the URI already in $CRED_FILE)."
elif (( rc != 0 )); then
  c_die "Creating the app user failed."
fi

APP_URI="mongodb://$DB_USER:$APP_PASSWORD@127.0.0.1:27017/$DB_NAME?authSource=$DB_NAME"
umask 077
printf '# %s  database %s\nMONGODB_URI_%s=%s\n' "$(date '+%F %T')" "$DB_NAME" "$DB_NAME" "$APP_URI" >> "$CRED_FILE"
chmod 600 "$CRED_FILE"
c_ok "app user created (saved in $CRED_FILE)"

# -------------------------------------------------------------- 4. verify ---
c_info "4/4  Verifying the app user can log in"
mongo_js <<JS >/dev/null || c_die "App user login failed - see $CRED_FILE and: sudo journalctl -u mongod -n 50"
const conn = new Mongo("$APP_URI");
conn.getDB("$DB_NAME").getCollectionNames();
JS
c_ok "app user login works"

cat <<DONE

============================================================
  MONGODB READY
  Version   : $INSTALLED_VERSION  (listening on 127.0.0.1:27017 only)
  Database  : $DB_NAME
  User      : $DB_USER  (readWrite on $DB_NAME only)

  Put this line in your app's .env (paste it when deploy asks):
    MONGODB_URI=$APP_URI

  All credentials : $CRED_FILE  (chmod 600)
  Admin shell     : mongosh "\$(grep ^ADMIN_URI= $CRED_FILE | cut -d= -f2-)"
  From your PC    : ssh -L 27017:127.0.0.1:27017 $USER@<server-ip>
                    then connect Compass to mongodb://localhost:27017 with the URI above
  Another app     : rerun ./mongo-setup.sh with a new database name
============================================================
DONE
