# shellcheck shell=bash
# Shared paths, config and helpers for the bench box. Sourced by bench/box/bench.

BENCH_ROOT=/opt/twenty-bench
INFRA_DIR="$BENCH_ROOT/infra"
SECRETS_DIR="$BENCH_ROOT/secrets"
ENV_SECRETS_DIR="$SECRETS_DIR/env"
REPO_DIR="$BENCH_ROOT/repo"
ENVS_DIR="$BENCH_ROOT/envs"
LOG_DIR="$BENCH_ROOT/log"
LOCK_DIR="$BENCH_ROOT/locks"
STATE_DIR="$BENCH_ROOT/state"
NODE_DIR="$BENCH_ROOT/node"
TEMPLATE_STORAGE_DIR="$BENCH_ROOT/template-storage"
LINGUI_OVERLAY_DIR="$BENCH_ROOT/lingui-overlay"
CONFIG_FILE="$BENCH_ROOT/config.env"
BENCH_SECRETS_FILE="$SECRETS_DIR/bench.env"
LOGINS_FILE="$SECRETS_DIR/logins.env"

FORK_URL=https://github.com/iulianoana/twenty.git
BENCH_USER=twenty
TEMPLATE_DB=twenty_template
TEMPLATE_ENV=template
TEMPLATE_SLOT=99

# Packages the bench builds, in dependency order (see bench/README.md).
BUILD_ORDER=(
  twenty-shared
  twenty-ui
  twenty-client-sdk
  twenty-emails
  twenty-sdk
  twenty-front-component-renderer
  twenty-server
  twenty-front
)
FOCUS_WORKSPACES=(
  twenty-monorepo twenty-front twenty-front-component-renderer twenty-ui
  twenty-shared twenty-sdk twenty-client-sdk twenty-server twenty-emails
  twenty-oxlint-rules
)

declare -A PACKAGE_DEPENDENTS=(
  [twenty-shared]="twenty-client-sdk twenty-emails twenty-sdk twenty-front-component-renderer twenty-server twenty-front"
  [twenty-ui]="twenty-sdk twenty-front-component-renderer twenty-front"
  [twenty-client-sdk]="twenty-sdk twenty-front-component-renderer twenty-server twenty-front"
  [twenty-emails]="twenty-server"
  [twenty-sdk]="twenty-front-component-renderer twenty-front"
  [twenty-front-component-renderer]="twenty-front"
  [twenty-server]=""
  [twenty-front]=""
)

declare -A LINGUI_LOCALE_DIRS=(
  [twenty-front]=packages/twenty-front/src/locales
  [twenty-server]=packages/twenty-server/src/engine/core-modules/i18n/locales
  [twenty-emails]=packages/twenty-emails/src/locales
)

export PATH="$NODE_DIR/bin:$PATH"

log() { printf '[bench %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

now_s() { date +%s; }

# Records a named duration for the current operation; printed as a JSON summary at the end.
declare -A TIMINGS=()
TIMING_KEYS=()
timing() {
  TIMINGS[$1]=$2
  TIMING_KEYS+=("$1")
  log "timing $1=${2}s"
}
timings_json() {
  local key out="{" first=1
  for key in "${TIMING_KEYS[@]}"; do
    [[ $first == 1 ]] || out+=","
    out+="\"$key\":${TIMINGS[$key]}"
    first=0
  done
  printf '%s}' "$out"
}

require_root() { [[ $EUID == 0 ]] || die "run as root"; }

load_config() {
  [[ -f $CONFIG_FILE ]] || die "missing $CONFIG_FILE (run provision first)"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${PUBLIC_IP:?}" "${HOST_SUFFIX:?}" "${FRONT_BUILD_SLOTS:?}" "${MAX_PREVIEWS:?}"
}

load_bench_secrets() {
  [[ -f $BENCH_SECRETS_FILE ]] || die "missing bench secrets"
  # shellcheck disable=SC1090
  source "$BENCH_SECRETS_FILE"
}

as_bench() {
  runuser -u "$BENCH_USER" -- env \
    PATH="$PATH" HOME="/home/$BENCH_USER" \
    NX_DAEMON=false NX_NO_CLOUD=true NX_TUI=false NX_SKIP_NX_CACHE=true \
    NX_INTERACTIVE=false YARN_ENABLE_PROGRESS_BARS=false \
    "$@"
}

yarn_in() {
  local tree=$1
  shift
  local yarn_path
  yarn_path=$(sed -n 's/^yarnPath: //p' "$tree/.yarnrc.yml")
  (cd "$tree" && as_bench node "$tree/$yarn_path" "$@")
}

nx_in() {
  local tree=$1
  shift
  (cd "$tree" && as_bench node "$tree/node_modules/.bin/nx" "$@")
}

psql_admin() {
  PGPASSWORD="$PG_PASSWORD" psql -h 127.0.0.1 -U twenty -d postgres -v ON_ERROR_STOP=1 -qtA "$@"
}

psql_db() {
  local db=$1
  shift
  PGPASSWORD="$PG_PASSWORD" psql -h 127.0.0.1 -U twenty -d "$db" -v ON_ERROR_STOP=1 -qtA "$@"
}

random_hex() { openssl rand -hex "${1:-32}"; }
random_password() {
  python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(24)))'
}

# Exclusive lock on a named file for the rest of the calling shell.
lock_exclusive() {
  local name=$1 fd
  mkdir -p "$LOCK_DIR"
  exec {fd}>"$LOCK_DIR/$name.lock"
  flock "$fd"
}

# Holds one of N slots of a named semaphore in SLOT_FD (not a subshell, so the lock stays held).
SLOT_FD=
acquire_slot() {
  local name=$1 slots=$2 i fd waited=0
  mkdir -p "$LOCK_DIR"
  while true; do
    for ((i = 0; i < slots; i++)); do
      exec {fd}>"$LOCK_DIR/$name.$i.lock"
      if flock -n "$fd"; then
        [[ $waited == 0 ]] || log "got $name slot $i after ${waited}s"
        SLOT_FD=$fd
        return 0
      fi
      exec {fd}>&-
    done
    sleep 2
    waited=$((waited + 2))
  done
}
release_slot() {
  [[ -n $SLOT_FD ]] || return 0
  exec {SLOT_FD}>&-
  SLOT_FD=
}

valid_env_name() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

slug_for_branch() { printf '%s' "${1//\//-}"; }

env_dir() { printf '%s/%s' "$ENVS_DIR" "$1"; }
env_secret_file() { printf '%s/%s.env' "$ENV_SECRETS_DIR" "$1"; }
env_host() { printf '%s.%s' "$1" "$HOST_SUFFIX"; }
env_url() { printf 'https://%s' "$(env_host "$1")"; }

env_exists() { [[ -f "$(env_dir "$1")/meta" ]]; }

load_env_meta() {
  local meta
  meta="$(env_dir "$1")/meta"
  [[ -f $meta ]] || die "environment '$1' does not exist"
  # shellcheck disable=SC1090
  source "$meta"
}

db_name_for() {
  local name=$1
  if [[ $name == main ]]; then
    echo twenty_main
    return
  fi
  local short=${name//-/_} hash
  short=${short:0:48}
  hash=$(printf '%s' "$name" | sha1sum | cut -c1-8)
  echo "pv_${short}_${hash}"
}
