# shellcheck shell=bash
# shellcheck disable=SC2034,SC2029
# Helpers for the bench-* workflows (GitHub-hosted runners): Hetzner lookup, SSH to the
# Twenty bench server, and GitHub deployment statuses.

# The only label selector this code lists, changes or deletes servers by.
TWENTY_SERVER_SELECTOR='outqube-bench=true,role=twenty'
TWENTY_SERVER_NAME=outqube-bench-twenty
HCLOUD_SSH_KEY_NAME=outqube-bench
PROTECTED_LABELS=(bench-box bench2-box bench-golden bench2-golden)
REMOTE_ROOT=/opt/twenty-bench

log() { printf '[bench-ci %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() {
  echo "::error::$*" >&2
  exit 1
}

require_secrets() {
  local missing=()
  [[ -n ${HCLOUD_TOKEN:-} ]] || missing+=(HCLOUD_TOKEN)
  [[ -n ${BENCH_SSH_PRIVATE_KEY:-} ]] || missing+=(BENCH_SSH_PRIVATE_KEY)
  [[ ${#missing[@]} == 0 ]] || die "missing Actions secrets: ${missing[*]}"
}

hcloud() {
  local method=$1 path=$2 data=${3:-}
  local -a args=(-sS -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" -H 'Content-Type: application/json')
  [[ -z $data ]] || args+=(--data-binary "$data")
  curl "${args[@]}" "https://api.hetzner.cloud/v1$path"
}

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# Prints the JSON array of servers matching TWENTY_SERVER_SELECTOR, after checking none carries a protected label.
twenty_servers() {
  local resp label
  resp=$(hcloud GET "/servers?label_selector=$(urlencode "$TWENTY_SERVER_SELECTOR")")
  jq -e '.servers' <<<"$resp" >/dev/null || die "Hetzner API error: $(jq -c '.error // .' <<<"$resp" | cut -c1-300)"
  for label in "${PROTECTED_LABELS[@]}"; do
    if jq -e --arg l "$label" '[.servers[] | select(.labels | has($l))] | length > 0' <<<"$resp" >/dev/null; then
      die "a server matching $TWENTY_SERVER_SELECTOR also carries protected label $label; refusing to continue"
    fi
  done
  jq -c '.servers' <<<"$resp"
}

twenty_server_ip() {
  local servers count
  servers=$(twenty_servers)
  count=$(jq length <<<"$servers")
  [[ $count == 1 ]] || die "expected exactly one server labelled $TWENTY_SERVER_SELECTOR, found $count (run bench-provision)"
  jq -r '.[0].public_net.ipv4.ip' <<<"$servers"
}

setup_ssh() {
  local ip=$1
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  printf '%s\n' "$BENCH_SSH_PRIVATE_KEY" >~/.ssh/bench_key
  chmod 600 ~/.ssh/bench_key
  cat >~/.ssh/config <<EOF
Host bench
  HostName $ip
  User root
  IdentityFile ~/.ssh/bench_key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts_bench
  ServerAliveInterval 30
  ServerAliveCountMax 10
  ConnectTimeout 15
  LogLevel ERROR
EOF
}

wait_for_ssh() {
  local deadline=$((SECONDS + ${1:-300}))
  until ssh -o BatchMode=yes bench true 2>/dev/null; do
    ((SECONDS < deadline)) || die "SSH to the bench server did not come up"
    sleep 5
  done
}

# Ships bench/box to the server as a new versioned dir and swaps the infra symlink atomically.
sync_infra() {
  local repo_root=$1 version
  version="$(date -u +%Y%m%d%H%M%S)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
  tar -C "$repo_root/bench" -czf - box | ssh bench "set -e
    mkdir -p $REMOTE_ROOT/infra-versions/$version
    tar -xzf - -C $REMOTE_ROOT/infra-versions/$version
    chmod +x $REMOTE_ROOT/infra-versions/$version/box/bench
    ln -sfn infra-versions/$version $REMOTE_ROOT/infra.new
    mv -T $REMOTE_ROOT/infra.new $REMOTE_ROOT/infra
    cd $REMOTE_ROOT/infra-versions && ls -1t | tail -n +6 | xargs -r rm -rf"
}

remote_bench() {
  ssh bench "$REMOTE_ROOT/infra/box/bench $(printf '%q ' "$@")"
}

connect_bench() {
  require_secrets
  local ip
  ip=$(twenty_server_ip)
  BENCH_IP=$ip
  setup_ssh "$ip"
  wait_for_ssh 120
  sync_infra "$1"
}

slug_for_branch() { printf '%s' "${1//\//-}"; }

dashed_ip() { printf '%s' "${1//./-}"; }

# --- GitHub deployments (GH_TOKEN = the job's GITHUB_TOKEN) ---

create_deployment() {
  local sha=$1 environment=$2
  gh api -X POST "repos/$GITHUB_REPOSITORY/deployments" --input - --jq .id <<EOF
{"ref":"$sha","environment":"$environment","auto_merge":false,"required_contexts":[],"transient_environment":true,"description":"Twenty bench preview"}
EOF
}

post_status() {
  local deployment_id=$1 state=$2 environment_url=${3:-} body
  body=$(jq -nc --arg s "$state" --arg e "$environment_url" --arg l "$RUN_URL" \
    '{state:$s,log_url:$l} + (if $e == "" then {} else {environment_url:$e} end)')
  gh api -X POST "repos/$GITHUB_REPOSITORY/deployments/$deployment_id/statuses" --input - --jq .state <<<"$body" >/dev/null
}

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
