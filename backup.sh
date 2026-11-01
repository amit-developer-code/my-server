#!/usr/bin/env bash
#
# backup.sh - Back up the MongoDB databases on this server.
#
# Dumps every app database (or only those given with -d) together with its
# users, so after a restore the apps' existing MONGODB_URI values keep working.
# The admin user is not part of the backup - the new server keeps its own.
#
# Writes one file: ~/backups/mongo-backup-HOST-DATE.tar (chmod 600) holding
#   dump/<db>/         mongodump output per database (gzipped, incl. its users)
#   databases.txt      collections + document counts, to compare after a restore
#   credentials.txt    copy of ~/mongo-credentials.txt (the app URIs)
#   RESTORE.txt        restore commands
# It holds passwords - keep it private, or use --encrypt.
#
# Usage:
#   ./backup.sh                          # all app databases, keep the last 7 backups
#   ./backup.sh -d shop -d blog          # only these databases
#   ./backup.sh --encrypt                # gpg-encrypt with a passphrase
#   ./backup.sh --to ubuntu@1.2.3.4:~    # also copy it to another server
#
# Cron (daily at 03:00):
#   0 3 * * * /home/ubuntu/myserver/backup.sh >> /home/ubuntu/backups/backup.log 2>&1
# With --encrypt in cron, set BACKUP_PASSPHRASE in the crontab line.
#
# Run as the user that ran mongo-setup.sh (its ~/mongo-credentials.txt holds
# the admin login), or point at that file with --cred. No sudo needed.

set -euo pipefail

CRED_FILE="$HOME/mongo-credentials.txt"
OUT_DIR="$HOME/backups"
KEEP="7"
DEST=""
ENCRYPT="false"
DBS=()

# ---------------------------------------------------------------- helpers ---
c_info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
c_ok()    { printf '\033[1;32m  [OK] %s\033[0m\n' "$*"; }
c_warn()  { printf '\033[1;33m  [!!] %s\033[0m\n' "$*"; }
c_die()   { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# need OPTION VALUE - fail clearly when a flag is missing its value.
need() { [[ -n "${2:-}" && "$2" != -* ]] || c_die "Option $1 needs a value (see --help)."; }

# mongo_js - run JavaScript from stdin in mongosh (connects itself via new Mongo()).
# Goes through a chmod 600 temp file so passwords never appear in `ps`.
mongo_js() {
  local tmp rc=0
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  cat > "$tmp"
  mongosh --nodb --quiet --file "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

usage() {
  cat <<USAGE
Usage: $0 [options]
  -d, --db NAME        back up only this database (repeat for more; default: all app databases)
  -c, --cred FILE      credentials file with ADMIN_URI= (default: ~/mongo-credentials.txt)
  -o, --out DIR        where to write the backup (default: ~/backups)
  -k, --keep N         keep the newest N backups in DIR, delete older (default: $KEEP)
      --to DEST        also copy the backup with scp, e.g. ubuntu@1.2.3.4:~
      --encrypt        encrypt with gpg (passphrase asked, or from BACKUP_PASSPHRASE)
  -h, --help           show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--db)   need "$1" "${2:-}"; DBS+=("$2");     shift 2 ;;
    -c|--cred) need "$1" "${2:-}"; CRED_FILE="$2";  shift 2 ;;
    -o|--out)  need "$1" "${2:-}"; OUT_DIR="$2";    shift 2 ;;
    -k|--keep) need "$1" "${2:-}"; KEEP="$2";       shift 2 ;;
    --to)      need "$1" "${2:-}"; DEST="$2";       shift 2 ;;
    --encrypt) ENCRYPT="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) c_die "Unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ sanity check ---
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || c_die "--keep must be a number >= 1 (got '$KEEP')."
[[ "$OUT_DIR" == /* ]] || c_die "--out must be an absolute path (got '$OUT_DIR')."
OUT_DIR="${OUT_DIR%/}"
for db in "${DBS[@]}"; do
  [[ "$db" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || c_die "'$db' is not a valid database name."
done

command -v mongodump >/dev/null 2>&1 || c_die "mongodump not found (sudo apt-get install -y mongodb-database-tools)."
command -v mongosh   >/dev/null 2>&1 || c_die "mongosh not found (sudo apt-get install -y mongodb-mongosh)."

[[ -r "$CRED_FILE" ]] || c_die "$CRED_FILE not found or not readable - run as the user that ran mongo-setup.sh, or pass --cred FILE."
ADMIN_URI="$(grep -E '^ADMIN_URI=' "$CRED_FILE" | tail -n 1 | cut -d= -f2- || true)"
[[ -n "$ADMIN_URI" ]] \
  || c_die "No ADMIN_URI= line in $CRED_FILE. Add one: ADMIN_URI=mongodb://admin:PASSWORD@127.0.0.1:27017/admin?authSource=admin"
# mongodump refuses --db when the URI names a different database, so drop
# the /admin path (authSource=admin stays in the query string).
DUMP_URI="$(sed -E 's#^(mongodb(\+srv)?://[^/?]+)/[^?]*#\1/#' <<<"$ADMIN_URI")"

PASSPHRASE=""
if [[ "$ENCRYPT" == "true" ]]; then
  command -v gpg >/dev/null 2>&1 || c_die "gpg is not installed (sudo apt-get install -y gnupg)."
  PASSPHRASE="${BACKUP_PASSPHRASE:-}"
  if [[ -z "$PASSPHRASE" ]]; then
    [[ -t 0 ]] || c_die "--encrypt needs BACKUP_PASSPHRASE when there is no terminal."
    PASS2=""
    read -rsp "Backup passphrase (hidden): " PASSPHRASE; echo
    read -rsp "Repeat passphrase: " PASS2; echo
    [[ -n "$PASSPHRASE" ]] || c_die "Passphrase is required."
    [[ "$PASSPHRASE" == "$PASS2" ]] || c_die "Passphrases do not match."
  fi
fi

# ----------------------------------------------------------- database list ---
ALL_DBS="$(mongo_js <<JS
const a = new Mongo("$ADMIN_URI").getDB("admin");
a.adminCommand({ listDatabases: 1, nameOnly: true }).databases
  .map(d => d.name).filter(n => !["admin", "local", "config"].includes(n))
  .forEach(n => print(n));
JS
)" || c_die "Cannot connect to MongoDB - is mongod running (sudo systemctl status mongod)? Is ADMIN_URI in $CRED_FILE correct?"

if (( ${#DBS[@]} )); then
  for db in "${DBS[@]}"; do
    grep -qxF "$db" <<<"$ALL_DBS" || c_die "Database '$db' does not exist. Databases here: $(paste -sd' ' <<<"$ALL_DBS")"
  done
else
  mapfile -t DBS < <(grep -v '^$' <<<"$ALL_DBS" || true)
fi
(( ${#DBS[@]} )) || c_die "No app databases found (admin/local/config are never backed up)."

HOST="$(hostname -s 2>/dev/null || hostname)"
NAME="mongo-backup-$HOST-$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/$NAME.tar"
[[ "$ENCRYPT" == "true" ]] && OUT="$OUT.gpg"

cat <<SUMMARY

------------------------------------------------------------
  Databases   : ${DBS[*]}
  Output      : $OUT
  Encrypted   : $ENCRYPT
  Keep        : newest $KEEP backups
------------------------------------------------------------
SUMMARY

# ------------------------------------------------------------- staging dir ---
umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# Only one backup at a time.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$OUT_DIR/.backup.lock"
  flock -n 9 || c_die "Another backup is already running (lock: $OUT_DIR/.backup.lock)."
fi

# Staged next to the output, not in /tmp (which may be small or in RAM).
STAGE="$(mktemp -d "$OUT_DIR/.staging.XXXXXX")"
cleanup() { rm -rf -- "$STAGE" "$OUT.part"; }
trap cleanup EXIT
mkdir -p "$STAGE/dump"

# Passed through a chmod 600 config file so the password never appears in `ps`.
printf 'uri: "%s"\n' "$DUMP_URI" > "$STAGE/.mongodump.yaml"

# ----------------------------------------------------------------- 1. dump ---
c_info "1/3  Dumping ${#DBS[@]} database(s)"
for db in "${DBS[@]}"; do
  mongodump --config="$STAGE/.mongodump.yaml" --db="$db" --dumpDbUsersAndRoles \
    --gzip --out="$STAGE/dump" --quiet \
    || c_die "mongodump of '$db' failed - check: df -h $OUT_DIR"
  c_ok "$db  $(du -sh "$STAGE/dump/$db" | cut -f1)"
done
rm -f "$STAGE/.mongodump.yaml"

# ----------------------------------------------------------------- 2. info ---
c_info "2/3  Writing databases.txt and RESTORE.txt"
DB_JSON="$(printf '"%s",' "${DBS[@]}")"
mongo_js > "$STAGE/databases.txt" <<JS || c_warn "Could not list collections (the dump itself is fine)."
const conn = new Mongo("$ADMIN_URI");
print("MongoDB " + conn.getDB("admin").version() + " on $HOST, $(date '+%F %T %Z')");
[${DB_JSON%,}].forEach(name => {
  const d = conn.getDB(name);
  print("");
  print("database " + name);
  d.getCollectionInfos({ type: "collection" }).map(c => c.name).sort().forEach(c =>
    print("  " + c.padEnd(40) + d.getCollection(c).estimatedDocumentCount() + " docs"));
  d.getUsers().users.forEach(u => print("  user: " + u.user));
});
JS
cp "$CRED_FILE" "$STAGE/credentials.txt"

FILE_NAME="$(basename "$OUT")"
UNPACK="tar -xf ~/$FILE_NAME -C ~/mongo-restore"
[[ "$ENCRYPT" == "true" ]] && UNPACK="gpg -d ~/$FILE_NAME | tar -x -C ~/mongo-restore"

cat > "$STAGE/RESTORE.txt" <<RESTORE
MongoDB backup of $HOST taken $(date '+%F %T %Z')
Databases: ${DBS[*]}

Each dump/<db> folder holds the data and that database's own users, so the
apps' old MONGODB_URI (in credentials.txt) works again after the restore.

On the new server:

 1. Install MongoDB (creates the admin login in ~/mongo-credentials.txt).
    Give it one of the database names above:
      ./mongo-setup.sh -d ${DBS[0]}

 2. Unpack the backup:
      mkdir -p ~/mongo-restore && $UNPACK

 3. Restore every database with its users (--drop replaces what is there,
    including the user mongo-setup.sh just made):
      URI="\$(grep ^ADMIN_URI= ~/mongo-credentials.txt | tail -n 1 | cut -d= -f2- | sed -E 's#^(mongodb://[^/?]+)/[^?]*#\1/#')"
      for d in ~/mongo-restore/dump/*/; do
        mongorestore --uri "\$URI" --db "\$(basename "\$d")" --gzip --drop --restoreDbUsersAndRoles "\$d"
      done

 4. Compare with databases.txt (collections + document counts), and put the
    old MONGODB_URI lines from credentials.txt into each app's .env.

Restore into this same server works the same way (skip step 1).
RESTORE
c_ok "done"

# ----------------------------------------------------------------- 3. pack ---
# Dump files are already gzipped, so the outer tar is not compressed again.
c_info "3/3  Writing $OUT"
if [[ "$ENCRYPT" == "true" ]]; then
  tar -cf - -C "$STAGE" . \
    | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
        --symmetric --cipher-algo AES256 -o "$OUT.part" 3<<<"$PASSPHRASE" \
    || c_die "Writing the encrypted backup failed - check: df -h $OUT_DIR"
else
  tar -cf "$OUT.part" -C "$STAGE" . || c_die "Writing the backup failed - check: df -h $OUT_DIR"
  tar -tf "$OUT.part" >/dev/null || c_die "The new backup file is unreadable - not keeping it."
fi
mv -f "$OUT.part" "$OUT"
chmod 600 "$OUT"
c_ok "$(du -h "$OUT" | cut -f1)  $OUT"

# Keep the newest KEEP backups.
while IFS= read -r old; do
  [[ -n "$old" ]] || continue
  rm -f -- "$old"
  c_ok "deleted old backup $(basename "$old")"
done < <(find "$OUT_DIR" -maxdepth 1 -type f -name 'mongo-backup-*.tar*' ! -name '*.part' -printf '%T@ %p\n' \
           | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)

if [[ -n "$DEST" ]]; then
  c_info "Copying to $DEST"
  if scp "$OUT" "$DEST"; then
    c_ok "copied to $DEST"
  else
    c_warn "scp to $DEST failed - the backup is still at $OUT"
  fi
fi

READ_GUIDE="tar -xOf $FILE_NAME ./RESTORE.txt"
[[ "$ENCRYPT" == "true" ]] && READ_GUIDE="gpg -d $FILE_NAME | tar -xO ./RESTORE.txt"

cat <<DONE

============================================================
  MONGODB BACKUP COMPLETE
  Databases : ${DBS[*]}
  File      : $OUT
  Contains  : data + database passwords - keep it private
  To your PC: scp $(id -un)@<server-ip>:$OUT .
  Restore   : $READ_GUIDE
============================================================
DONE
