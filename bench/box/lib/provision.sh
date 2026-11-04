# shellcheck shell=bash
# One-time (idempotent) box setup: packages, Node, Postgres, Caddy, the built base checkout,
# the seeded template database and the main environment.

provision_system() {
  local public_ip=$1 start
  start=$(now_s)
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$BENCH_ROOT"
  if [[ ! -f "$STATE_DIR/system.ok" ]]; then
    log "installing system packages"
    apt-get update -qq
    apt-get install -y -qq git curl jq rsync xz-utils python3 openssl ca-certificates gnupg \
      debian-keyring debian-archive-keyring apt-transport-https ufw \
      postgresql postgresql-contrib redis-server >/dev/null
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt >/etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq
    fi
    apt-get install -y -qq caddy >/dev/null
    systemctl disable --now redis-server >/dev/null 2>&1 || true
  fi

  id "$BENCH_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$BENCH_USER"
  mkdir -p "$ENVS_DIR" "$LOG_DIR" "$LOCK_DIR" "$STATE_DIR" "$SECRETS_DIR" "$ENV_SECRETS_DIR" "$LINGUI_OVERLAY_DIR"
  chmod 700 "$SECRETS_DIR" "$ENV_SECRETS_DIR"
  chown "$BENCH_USER:" "$ENVS_DIR" "$LOG_DIR"
  chmod 1777 "$LOCK_DIR"
  git config --system safe.directory '*'

  if ! swapon --show | grep -q .; then
    log "adding 16G swap"
    fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
  sysctl -q -w vm.overcommit_memory=1 vm.swappiness=10 fs.inotify.max_user_watches=524288
  printf 'vm.overcommit_memory=1\nvm.swappiness=10\nfs.inotify.max_user_watches=524288\n' >/etc/sysctl.d/90-twenty-bench.conf

  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null

  # Capacity follows memory: a front build peaks at ~7 GB, an environment at ~2 GB.
  local mem_gb
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo)
  local slots=2 previews=3 heap=7168
  if (($(nproc) < 12)); then slots=1; fi
  if ((mem_gb < 28)); then slots=1 heap=6144; fi
  if ((mem_gb < 20)); then previews=2; fi
  [[ -n $public_ip ]] || public_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  cat >"$CONFIG_FILE" <<EOF
PUBLIC_IP=$public_ip
HOST_SUFFIX=${public_ip//./-}.sslip.io
FRONT_BUILD_SLOTS=$slots
MAX_PREVIEWS=$previews
FRONT_BUILD_HEAP_MB=$heap
MEM_GB=$mem_gb
CPUS=$(nproc)
EOF
  load_config
  log "box: $(nproc) vCPU, ${mem_gb} GB RAM -> front build slots $slots, max previews $previews"

  if [[ ! -f $BENCH_SECRETS_FILE ]]; then
    log "generating bench secrets"
    umask 077
    cat >"$BENCH_SECRETS_FILE" <<EOF
PG_PASSWORD=$(random_hex 24)
ENCRYPTION_KEY=$(random_hex 32)
TEMPLATE_APP_SECRET=$(random_hex 32)
ADMIN_EMAIL=jane.austen@apple.dev
ADMIN_PASSWORD=$(random_password)
MEMBER_EMAIL=jony.ive@apple.dev
MEMBER_PASSWORD=$(random_password)
EOF
    umask 022
  fi
  load_bench_secrets

  install_node
  install_yarn_shim
  setup_postgres
  install -m 644 "$INFRA_DIR"/box/systemd/*.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now caddy >/dev/null 2>&1
  touch "$STATE_DIR/system.ok"
  timing system $(($(now_s) - start))
}

install_node() {
  local version
  version=$(git -C "$REPO_DIR" show HEAD:.nvmrc 2>/dev/null || echo 26.12.1)
  version=${version#v}
  if [[ "$("$NODE_DIR/bin/node" --version 2>/dev/null)" == "v$version" ]]; then return 0; fi
  log "installing Node $version"
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "https://nodejs.org/dist/v$version/node-v$version-linux-x64.tar.xz" -o "$tmp/node.tar.xz"
  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xJf "$tmp/node.tar.xz" -C "$NODE_DIR" --strip-components=1
  rm -rf "$tmp"
}

# Node 26 ships without Yarn; package scripts call `yarn`, so run the release pinned in the nearest .yarnrc.yml.
install_yarn_shim() {
  cat >/usr/local/bin/yarn <<'EOF'
#!/bin/sh
dir=$PWD
while [ "$dir" != / ] && [ ! -f "$dir/.yarnrc.yml" ]; do dir=$(dirname "$dir"); done
exec node "$dir/$(sed -n 's/^yarnPath: //p' "$dir/.yarnrc.yml")" "$@"
EOF
  chmod 755 /usr/local/bin/yarn
}

setup_postgres() {
  local conf
  conf=$(ls -d /etc/postgresql/*/main | sort -V | tail -n1)
  cat >"$conf/conf.d/twenty-bench.conf" <<'EOF'
listen_addresses = 'localhost'
max_connections = 200
shared_buffers = 1GB
work_mem = 16MB
synchronous_commit = off
EOF
  systemctl restart postgresql
  local i
  for ((i = 0; i < 30; i++)); do runuser -u postgres -- pg_isready -q && break; sleep 1; done
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'twenty'" | grep -q 1; then
    runuser -u postgres -- psql -qc "CREATE ROLE twenty WITH LOGIN SUPERUSER"
  fi
  printf "ALTER ROLE twenty WITH PASSWORD '%s';\n" "$PG_PASSWORD" | runuser -u postgres -- psql -q
}

# Clones (or updates) the base checkout at the fork's main and builds everything once.
provision_base() {
  local main_sha=$1 start
  start=$(now_s)
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    log "cloning $FORK_URL"
    mkdir -p "$REPO_DIR"
    chown "$BENCH_USER:" "$REPO_DIR"
    as_bench git clone --quiet --depth 1 --branch main "$FORK_URL" "$REPO_DIR"
  fi
  as_bench git -C "$REPO_DIR" fetch --quiet --depth=1 origin "+refs/heads/main:refs/remotes/origin/main"
  [[ -n $main_sha ]] || main_sha=$(git -C "$REPO_DIR" rev-parse refs/remotes/origin/main)
  git -C "$REPO_DIR" cat-file -e "$main_sha^{commit}" || die "main sha $main_sha not fetched"
  install_node

  local built=""
  [[ -f "$STATE_DIR/base.sha" ]] && built=$(cat "$STATE_DIR/base.sha")
  if [[ $built == "$main_sha" ]]; then
    log "base already built at ${main_sha:0:12}"
    return 0
  fi
  as_bench git -C "$REPO_DIR" checkout --quiet --force --detach "$main_sha"

  local deps_hash
  deps_hash=$(cd "$REPO_DIR" && cat yarn.lock package.json packages/*/package.json | sha1sum | cut -c1-40)
  if [[ ! -f "$STATE_DIR/base.deps" || $(cat "$STATE_DIR/base.deps") != "$deps_hash" || ! -d "$REPO_DIR/node_modules" ]]; then
    install_dependencies "$REPO_DIR"
    echo "$deps_hash" >"$STATE_DIR/base.deps"
  fi

  if [[ -n $built ]] && git -C "$REPO_DIR" cat-file -e "$built^{commit}" 2>/dev/null; then
    mapfile -t changed < <(git -C "$REPO_DIR" diff --name-only "$built" "$main_sha")
    plan_build "${changed[@]}"
  else
    BUILD_SET=("${BUILD_ORDER[@]}")
  fi
  build_tree "$REPO_DIR" "$main_sha" extract "${BUILD_SET[@]}"
  save_catalog_overlay "$REPO_DIR"
  local changed_catalogs
  changed_catalogs=$(git -C "$REPO_DIR" status --porcelain -- '*locales*' | wc -l)
  log "lingui extraction changed $changed_catalogs catalog files versus the committed ones"
  echo "$main_sha" >"$STATE_DIR/base.sha"
  timing base_build $(($(now_s) - start))
}

# Seeds twenty_template once from the base build. Previews and main are cloned from it.
provision_template() {
  local force=${1:-0} start
  if [[ -f "$STATE_DIR/template.ok" && $force != 1 ]]; then
    log "template already seeded ($(cat "$STATE_DIR/template.ok"))"
    return 0
  fi
  start=$(now_s)
  load_bench_secrets
  mkdir -p "$(env_dir "$TEMPLATE_ENV")"
  cat >"$(env_dir "$TEMPLATE_ENV")/meta" <<EOF
NAME=$TEMPLATE_ENV
SLOT=$TEMPLATE_SLOT
PORT=3199
REDIS_PORT=6499
DB_NAME=$TEMPLATE_DB
HOST=template.invalid
EOF
  write_env_file "$TEMPLATE_ENV" "$TEMPLATE_APP_SECRET"
  sed -i 's/^NODE_ENV=.*/NODE_ENV=development/' "$(env_secret_file "$TEMPLATE_ENV")"
  sed -i "s|^STORAGE_LOCAL_PATH=.*|STORAGE_LOCAL_PATH=$TEMPLATE_STORAGE_DIR|" "$(env_secret_file "$TEMPLATE_ENV")"
  rm -f "$(env_dir "$TEMPLATE_ENV")/meta"

  rm -rf "$TEMPLATE_STORAGE_DIR"
  mkdir -p "$TEMPLATE_STORAGE_DIR"
  chown "$BENCH_USER:" "$TEMPLATE_STORAGE_DIR"
  psql_admin -c "DROP DATABASE IF EXISTS $TEMPLATE_DB WITH (FORCE)"
  psql_admin -c "CREATE DATABASE $TEMPLATE_DB"
  systemctl start "twenty-redis@$TEMPLATE_ENV"
  flush_redis_port 6499

  local server="$REPO_DIR/packages/twenty-server" seedlog="$LOG_DIR/template-seed.log"
  log "initialising and seeding the template database (full dev seed)"
  (
    set -a
    # shellcheck disable=SC1090
    source "$(env_secret_file "$TEMPLATE_ENV")"
    set +a
    cd "$server"
    as_bench node dist/database/scripts/setup-db.js &&
      as_bench node dist/command/command run-instance-commands --force --include-slow &&
      as_bench node dist/command/command cache:flush &&
      as_bench node dist/command/command workspace:seed:dev &&
      as_bench node dist/command/command cache:flush
  ) >"$seedlog" 2>&1 || { tail -n 60 "$seedlog" >&2; die "template seed failed"; }
  timing template_seed $(($(now_s) - start))

  local admin_hash member_hash other_hash
  admin_hash=$(bcrypt_hash "$ADMIN_PASSWORD")
  member_hash=$(bcrypt_hash "$MEMBER_PASSWORD")
  other_hash=$(bcrypt_hash "$(random_password)")
  {
    printf "\\\\set admin_email '%s'\n\\\\set member_email '%s'\n" "$ADMIN_EMAIL" "$MEMBER_EMAIL"
    printf "\\\\set admin_hash '%s'\n\\\\set member_hash '%s'\n\\\\set other_hash '%s'\n" "$admin_hash" "$member_hash" "$other_hash"
    cat "$INFRA_DIR/box/sql/template-tweaks.sql"
  } | psql_db "$TEMPLATE_DB" -f - >/dev/null
  psql_db "$TEMPLATE_DB" -f "$INFRA_DIR/box/sql/workspace-settings.sql" >/dev/null
  systemctl stop "twenty-redis@$TEMPLATE_ENV"
  psql_db "$TEMPLATE_DB" -f "$INFRA_DIR/box/sql/seed-report.sql" 2>&1 | sed 's/^/[seed] /' >&2
  psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$TEMPLATE_DB' AND pid <> pg_backend_pid()" >/dev/null
  date -u +%Y-%m-%dT%H:%M:%SZ >"$STATE_DIR/template.ok"
  timing template_total $(($(now_s) - start))
}

# Re-applies workspace-settings.sql to the template and every environment (idempotent), then drops
# each environment's cached workspace so the change is seen without a reseed.
apply_workspace_settings() {
  local meta
  load_bench_secrets
  psql_db "$TEMPLATE_DB" -f "$INFRA_DIR/box/sql/workspace-settings.sql" >/dev/null
  for meta in "$ENVS_DIR"/*/meta; do
    [[ -f $meta ]] || continue
    (
      # shellcheck disable=SC1090
      source "$meta"
      psql_db "$DB_NAME" -f "$INFRA_DIR/box/sql/workspace-settings.sql" >/dev/null
      if systemctl is-active --quiet "twenty-redis@$NAME"; then
        redis-cli -p "$REDIS_PORT" FLUSHALL >/dev/null
        systemctl restart "twenty-server@$NAME" "twenty-worker@$NAME"
      fi
    )
  done
}

# The shim needs the seeded workspace's invite hash, which every clone shares with the template.
install_signup_shim() {
  local invite_hash
  load_bench_secrets
  invite_hash=$(psql_db "$TEMPLATE_DB" -c "SELECT \"inviteHash\" FROM core.workspace WHERE id = '20202020-1c25-4d02-bf25-6aeccf7ea419'")
  [[ -n $invite_hash ]] || die "seeded workspace has no invite hash"
  printf 'SHIM_PORT=%s\nBENCH_INVITE_HASH=%s\n' "$SIGNUP_SHIM_PORT" "$invite_hash" >"$SIGNUP_SHIM_ENV"
  systemctl enable --quiet twenty-signup-shim
  systemctl restart twenty-signup-shim
  local i
  for ((i = 0; i < 20; i++)); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SIGNUP_SHIM_PORT/" && break
    sleep 0.5
  done
}

flush_redis_port() {
  local i
  for ((i = 0; i < 20; i++)); do
    redis-cli -p "$1" FLUSHALL >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  die "redis on port $1 did not answer"
}

bcrypt_hash() {
  printf '%s' "$1" | (cd "$REPO_DIR/packages/twenty-server" && as_bench node -e "
    let input = '';
    process.stdin.on('data', (chunk) => (input += chunk));
    process.stdin.on('end', () => require('bcrypt').hash(input, 10).then((hash) => console.log(hash)));")
}

write_logins() {
  load_bench_secrets
  umask 077
  cat >"$LOGINS_FILE" <<EOF
TWENTY_MAIN_URL=$(env_url main)
TWENTY_HEALTH_URL=$(env_url main)/healthz
TWENTY_PREVIEW_URL_TEMPLATE=https://{slug}.$HOST_SUFFIX
TWENTY_SERVER_IP=$PUBLIC_IP
TWENTY_ADMIN_EMAIL=$ADMIN_EMAIL
TWENTY_ADMIN_PASSWORD=$ADMIN_PASSWORD
TWENTY_MEMBER_EMAIL=$MEMBER_EMAIL
TWENTY_MEMBER_PASSWORD=$MEMBER_PASSWORD
EOF
  umask 022
}
