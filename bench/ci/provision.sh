#!/usr/bin/env bash
# bench-provision workflow: find or create the one Twenty bench server, then run `bench provision` on it.
# Usage: provision.sh provision <server_types> <location> | list | inventory | destroy <confirm_name>
# Env: PRIMARY_IPV4_NAME (approved parked IPv4 to create the server on), RESEED.
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib.sh
source "$REPO_ROOT/bench/ci/lib.sh"

TWENTY_FIREWALL_NAME=outqube-bench-twenty

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

# Our own firewall (never the existing outqube-bench one): SSH, HTTP, HTTPS and ICMP in.
firewall_id() {
  local resp id body
  resp=$(hcloud GET "/firewalls?name=$(urlencode "$TWENTY_FIREWALL_NAME")")
  id=$(jq -r '.firewalls[0].id // empty' <<<"$resp")
  if [[ -n $id ]]; then
    jq -e '.firewalls[0].labels["outqube-bench"] == "true" and .firewalls[0].labels.role == "twenty"' <<<"$resp" >/dev/null ||
      die "firewall $TWENTY_FIREWALL_NAME exists without our labels; not using it"
    echo "$id"
    return
  fi
  body=$(jq -nc --arg n "$TWENTY_FIREWALL_NAME" '{name:$n,labels:{"outqube-bench":"true",role:"twenty"},rules:
    (([22,80,443] | map({direction:"in",protocol:"tcp",port:(tostring),source_ips:["0.0.0.0/0","::/0"]}))
    + [{direction:"in",protocol:"icmp",source_ips:["0.0.0.0/0","::/0"]}])}')
  resp=$(hcloud POST /firewalls "$body")
  id=$(jq -r '.firewall.id // empty' <<<"$resp")
  [[ -n $id ]] || die "firewall creation failed: $(jq -c '.error // .' <<<"$resp" | cut -c1-300)"
  echo "::notice::created firewall $TWENTY_FIREWALL_NAME ($id)" >&2
  echo "$id"
}

# Prints the parked IPv4 as JSON after checking it is unassigned and keeps auto_delete=false.
parked_ipv4() {
  local name=$1 resp
  resp=$(hcloud GET "/primary_ips?name=$(urlencode "$name")")
  jq -e '.primary_ips | length == 1' <<<"$resp" >/dev/null || die "primary IP '$name' not found"
  echo "::add-mask::$(jq -r '.primary_ips[0].ip' <<<"$resp")" >&2
  jq -e '.primary_ips[0] | .type == "ipv4" and .assignee_id == null and .auto_delete == false' <<<"$resp" >/dev/null ||
    die "primary IP '$name' is not a parked IPv4 with auto_delete=false; not using it"
  jq -c '.primary_ips[0] | {id, name, labels, auto_delete, location: (.location.name // .datacenter.location.name)}' <<<"$resp"
}

# The borrowed IP must come back exactly as it was: unassigned, same labels, auto_delete=false.
check_parked_ipv4() {
  local expected=$1 id resp
  id=$(jq -r .id <<<"$expected")
  resp=$(hcloud GET "/primary_ips/$id")
  if jq -e --argjson e "$expected" '.primary_ip | .assignee_id == null and .auto_delete == false and .labels == $e.labels and .name == $e.name' <<<"$resp" >/dev/null; then
    echo "::notice::primary IP $(jq -r .name <<<"$expected") still exists, unassigned, labels $(jq -c .labels <<<"$expected"), auto_delete=false"
  else
    die "primary IP check failed after teardown: $(jq -c '.primary_ip | {name, assigned: (.assignee_id != null), labels, auto_delete} // .error' <<<"$resp")"
  fi
}

try_create() {
  local body=$1 server_type=$2 location=$3 resp
  resp=$(hcloud POST /servers "$body")
  if jq -e '.server.id' <<<"$resp" >/dev/null; then
    CREATED_ID=$(jq -r '.server.id' <<<"$resp")
    echo "::notice::created server $CREATED_ID type=$server_type location=$location ipv6=$(jq -r .public_net.enable_ipv6 <<<"$body")"
    return 0
  fi
  CREATE_CODE=$(jq -r '.error.code // "unknown"' <<<"$resp")
  CREATE_MESSAGE=$(jq -r '.error.message // ""' <<<"$resp" | cut -c1-200)
  echo "::warning::$server_type in $location: $CREATE_CODE: $CREATE_MESSAGE"
  return 1
}

# Tries each comma-separated server type once, in order; a limit error moves on to the next type.
create_server() {
  local server_types=$1 first_location=$2 key_id fw_id server_type location body public_net parked=""
  key_id=$(ssh_key_id)
  fw_id=$(firewall_id)
  local locations=("$first_location" fsn1 nbg1 hel1)
  if [[ -n ${PRIMARY_IPV4_NAME:-} ]]; then
    # Approved borrowing: the parked IP is only assigned through server creation, never modified.
    parked=$(parked_ipv4 "$PRIMARY_IPV4_NAME")
    locations=("$(jq -r .location <<<"$parked")")
    log "using parked primary IPv4 $(jq -r .name <<<"$parked") in ${locations[0]}"
  fi
  IFS=, read -ra types <<<"$server_types"
  for server_type in "${types[@]}"; do
    for location in "${locations[@]}"; do
      if [[ -n $parked ]]; then
        public_net=$(jq -nc --argjson id "$(jq .id <<<"$parked")" '{enable_ipv4:true,enable_ipv6:true,ipv4:$id}')
      else
        public_net='{"enable_ipv4":true,"enable_ipv6":true}'
      fi
      body=$(jq -nc --arg n "$TWENTY_SERVER_NAME" --arg t "$server_type" --arg l "$location" --argjson k "$key_id" \
        --argjson p "$public_net" --argjson f "$fw_id" \
        '{name:$n,server_type:$t,image:"ubuntu-24.04",location:$l,ssh_keys:[$k],start_after_create:true,
          labels:{"outqube-bench":"true",role:"twenty"},public_net:$p,firewalls:[{firewall:$f}]}')
      log "creating $server_type in $location"
      try_create "$body" "$server_type" "$location" && return 0
      # A new IPv6 primary IP also counts against the primary IP limit: retry this type once without it.
      if [[ $CREATE_CODE == resource_limit_exceeded && $CREATE_MESSAGE == *"Primary IP"* ]]; then
        log "retrying $server_type without IPv6"
        try_create "$(jq -c '.public_net.enable_ipv6 = false' <<<"$body")" "$server_type" "$location" && return 0
      fi
      [[ $CREATE_CODE == resource_unavailable && -z $parked ]] && continue
      [[ $CREATE_CODE == resource_limit_exceeded ]] && break
      die "server creation failed ($CREATE_CODE); not retrying"
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
  local server_type=${1:-ccx33} location=${2:-fsn1} servers count id ip start
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
  ip=$(twenty_server_ip)
  mask_ip "$ip"
  echo "::notice::Twenty bench server id=$id type=$(jq -r '.[0].server_type.name' <<<"$(twenty_servers)")"
  setup_ssh "$ip"
  wait_for_ssh 600
  sync_infra "$REPO_ROOT"
  remote_bench provision --ip "$ip" --main-sha "$GITHUB_SHA" ${RESEED:+--reseed}
  echo "::notice::provision finished in $((SECONDS - start))s"
}

cmd_list() {
  require_secrets
  hcloud GET '/server_types?per_page=50' | jq -r '.server_types[] | select(.deprecation == null and .cores >= 8 and .architecture == "x86")
    | "type \(.name) \(.cpu_type) cores=\(.cores) mem=\(.memory)GB disk=\(.disk)GB locations=\([.prices[].location] | join(","))"'
  twenty_servers | jq -r '.[] | "server id=\(.id) name=\(.name) type=\(.server_type.name) status=\(.status) primary_ipv4_id=\(.public_net.ipv4.id // "-") labels=\(.labels|tojson) created=\(.created)"'
}

# Read-only inventory of the whole Hetzner project (GET requests only, no addresses printed).
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
}

# Deletes only our labelled server, and only when the operator types its exact name; always lists
# first, then checks the borrowed primary IPv4 is back to parked with its labels and auto_delete=false.
cmd_destroy() {
  local confirm=${1:-} servers count name id ipv4_id expected="" action status deadline
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
  ipv4_id=$(jq -r '.[0].public_net.ipv4.id // empty' <<<"$servers")
  if [[ -n $ipv4_id ]]; then
    expected=$(hcloud GET "/primary_ips/$ipv4_id" | jq -c '.primary_ip | {id, name, labels, auto_delete}')
    log "server uses primary IPv4 $(jq -c . <<<"$expected")"
  fi
  [[ $confirm == "$name" ]] || { log "not deleting: confirm input '$confirm' != server name '$name'"; return 0; }
  action=$(hcloud DELETE "/servers/$id" | jq -r '.action.id')
  deadline=$((SECONDS + 300))
  while true; do
    status=$(hcloud GET "/actions/$action" | jq -r '.action.status')
    [[ $status == success ]] && break
    [[ $status == error ]] && die "server delete action failed"
    ((SECONDS < deadline)) || die "server delete did not finish"
    sleep 5
  done
  echo "::notice::deleted server $id ($name)"
  if [[ -n $expected ]]; then
    if [[ $(jq -r .auto_delete <<<"$expected") == true ]]; then
      log "primary IPv4 had auto_delete=true (created with the server); it is deleted with it"
    else
      check_parked_ipv4 "$expected"
    fi
  fi
}

case ${1:-} in
  provision) shift; cmd_provision "$@" ;;
  list) cmd_list ;;
  inventory) cmd_inventory ;;
  destroy) shift; cmd_destroy "$@" ;;
  *) die "usage: provision.sh provision|list|inventory|destroy" ;;
esac
