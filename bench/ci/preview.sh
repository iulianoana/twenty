#!/usr/bin/env bash
# Preview workflows (bench/README.md, RUNNER-DESIGN §13).
# Usage: preview.sh deploy <branch> [sha] | action <branch> <action> | teardown <branch> | ops <command> [args]
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib.sh
source "$REPO_ROOT/bench/ci/lib.sh"

fleet_slug() {
  local branch=$1 slug
  [[ $branch == baseline/* || $branch == phase-1/* ]] || die "not a fleet branch: $branch"
  slug=$(slug_for_branch "$branch")
  [[ $slug =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "branch '$branch' does not give a valid DNS label"
  echo "$slug"
}

summary() { [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || echo "$*" >>"$GITHUB_STEP_SUMMARY"; }

public_health() {
  local url=$1 deadline=$((SECONDS + 120))
  until curl -fsS --max-time 10 -o /dev/null "$url/healthz"; do
    ((SECONDS < deadline)) || die "$url/healthz did not answer 200 from the runner"
    sleep 3
  done
}

report_result() {
  local output=$1 line
  line=$(grep '^BENCH_RESULT ' "$output" | tail -n1 | cut -d' ' -f2-)
  [[ -z $line ]] || summary "\`\`\`json
$line
\`\`\`"
  grep -E '^BENCH_(LOGOUT_PROOF|PROBE)' "$output" | while IFS= read -r line; do summary "- $line"; done || true
}

cmd_deploy() {
  local branch=$1 sha=${2:-} slug environment url start=$SECONDS out
  slug=$(fleet_slug "$branch")
  [[ -n $sha ]] || sha=$(gh api "repos/$GITHUB_REPOSITORY/branches/$(urlencode "$branch")" --jq .commit.sha)
  environment="preview-$slug"
  DEPLOYMENT_ID=$(create_deployment "$sha" "$environment")
  log "deployment $DEPLOYMENT_ID for $environment at $sha"
  post_status "$DEPLOYMENT_ID" in_progress
  DEPLOY_OK=0
  trap '[[ $DEPLOY_OK == 1 ]] || post_status "$DEPLOYMENT_ID" failure || true' EXIT
  connect_bench "$REPO_ROOT"
  url="https://$slug.$(dashed_ip "$BENCH_IP").sslip.io"
  out=$(mktemp)
  remote_bench deploy "$slug" "$branch" "$sha" | tee "$out"
  public_health "$url"
  post_status "$DEPLOYMENT_ID" success "$url"
  DEPLOY_OK=1
  echo "::notice::$environment ready at $url in $((SECONDS - start))s (sha ${sha:0:12})"
  summary "### $environment → $url ($((SECONDS - start))s in job)"
  report_result "$out"
}

cmd_action() {
  local branch=$1 action=$2 slug url out
  slug=$(fleet_slug "$branch")
  case $action in reset-db | rotate-auth-secret) ;; *) die "unknown action $action" ;; esac
  connect_bench "$REPO_ROOT"
  url="https://$slug.$(dashed_ip "$BENCH_IP").sslip.io"
  out=$(mktemp)
  remote_bench action "$slug" "$action" | tee "$out"
  public_health "$url"
  summary "### $action on $slug done"
  report_result "$out"
}

cmd_teardown() {
  local branch=$1 slug deployment_id
  slug=$(fleet_slug "$branch")
  connect_bench "$REPO_ROOT"
  remote_bench teardown "$slug"
  deployment_id=$(gh api "repos/$GITHUB_REPOSITORY/deployments?environment=preview-$slug&per_page=1" --jq '.[0].id // empty')
  if [[ -n $deployment_id ]]; then
    post_status "$deployment_id" inactive
    log "deployment $deployment_id marked inactive"
  else
    log "no deployment found for preview-$slug"
  fi
  summary "### preview-$slug torn down"
}

cmd_ops() {
  local command=$1 arg1=${2:-} arg2=${3:-} out
  connect_bench "$REPO_ROOT"
  out=$(mktemp)
  case $command in
    status) remote_bench status | tee "$out" ;;
    logs) remote_bench logs "$arg1" "${arg2:-200}" | tee "$out" ;;
    probe-login) remote_bench probe-login "$arg1" | tee "$out" ;;
    probe-create) remote_bench probe-create "$arg1" "$arg2" | tee "$out" ;;
    probe-find) remote_bench probe-find "$arg1" "$arg2" | tee "$out" ;;
    deploy-main) remote_bench deploy main main "$GITHUB_SHA" | tee "$out" ;;
    *) die "unknown ops command $command" ;;
  esac
  grep -E '^BENCH_' "$out" | while IFS= read -r line; do summary "- \`$line\`"; done || true
}

case ${1:-} in
  deploy) shift; cmd_deploy "$@" ;;
  action) shift; cmd_action "$@" ;;
  teardown) shift; cmd_teardown "$@" ;;
  ops) shift; cmd_ops "$@" ;;
  *) die "usage: preview.sh deploy|action|teardown|ops" ;;
esac
