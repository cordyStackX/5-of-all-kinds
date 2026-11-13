#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/container-projects-avahi-${UID}"
PROJECTS=(
  "Auditrack"
  "PPGS-Asset-Management"
  "metric_supabase-app"
  "supabase-laco-ai"
  "supabase-laco-pos"
)
HOSTNAMES=(
  "app.laco.local"
  "lacobookstore-pos.local"
  "auditrack.local"
  "app.metric.local"
  "lccb.assetory.local"
  "kong.local"
  "lccb.local"
  "www.lccb.local"
)
HOSTS_ENTRIES=(
  "lccb.local"
  "kong.local"
  "kong"
  "app.laco.local"
  "auditrack.local"
  "lacobookstore-pos.local"
  "lccb.assetory.local"
  "app.metric.local"
)
NGINX_CONFIGS=(
  "auditrack.conf"
  "kong.conf"
  "lacobookstore.conf"
  "laco.conf"
  "lccb-home.conf"
  "metric.conf"
  "ppgs.conf"
)

usage() {
  cat <<'EOF'
Usage: ./start-all.sh [up|stop|down|status]
       ./start-all.sh --backup [PASSWORD]
       ./start-all.sh --import [PASSWORD]
       ./start-all.sh --tables --backup [PASSWORD]
       ./start-all.sh --tables --import

  up      Start all Compose projects and publish their .local hostnames (default)
  stop    Stop all Compose projects managed by this script and hostname publishers
  down    Alias for stop
  status  Show the state of each Compose project
  --backup  Create an AES-256 encrypted env-backup.zip
  --import  Restore every environment file from env-backup.zip
  --tables --backup  Create one encrypted ZIP containing all four Supabase database dumps
  --tables --import  Start the stacks, then offer an optional table restore
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ENV_ARCHIVE="$ROOT_DIR/env-backup.zip"
ENV_MANIFEST="$ROOT_DIR/env-files.list"
TABLE_DB_LABELS=("auditrack" "laco-ai" "metric" "lacobookstore-pos")
TABLE_DB_CONTAINERS=("auditrack-supabase-db" "supabase-db" "metric-supabase-db" "lacobookstore-pos-db")

read_password() {
  local prompt="$1" confirm="${2:-false}" password confirmation
  [[ -r /dev/tty ]] || die "No terminal available to read the backup password. Pass it as an argument."
  printf '%s' "$prompt" > /dev/tty
  IFS= read -r -s password < /dev/tty
  printf '\n' > /dev/tty
  [[ -n "$password" ]] || die "Password cannot be empty."
  if [[ "$confirm" == "true" ]]; then
    printf 'Confirm password: ' > /dev/tty
    IFS= read -r -s confirmation < /dev/tty
    printf '\n' > /dev/tty
    [[ "$password" == "$confirmation" ]] || die "Passwords do not match."
  fi
  REPLY="$password"
}

validate_env_path() {
  local path="$1"
  [[ "$path" != /* && "$path" != *".."* && ( "$path" == ".env" || "$path" == */.env || "$path" == ".env.local" || "$path" == */.env.local ) ]]
}

load_env_manifest() {
  [[ -f "$ENV_MANIFEST" ]] || die "Missing environment file manifest: $ENV_MANIFEST"
  mapfile -t ENV_PATHS < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$ENV_MANIFEST")
  ((${#ENV_PATHS[@]} > 0)) || die "The environment file manifest is empty."
  local path
  for path in "${ENV_PATHS[@]}"; do
    validate_env_path "$path" || die "Invalid path in env-files.list: $path"
  done
}

set_restored_file_owner() {
  local path="$1"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$path"
  fi
}

backup_env_files() {
  local password="$1" temp_dir actual_list merged_manifest archive_list path
  command -v 7z >/dev/null 2>&1 || die "7z is required for AES-256 ZIP encryption. Install the Debian 7zip package first."
  load_env_manifest
  for path in "${ENV_PATHS[@]}"; do
    [[ -f "$ROOT_DIR/$path" ]] || die "Cannot create a complete backup; required file is missing: $path"
  done

  temp_dir="$(mktemp -d "$ROOT_DIR/.env-backup.XXXXXX")"
  actual_list="$temp_dir/current-files.list"
  merged_manifest="$temp_dir/env-files.list"
  archive_list="$temp_dir/archive-files.list"
  (
    cd "$ROOT_DIR"
    find . -type d \( -name .git -o -name node_modules -o -name volumes \) -prune -o \
      -type f \( -name .env -o -name .env.local \) -print | sed 's#^\./##' | sort -u
  ) > "$actual_list" || { rm -rf "$temp_dir"; die "Could not scan environment files. Check directory permissions."; }
  cat "$ENV_MANIFEST" "$actual_list" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' | sort -u > "$merged_manifest"
  while IFS= read -r path; do
    validate_env_path "$path" || { rm -rf "$temp_dir"; die "Invalid environment file path: $path"; }
    [[ -f "$ROOT_DIR/$path" ]] || { rm -rf "$temp_dir"; die "Cannot back up missing environment file: $path"; }
  done < "$merged_manifest"

  cp "$merged_manifest" "$ENV_MANIFEST"
  cat "$merged_manifest" > "$archive_list"
  printf 'env-files.list\n' >> "$archive_list"
  (
    cd "$ROOT_DIR"
    7z a -tzip -mem=AES256 "-p$password" "$temp_dir/env-backup.zip" "@$archive_list" >/dev/null
  ) || { rm -rf "$temp_dir"; die "Could not create the encrypted ZIP archive."; }
  chmod 0600 "$temp_dir/env-backup.zip"
  mv -f "$temp_dir/env-backup.zip" "$ENV_ARCHIVE"
  chmod 0600 "$ENV_ARCHIVE"
  set_restored_file_owner "$ENV_ARCHIVE"
  rm -rf "$temp_dir"
  printf 'Encrypted backup created: %s (%s environment files)\n' "$ENV_ARCHIVE" "$(wc -l < "$ENV_MANIFEST" | tr -d '[:space:]')"
}

restore_env_files() {
  local password="$1" temp_dir path source_path target_path
  shift
  local paths=("$@")
  command -v 7z >/dev/null 2>&1 || die "7z is required to import the encrypted ZIP."
  [[ -f "$ENV_ARCHIVE" ]] || die "Backup archive not found: $ENV_ARCHIVE. Create it with --backup first."
  ((${#paths[@]} > 0)) || { printf 'All environment files already exist. Nothing to restore.\n'; return 0; }

  7z t "-p$password" "$ENV_ARCHIVE" >/dev/null 2>&1 || die "Could not open the backup ZIP. Check the password and archive."
  temp_dir="$(mktemp -d)"
  for path in "${paths[@]}"; do
    validate_env_path "$path" || { rm -rf "$temp_dir"; die "Invalid environment file path: $path"; }
    7z x -y "-p$password" "-o$temp_dir" "$ENV_ARCHIVE" "$path" >/dev/null 2>&1 || {
      rm -rf "$temp_dir"
      die "Could not restore $path from the backup ZIP."
    }
    source_path="$temp_dir/$path"
    target_path="$ROOT_DIR/$path"
    [[ -f "$source_path" ]] || { rm -rf "$temp_dir"; die "The backup ZIP does not contain $path."; }
    mkdir -p "$(dirname "$target_path")"
    install -m 0600 "$source_path" "$target_path"
    set_restored_file_owner "$target_path"
    printf 'Restored %s\n' "$path"
  done
  rm -rf "$temp_dir"
}

ensure_env_files() {
  local path password missing=()
  load_env_manifest
  for path in "${ENV_PATHS[@]}"; do
    [[ -f "$ROOT_DIR/$path" ]] || missing+=("$path")
  done
  if ((${#missing[@]})); then
    printf 'Environment files are missing; restoring from the encrypted backup before Docker starts:\n'
    printf '  %s\n' "${missing[@]}"
    if [[ -n "${IMPORT_PASSWORD:-}" ]]; then
      password="$IMPORT_PASSWORD"
    else
      read_password 'Backup ZIP password: '
      password="$REPLY"
    fi
    restore_env_files "$password" "${missing[@]}"
    for path in "${missing[@]}"; do
      [[ -f "$ROOT_DIR/$path" ]] || die "Environment restore incomplete; Docker will not start. Missing: $path"
    done
  fi
}

import_all_env_files() {
  local password="$1"
  load_env_manifest
  restore_env_files "$password" "${ENV_PATHS[@]}"
}

check_supabase_db_containers() {
  local container state
  for container in "${TABLE_DB_CONTAINERS[@]}"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
      die "Supabase database container is missing: $container"
    fi
    state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
    [[ "$state" == running\ healthy || "$state" == running\ none ]] || die "Supabase database $container is not ready (state: $state)."
  done
}

wait_for_supabase_dbs() {
  local attempt container state all_ready
  printf 'Waiting for all Supabase databases to become healthy'
  for ((attempt=0; attempt<180; attempt++)); do
    all_ready=1
    for container in "${TABLE_DB_CONTAINERS[@]}"; do
      state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
      if [[ "$state" != running\ healthy && "$state" != running\ none ]]; then
        all_ready=0
        break
      fi
    done
    if ((all_ready)); then
      printf ' ready.\n'
      return 0
    fi
    printf '.'
    sleep 2
  done
  printf '\n'
  die "Timed out waiting for the Supabase database containers."
}

backup_supabase_tables() {
  local password="$1" temp_dir label container db_name dump_file archive_path suffix=0
  command -v 7z >/dev/null 2>&1 || die "7z is required for AES-256 ZIP encryption."
  check_supabase_db_containers
  temp_dir="$(mktemp -d)"
  chmod 0700 "$temp_dir"
  mkdir -m 0700 "$temp_dir/tables"

  for index in "${!TABLE_DB_CONTAINERS[@]}"; do
    label="${TABLE_DB_LABELS[$index]}"
    container="${TABLE_DB_CONTAINERS[$index]}"
    db_name="$(docker exec "$container" sh -c 'printf %s "${POSTGRES_DB:-postgres}"')"
    dump_file="$temp_dir/tables/$label.dump"
    printf 'Dumping %s (%s)\n' "$label" "$container"
    if ! docker exec "$container" pg_dump --username=postgres --dbname="$db_name" --format=custom --no-owner --no-privileges > "$dump_file"; then
      rm -rf "$temp_dir"
      die "Database dump failed for $label."
    fi
  done

  printf 'Supabase PostgreSQL custom-format table/database dumps.\n' > "$temp_dir/tables/README.txt"
  archive_path="$ROOT_DIR/supabase-tables-backup-$(date +%Y%m%d-%H%M%S).zip"
  while [[ -e "$archive_path" ]]; do
    ((suffix+=1))
    archive_path="$ROOT_DIR/supabase-tables-backup-$(date +%Y%m%d-%H%M%S)-$suffix.zip"
  done
  if ! (cd "$temp_dir" && 7z a -tzip -mem=AES256 "-p$password" "$archive_path" tables >/dev/null); then
    rm -rf "$temp_dir"
    die "Could not create the encrypted Supabase tables ZIP."
  fi
  chmod 0600 "$archive_path"
  set_restored_file_owner "$archive_path"
  rm -rf "$temp_dir"
  printf 'Encrypted Supabase tables backup created: %s\n' "$archive_path"
}

list_table_archives() {
  shopt -s nullglob
  TABLE_ARCHIVES=("$ROOT_DIR"/supabase-tables-backup-*.zip)
  shopt -u nullglob
}

restore_supabase_tables() {
  local archive="$1" password="$2" temp_dir label container dump_file db_name
  local dump_paths=()
  command -v 7z >/dev/null 2>&1 || die "7z is required to import the encrypted ZIP."
  [[ -f "$archive" ]] || die "Table backup ZIP not found: $archive"
  7z t "-p$password" "$archive" >/dev/null 2>&1 || die "Could not open the table backup ZIP. Check the password and archive."
  check_supabase_db_containers

  temp_dir="$(mktemp -d)"
  for label in "${TABLE_DB_LABELS[@]}"; do dump_paths+=("tables/$label.dump"); done
  if ! 7z x -y "-p$password" "-o$temp_dir" "$archive" "tables/README.txt" "${dump_paths[@]}" >/dev/null 2>&1; then
    rm -rf "$temp_dir"
    die "Could not extract all Supabase database dumps from the archive."
  fi
  for dump_file in "${dump_paths[@]}"; do
    [[ -s "$temp_dir/$dump_file" ]] || { rm -rf "$temp_dir"; die "The archive is missing $dump_file."; }
  done

  printf 'Restoring will replace database objects and data in all four Supabase projects.\n'
  for index in "${!TABLE_DB_CONTAINERS[@]}"; do
    label="${TABLE_DB_LABELS[$index]}"
    container="${TABLE_DB_CONTAINERS[$index]}"
    dump_file="$temp_dir/tables/$label.dump"
    db_name="$(docker exec "$container" sh -c 'printf %s "${POSTGRES_DB:-postgres}"')"
    printf 'Restoring %s\n' "$label"
    if ! docker exec -i "$container" pg_restore --username=postgres --dbname="$db_name" --clean --if-exists --no-owner --no-privileges --exit-on-error - < "$dump_file"; then
      rm -rf "$temp_dir"
      die "Database restore failed for $label. Earlier projects may already have been restored."
    fi
  done
  rm -rf "$temp_dir"
  printf 'All Supabase databases restored.\n'
}

prompt_table_import() {
  local answer selection password archive
  [[ -r /dev/tty ]] || { printf 'No interactive terminal; skipping optional table import.\n'; return 0; }
  list_table_archives
  ((${#TABLE_ARCHIVES[@]})) || { printf 'No Supabase table backup ZIPs found; skipping import prompt.\n'; return 0; }
  printf 'Import Supabase tables from a backup ZIP now? [y/N] ' > /dev/tty
  IFS= read -r answer < /dev/tty
  case "${answer,,}" in
    y|yes) ;;
    *) printf 'Skipping Supabase table import.\n'; return 0 ;;
  esac

  printf '\nAvailable Supabase table backups:\n'
  for index in "${!TABLE_ARCHIVES[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "$(basename "${TABLE_ARCHIVES[$index]}")"
  done
  printf 'Choose a backup number: ' > /dev/tty
  IFS= read -r selection < /dev/tty
  [[ "$selection" =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#TABLE_ARCHIVES[@]})) || die "Invalid table backup selection."
  archive="${TABLE_ARCHIVES[$((selection - 1))]}"
  read_password 'Table backup ZIP password: '
  password="$REPLY"
  restore_supabase_tables "$archive" "$password"
}

root_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "Root permission is needed to configure /etc/nginx and /etc/hosts. Run ./start-all.sh with sudo."
    sudo "$@"
  fi
}

docker_cmd() {
  docker compose "$@"
}

detect_lan_ip() {
  local ip_address

  # Prefer the wired interface named in this host's setup, then use the
  # interface selected by the default route. Never advertise loopback.
  ip_address="$(ip -4 -o addr show dev enp6s0 scope global 2>/dev/null \
    | awk '{split($4, a, "/"); print a[1]; exit}')"
  if [[ -z "$ip_address" ]]; then
    ip_address="$(ip -4 route show default 2>/dev/null \
      | awk 'NR == 1 {print $5; exit}' \
      | while read -r iface; do
          [[ -n "$iface" ]] && ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
            | awk '{split($4, a, "/"); print a[1]; exit}'
        done)"
  fi

  [[ -n "$ip_address" ]] || die "Could not detect a LAN IPv4 address (checked enp6s0 and the default route)."
  printf '%s\n' "$ip_address"
}

ensure_avahi() {
  local sudo_cmd=()

  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Avahi needs root to start. Run this script with sudo or install/configure Avahi first."
    sudo_cmd=(sudo)
  fi

  if ! command -v avahi-publish >/dev/null 2>&1; then
    [[ -r /etc/debian_version ]] || die "avahi-publish is missing; install avahi-utils on Debian first."
    "${sudo_cmd[@]}" apt-get update
    "${sudo_cmd[@]}" apt-get install -y avahi-daemon avahi-utils dbus
  fi

  if ! pgrep -x avahi-daemon >/dev/null 2>&1; then
    if command -v service >/dev/null 2>&1; then
      "${sudo_cmd[@]}" service dbus start >/dev/null 2>&1 || true
      "${sudo_cmd[@]}" service avahi-daemon start
    else
      die "Avahi is installed but avahi-daemon is not running and service(8) is unavailable."
    fi
  fi
}

nginx_is_running() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    return 0
  fi
  pgrep -x nginx >/dev/null 2>&1
}

show_nginx_status() {
  if ! command -v nginx >/dev/null 2>&1; then
    printf 'Nginx: not installed\n'
  elif nginx_is_running; then
    printf 'Nginx: running\n'
  else
    printf 'Nginx: stopped\n'
  fi
}

ensure_host_settings() {
  local address="$1" config changed=0 hosts_src hosts_tmp managed_hosts timeout_tmp

  command -v nginx >/dev/null 2>&1 || die "Nginx is not installed; install nginx before starting the stacks."
  root_cmd install -d -m 0755 /etc/nginx/conf.d
  for config in "${NGINX_CONFIGS[@]}"; do
    if [[ ! -f "/etc/nginx/conf.d/$config" ]]; then
      [[ -f "$ROOT_DIR/nginx-conf/$config" ]] || die "Missing Nginx template: nginx-conf/$config"
      root_cmd install -m 0644 "$ROOT_DIR/nginx-conf/$config" "/etc/nginx/conf.d/$config"
      printf 'Restored /etc/nginx/conf.d/%s\n' "$config"
      changed=1
    fi
  done

  if [[ ! -f /var/www/lccb-home/index.html ]]; then
    [[ -f "$ROOT_DIR/site/lccb-home/index.html" ]] || die "Missing homepage template: site/lccb-home/index.html"
    root_cmd install -d -m 0755 /var/www/lccb-home
    root_cmd install -m 0644 "$ROOT_DIR/site/lccb-home/index.html" /var/www/lccb-home/index.html
    printf 'Restored /var/www/lccb-home/index.html\n'
  fi

  [[ -f "$ROOT_DIR/host-config/hosts" ]] || die "Missing hosts template: host-config/hosts"
  hosts_src="$(mktemp)"
  hosts_tmp="$(mktemp)"
  if [[ -r /etc/hosts ]]; then
    cp /etc/hosts "$hosts_src"
  elif [[ ! -e /etc/hosts ]]; then
    sed "s/^@LAN_IP@/$address/" "$ROOT_DIR/host-config/hosts" > "$hosts_src"
  else
    die "/etc/hosts exists but is not readable. Run this script with sudo."
  fi

  managed_hosts="${HOSTS_ENTRIES[*]}"
  awk -v address="$address" -v hostnames="$managed_hosts" '
    BEGIN { count = split(hostnames, managed, " ") }
    $0 == "# Project names managed by start-all.sh" { next }
    /^[[:space:]]*#/ || NF == 0 { print; next }
    {
      line = $1
      kept = 0
      comment = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^#/) {
          for (j = i; j <= NF; j++) comment = comment (comment == "" ? "" : " ") $j
          break
        }
        remove = 0
        for (j = 1; j <= count; j++) if ($i == managed[j]) remove = 1
        if (!remove) { line = line " " $i; kept++ }
      }
      if (kept > 0 || comment != "") print line (comment != "" ? " " comment : "")
    }
    END { print "# Project names managed by start-all.sh"; print address, hostnames }
  ' "$hosts_src" > "$hosts_tmp"

  if [[ ! -e /etc/hosts ]] || ! cmp -s /etc/hosts "$hosts_tmp"; then
    root_cmd install -m 0644 "$hosts_tmp" /etc/hosts
    printf 'Mapped project names in /etc/hosts to %s\n' "$address"
  fi
  rm -f "$hosts_src"
  rm -f "$hosts_tmp"

  # PDF ingestion makes multiple page-by-page AI calls before responding.
  # Keep Nginx from returning its default 504 while that request is running.
  timeout_tmp="$(mktemp)"
  if awk '
    NR == FNR {
      if ($1 == "client_max_body_size" || $1 == "proxy_read_timeout" || $1 == "proxy_send_timeout" || $1 == "send_timeout") seen[$1] = 1
      next
    }
    {
      if ($1 == "client_max_body_size") {
        print "        client_max_body_size 100m;"
        next
      }
      if ($1 == "proxy_read_timeout" || $1 == "proxy_send_timeout" || $1 == "send_timeout") {
        print "        " $1 " 600s;"
        next
      }
      print
      if (index($0, "proxy_set_header Connection $connection_upgrade;") > 0) {
        anchor = 1
        if (!seen["client_max_body_size"]) print "        client_max_body_size 100m;"
        if (!seen["proxy_read_timeout"]) print "        proxy_read_timeout 600s;"
        if (!seen["proxy_send_timeout"]) print "        proxy_send_timeout 600s;"
        if (!seen["send_timeout"]) print "        send_timeout 600s;"
      }
    }
    END { if (!anchor) exit 10 }
  ' /etc/nginx/conf.d/laco.conf /etc/nginx/conf.d/laco.conf > "$timeout_tmp"; then
    if ! cmp -s /etc/nginx/conf.d/laco.conf "$timeout_tmp"; then
      root_cmd install -m 0644 "$timeout_tmp" /etc/nginx/conf.d/laco.conf
      printf 'Set app.laco.local PDF proxy timeouts to 600 seconds\n'
      changed=1
    fi
  else
    printf 'WARNING: Could not add PDF proxy timeouts to /etc/nginx/conf.d/laco.conf\n' >&2
  fi
  rm -f "$timeout_tmp"

  root_cmd nginx -t
  if nginx_is_running; then
    if ((changed)); then
      if command -v systemctl >/dev/null 2>&1; then
        root_cmd systemctl reload nginx
      else
        root_cmd nginx -s reload
      fi
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then
      root_cmd systemctl start nginx
    elif command -v service >/dev/null 2>&1; then
      root_cmd service nginx start
    else
      die "Nginx is stopped and no systemctl or service command is available to start it."
    fi
  fi
  show_nginx_status
}

start_publishers() {
  local address="$1" hostname pid_file pid process_name
  mkdir -p "$RUNTIME_DIR"
  for hostname in "${HOSTNAMES[@]}"; do
    pid_file="$RUNTIME_DIR/$hostname.pid"
    if [[ -f "$pid_file" ]]; then
      read -r pid < "$pid_file" || true
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null \
        && [[ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')" == avahi-publish ]]; then
        continue
      fi
      rm -f "$pid_file"
    fi
    avahi-publish -a -R "$hostname" "$address" >"$RUNTIME_DIR/$hostname.log" 2>&1 &
    printf '%s\n' "$!" > "$pid_file"
    pid="$!"
    sleep 0.1
    process_name="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$process_name" != avahi-publish ]]; then
      printf 'ERROR: Avahi failed to publish %s at %s.\n' "$hostname" "$address" >&2
      cat "$RUNTIME_DIR/$hostname.log" >&2 || true
      rm -f "$pid_file"
      return 1
    fi
    printf 'Avahi: %s -> %s\n' "$hostname" "$address"
  done
  printf 'Started Avahi publishers for %s names at %s.\n' "${#HOSTNAMES[@]}" "$address"
}

stop_publishers() {
  local pid_file pid
  if [[ ! -d "$RUNTIME_DIR" ]]; then return 0; fi
  for pid_file in "$RUNTIME_DIR"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    read -r pid < "$pid_file" || true
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null \
      && [[ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')" == avahi-publish ]]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
  rmdir "$RUNTIME_DIR" 2>/dev/null || true
}

start_projects() {
  local project
  for project in "${PROJECTS[@]}"; do
    [[ -f "$ROOT_DIR/$project/docker-compose.yml" ]] || die "Missing Compose file: $project/docker-compose.yml"
    printf '==> Checking %s configuration\n' "$project"
    (cd "$ROOT_DIR/$project" && docker_cmd config --quiet)
  done

  for project in "${PROJECTS[@]}"; do
    printf '\n==> Starting %s\n' "$project"
    (cd "$ROOT_DIR/$project" && docker_cmd up -d)
  done
}

show_status() {
  local project
  for project in "${PROJECTS[@]}"; do
    printf '\n==> %s\n' "$project"
    (cd "$ROOT_DIR/$project" && docker_cmd ps)
  done
  show_nginx_status
}

stop_projects() {
  local i project
  for ((i=${#PROJECTS[@]}-1; i>=0; i--)); do
    project="${PROJECTS[$i]}"
    printf '\n==> Stopping %s\n' "$project"
    (cd "$ROOT_DIR/$project" && docker_cmd down)
  done
}

TABLES_IMPORT_REQUESTED=0
case "${1:-}" in
  --tables)
    [[ $# -ge 2 ]] || { usage >&2; exit 2; }
    case "$2" in
      --backup)
        [[ $# -le 3 ]] || { usage >&2; exit 2; }
        command -v docker >/dev/null 2>&1 || die "Docker CLI is not installed."
        docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon."
        password="${3:-}"
        if [[ -z "$password" ]]; then
          read_password 'Supabase tables ZIP password: ' true
          password="$REPLY"
        fi
        backup_supabase_tables "$password"
        exit 0
        ;;
      --import)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        TABLES_IMPORT_REQUESTED=1
        ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
esac

case "${1:-}" in
  --backup)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    password="${2:-}"
    if [[ -z "$password" ]]; then
      read_password 'Backup ZIP password: ' true
      password="$REPLY"
    fi
    backup_env_files "$password"
    exit 0
    ;;
  --import)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    password="${2:-}"
    if [[ -z "$password" ]]; then
      read_password 'Backup ZIP password: '
      password="$REPLY"
    fi
    import_all_env_files "$password"
    exit 0
    ;;
esac

if ((TABLES_IMPORT_REQUESTED)); then
  action="up"
else
  action="${1:-up}"
fi
case "$action" in
  -h|--help|help) usage; exit 0 ;;
  up)
    if ((!TABLES_IMPORT_REQUESTED)); then
      [[ $# -le 1 ]] || { usage >&2; exit 2; }
    fi
    command -v docker >/dev/null 2>&1 || die "Docker CLI is not installed."
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available."
    ensure_env_files
    docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon. Give this Debian container access to /var/run/docker.sock and the required socket permissions."
    command -v ip >/dev/null 2>&1 || die "The iproute2 package is required to detect the LAN address."
    lan_ip="$(detect_lan_ip)"
    ensure_host_settings "$lan_ip"
    ensure_avahi
    start_projects
    if ((TABLES_IMPORT_REQUESTED)); then
      wait_for_supabase_dbs
    fi
    start_publishers "$lan_ip"
    if ((TABLES_IMPORT_REQUESTED)); then
      prompt_table_import
    fi
    cat <<EOF

All project stacks are started.
Supabase Kong endpoints on this host:
  Laco AI:          http://kong.local:8000
  Metric:           http://kong.local:8100
  Auditrack:        http://kong.local:8200
  Laco Bookstore:   http://kong.local:8300 (Compose currently binds this port to loopback only)
EOF
    ;;
  stop|down)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    command -v docker >/dev/null 2>&1 || die "Docker CLI is not installed."
    printf 'Stopping all Compose stacks managed by start-all.sh.\n'
    stop_publishers
    stop_projects
    ;;
  status)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    command -v docker >/dev/null 2>&1 || die "Docker CLI is not installed."
    show_status
    ;;
  *) usage >&2; exit 2 ;;
esac
