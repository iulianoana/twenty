#!/usr/bin/env bash
# bench-provision workflow: find or create the one Twenty bench server, then run `bench provision` on it.
# Usage: provision.sh provision <server_type> <location> | list | destroy <confirm_name>
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib.sh
source "$REPO_ROOT/bench/ci/lib.sh"

ssh_key_id() {
  local resp id fingerprint ours
  resp=$(hcloud GET "/ssh_keys?name=$(urlencode "$HCLOUD_SSH_KEY_NAME")")
  id=$(jq -r '.ssh_keys[0].id // empty' <<<"$resp")
  [[ -n $id ]] || die "Hetzner SSH key '$HCLOUD_SSH_KEY_NAME' not found (it must already exist; this workflow never creates keys)"
  fingerprint=$(jq -r '.ssh_keys[0].fingerprint' <<<"$resp")
  ours=$(ssh-keygen -y -f ~/.ssh/bench_key | ssh-keygen -l -E md5 -f - | awk '{print $2}' | sed 's/^MD5://')
  [[ $fingerprint == "$ours" ]] || die "BENCH_SSH_PRIVATE_KEY does not match Hetzner key '$HCLOUD_SSH_KEY_NAME'"
  echo "$id"
}

# Tries each comma-separated server type once, in order; a limit error moves on to the next type.
create_server() {
  local server_types=$1 first_location=$2 key_id server_type location body resp code
  key_id=$(ssh_key_id)
  IFS=, read -ra types <<<"$server_types"
  for server_type in "${types[@]}"; do
    for location in "$first_location" fsn1 nbg1 hel1; do
      body=$(jq -nc --arg n "$TWENTY_SERVER_NAME" --arg t "$server_type" --arg l "$location" --argjson k "$key_id" \
        '{name:$n,server_type:$t,image:"ubuntu-24.04",location:$l,ssh_keys:[$k],start_after_create:true,
          labels:{"outqube-bench":"true",role:"twenty"},public_net:{enable_ipv4:true,enable_ipv6:true}}')
      log "creating $server_type in $location"
      resp=$(hcloud POST /servers "$body")
      if jq -e '.server.id' <<<"$resp" >/dev/null; then
        CREATED_ID=$(jq -r '.server.id' <<<"$resp")
        echo "::notice::created server $CREATED_ID type=$server_type location=$location"
        return 0
      fi
      code=$(jq -r '.error.code // "unknown"' <<<"$resp")
      log "create failed: $code: $(jq -r '.error.message // ""' <<<"$resp" | cut -c1-300)"
      echo "::warning::$server_type: $code: $(jq -r '.error.message // ""' <<<"$resp" | cut -c1-200)"
      # A location without capacity is worth another location; a quota error moves to the next type.
      [[ $code == resource_unavailable ]] && continue
      [[ $code == resource_limit_exceeded ]] && break
      die "server creation failed ($code); not retrying"
    done
  done
  die "no server created: every type in '$server_types' hit a limit (quotas are shared with production evals)"
}

wait_running() {
  local id=$1 deadline=$((SECONDS + 300)) status
  while true; do
    status=$(hcloud GET "/servers/$id" | jq -r '.server.status')
    [[ $status == running ]] && return 0
    ((SECONDS < deadline)) || die "server $id stuck in status $status"
    sleep 5
  done
}

cmd_provision() {
  local server_type=${1:-cx53,cpx52,cx43} location=${2:-fsn1} servers count id ip start
  require_secrets
  start=$SECONDS
  setup_ssh 0.0.0.0
  servers=$(twenty_servers)
  count=$(jq length <<<"$servers")
  ((count <= 1)) || die "found $count servers labelled $TWENTY_SERVER_SELECTOR; expected at most one"
  if [[ $count == 0 ]]; then
    create_server "$server_type" "$location"
    id=$CREATED_ID
    wait_running "$id"
  else
    id=$(jq -r '.[0].id' <<<"$servers")
    log "reusing server $id ($(jq -r '.[0].server_type.name' <<<"$servers"), created $(jq -r '.[0].created' <<<"$servers"))"
  fi
  servers=$(twenty_servers)
  ip=$(jq -r '.[0].public_net.ipv4.ip' <<<"$servers")
  echo "::notice::Twenty bench server id=$id ip=$ip type=$(jq -r '.[0].server_type.name' <<<"$servers") location=$(jq -r '.[0].datacenter.location.name' <<<"$servers")"
  setup_ssh "$ip"
  wait_for_ssh 600
  sync_infra "$REPO_ROOT"
  remote_bench provision --ip "$ip" --main-sha "$GITHUB_SHA" ${RESEED:+--reseed}
  echo "::notice::provision finished in $((SECONDS - start))s; main=https://main.$(dashed_ip "$ip").sslip.io"
}

cmd_list() {
  require_secrets
  hcloud GET '/server_types?per_page=50' | jq -r '.server_types[] | select(.deprecation == null and .cores >= 8 and .architecture == "x86")
    | "type \(.name) \(.cpu_type) cores=\(.cores) mem=\(.memory)GB disk=\(.disk)GB eur_hourly=\(.prices[0].price_hourly.gross | tonumber * 1000 | round / 1000) locations=\([.prices[].location] | join(","))"'
  twenty_servers | jq -r '.[] | "server id=\(.id) name=\(.name) type=\(.server_type.name) ip=\(.public_net.ipv4.ip) labels=\(.labels|tojson) created=\(.created)"'
}

# Read-only inventory of the whole Hetzner project (GET requests only).
cmd_inventory() {
  require_secrets
  local servers ips snapshots
  servers=$(hcloud GET '/servers?per_page=50')
  ips=$(hcloud GET '/primary_ips?per_page=50')
  snapshots=$(hcloud GET '/images?type=snapshot&per_page=50')
  echo "== servers"
  jq -r '.servers[] | "server name=\(.name) id=\(.id) type=\(.server_type.name) cpu=\(.server_type.cpu_type) cores=\(.server_type.cores) status=\(.status) has_ipv4=\(.public_net.ipv4 != null) location=\(.datacenter.location.name) created=\(.created) labels=\(.labels|tojson)"' <<<"$servers"
  echo "== primary IPs"
  jq -r --argjson s "$servers" '($s.servers | map({key: (.id|tostring), value: .name}) | from_entries) as $names
    | .primary_ips[] | "primary_ip name=\(.name) id=\(.id) type=\(.type) assigned=\(.assignee_id != null) server=\(if .assignee_id then ($names[(.assignee_id|tostring)] // (.assignee_id|tostring)) else "-" end) auto_delete=\(.auto_delete) location=\(.datacenter.location.name // .location.name // "?") created=\(.created) labels=\(.labels|tojson)"' <<<"$ips"
  echo "== snapshots by label"
  jq -r '[.images[] | (.labels | to_entries | map("\(.key)=\(.value)") | join(",")) | if . == "" then "(no labels)" else . end] | group_by(.) | .[] | "snapshots \(length) labels=\(.[0])"' <<<"$snapshots"
  echo "== totals"
  jq -r '"servers=\(.servers|length) shared_cores=\([.servers[] | select(.server_type.cpu_type == "shared") | .server_type.cores] | add // 0) dedicated_cores=\([.servers[] | select(.server_type.cpu_type == "dedicated") | .server_type.cores] | add // 0)"' <<<"$servers"
  jq -r '"primary_ipv4=\([.primary_ips[] | select(.type == "ipv4")] | length) assigned_ipv4=\([.primary_ips[] | select(.type == "ipv4" and .assignee_id != null)] | length) unassigned_ipv4=\([.primary_ips[] | select(.type == "ipv4" and .assignee_id == null)] | length) primary_ipv6=\([.primary_ips[] | select(.type == "ipv6")] | length)"' <<<"$ips"
  jq -r '"pagination servers_total=\(.meta.pagination.total_entries // "?")"' <<<"$servers"
  jq -r '"pagination primary_ips_total=\(.meta.pagination.total_entries // "?")"' <<<"$ips"
}

# Deletes the labelled server only when the operator types its exact name; always lists first.
cmd_destroy() {
  local confirm=${1:-} servers count name id
  require_secrets
  servers=$(twenty_servers)
  count=$(jq length <<<"$servers")
  log "dry run: servers matching $TWENTY_SERVER_SELECTOR:"
  cmd_list
  [[ $count == 1 ]] || die "expected exactly one server to destroy, found $count"
  name=$(jq -r '.[0].name' <<<"$servers")
  id=$(jq -r '.[0].id' <<<"$servers")
  jq -e '.[0].labels["outqube-bench"] == "true" and .[0].labels.role == "twenty"' <<<"$servers" >/dev/null ||
    die "label check failed"
  [[ $confirm == "$name" ]] || { log "not deleting: confirm input '$confirm' != server name '$name'"; return 0; }
  hcloud DELETE "/servers/$id" | jq -c '.action | {command, status}'
  echo "::notice::deleted server $id ($name)"
}

case ${1:-} in
  provision) shift; cmd_provision "$@" ;;
  list) cmd_list ;;
  inventory) cmd_inventory ;;
  destroy) shift; cmd_destroy "$@" ;;
  *) die "usage: provision.sh provision|list|destroy" ;;
esac
