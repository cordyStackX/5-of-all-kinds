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

  up      Start all Compose projects and publish their .local hostnames (default)
  stop    Stop all Compose projects managed by this script and hostname publishers
  down    Alias for stop
  status  Show the state of each Compose project
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

  if ! command -v avahi-publish-address >/dev/null 2>&1; then
    [[ -r /etc/debian_version ]] || die "avahi-publish-address is missing; install avahi-utils on Debian first."
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
  local config changed=0 hosts_tmp host missing=()

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

  if [[ -r /etc/hosts ]]; then
    hosts_tmp="$(mktemp)"
    cp /etc/hosts "$hosts_tmp"
  else
    hosts_tmp="$(mktemp)"
    cat > "$hosts_tmp" <<'EOF'
127.0.0.1 localhost
::1 localhost
EOF
  fi
  for host in "${HOSTS_ENTRIES[@]}"; do
    if ! awk -v host="$host" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == host) found = 1 } END { exit !found }' "$hosts_tmp"; then
      missing+=("$host")
    fi
  done
  if ((${#missing[@]})); then
    printf '\n# Local project hostnames managed by start-all.sh\n127.0.0.1 %s\n' "${missing[*]}" >> "$hosts_tmp"
    root_cmd install -m 0644 "$hosts_tmp" /etc/hosts
    printf 'Added missing names to /etc/hosts: %s\n' "${missing[*]}"
  fi
  rm -f "$hosts_tmp"

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
  local address="$1" hostname pid_file pid
  mkdir -p "$RUNTIME_DIR"
  for hostname in "${HOSTNAMES[@]}"; do
    pid_file="$RUNTIME_DIR/$hostname.pid"
    if [[ -f "$pid_file" ]]; then
      read -r pid < "$pid_file" || true
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null \
        && [[ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')" == avahi-publish-address ]]; then
        continue
      fi
      rm -f "$pid_file"
    fi
    avahi-publish-address -R "$hostname" "$address" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pid_file"
  done
  printf 'Published %s names at %s via Avahi.\n' "${#HOSTNAMES[@]}" "$address"
}

stop_publishers() {
  local pid_file pid
  if [[ ! -d "$RUNTIME_DIR" ]]; then return 0; fi
  for pid_file in "$RUNTIME_DIR"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    read -r pid < "$pid_file" || true
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null \
      && [[ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')" == avahi-publish-address ]]; then
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

action="${1:-up}"
case "$action" in
  -h|--help|help) usage; exit 0 ;;
  up)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    command -v docker >/dev/null 2>&1 || die "Docker CLI is not installed."
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available."
    docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon. Give this Debian container access to /var/run/docker.sock and the required socket permissions."
    command -v ip >/dev/null 2>&1 || die "The iproute2 package is required to detect the LAN address."
    lan_ip="$(detect_lan_ip)"
    ensure_host_settings
    ensure_avahi
    start_projects
    start_publishers "$lan_ip"
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
