# shellcheck shell=bash
# Sign-in and record probes against one environment, run on the box through Caddy's TLS.
# Tokens and passwords never reach the log.

gql() {
  local name=$1 endpoint=$2 body=$3 token=${4:-} host
  host=$(env_host "$name")
  local -a args=(-sS --max-time 30 --resolve "$host:443:127.0.0.1" -H 'Content-Type: application/json')
  [[ -z $token ]] || args+=(-H "Authorization: Bearer $token")
  curl "${args[@]}" --data-binary @- "https://$host/$endpoint" <<<"$body"
}

# Prints "<accessToken> <refreshToken>" for a seeded login (admin or member).
auth_tokens() {
  local name=$1 role=$2 email password origin body resp login_token
  load_bench_secrets
  case $role in
    admin) email=$ADMIN_EMAIL password=$ADMIN_PASSWORD ;;
    member) email=$MEMBER_EMAIL password=$MEMBER_PASSWORD ;;
    *) die "unknown role $role" ;;
  esac
  origin=$(env_url "$name")
  body=$(jq -nc --arg e "$email" --arg p "$password" --arg o "$origin" \
    '{query:"mutation($e:String!,$p:String!,$o:String!){getLoginTokenFromCredentials(email:$e,password:$p,origin:$o){loginToken{token}}}",variables:{e:$e,p:$p,o:$o}}')
  resp=$(gql "$name" metadata "$body")
  login_token=$(jq -r '.data.getLoginTokenFromCredentials.loginToken.token // empty' <<<"$resp")
  [[ -n $login_token ]] || { log "sign-in failed: $(jq -c '.errors[0].message // .' <<<"$resp" | cut -c1-200)"; return 1; }
  body=$(jq -nc --arg t "$login_token" --arg o "$origin" \
    '{query:"mutation($t:String!,$o:String!){getAuthTokensFromLoginToken(loginToken:$t,origin:$o){tokens{accessOrWorkspaceAgnosticToken{token} refreshToken{token}}}}",variables:{t:$t,o:$o}}')
  resp=$(gql "$name" metadata "$body")
  jq -re '.data.getAuthTokensFromLoginToken.tokens | "\(.accessOrWorkspaceAgnosticToken.token) \(.refreshToken.token)"' <<<"$resp" ||
    { log "token exchange failed: $(jq -c '.errors[0].message // .' <<<"$resp" | cut -c1-200)"; return 1; }
}

auth_refresh_token() {
  local tokens
  tokens=$(auth_tokens "$1" "$2") || return 1
  echo "${tokens#* }"
}

# Prints "ok" if the refresh token renews, else the server's error message.
try_renew() {
  local name=$1 refresh=$2 body resp
  body=$(jq -nc --arg t "$refresh" '{query:"mutation($t:String!){renewToken(appToken:$t){tokens{accessOrWorkspaceAgnosticToken{token}}}}",variables:{t:$t}}')
  resp=$(gql "$name" metadata "$body")
  if jq -e '.data.renewToken.tokens.accessOrWorkspaceAgnosticToken.token' <<<"$resp" >/dev/null 2>&1; then
    echo ok
  else
    jq -r '.errors[0].message // "no data"' <<<"$resp" | cut -c1-200
  fi
}

# Logout proof: the refresh token issued before the action is rejected, and signing in again works.
verify_logout() {
  local name=$1 before=$2 old_result after new_result
  old_result=$(try_renew "$name" "$before")
  after=$(auth_refresh_token "$name" member) || die "sign-in after logout failed"
  new_result=$(try_renew "$name" "$after")
  log "logout proof: pre-action refresh token -> '$old_result'; fresh sign-in refresh token -> '$new_result'"
  echo "BENCH_LOGOUT_PROOF pre_action_token=$([[ $old_result == ok ]] && echo accepted || echo rejected) fresh_token=$new_result"
  [[ $old_result != ok ]] || die "pre-action refresh token still renews"
  [[ $new_result == ok ]] || die "fresh refresh token does not renew"
}

probe_login() {
  local name=$1 role
  for role in admin member; do
    auth_tokens "$name" "$role" >/dev/null || die "$role sign-in failed on $name"
    echo "BENCH_PROBE login role=$role env=$name ok"
  done
}

# Creates a company named after the given marker; prints its id.
probe_create_company() {
  local name=$1 marker=$2 tokens access body resp id
  tokens=$(auth_tokens "$name" admin) || die "sign-in failed"
  access=${tokens%% *}
  body=$(jq -nc --arg n "$marker" '{query:"mutation($n:String){createCompany(data:{name:$n}){id name}}",variables:{n:$n}}')
  resp=$(gql "$name" graphql "$body" "$access")
  id=$(jq -r '.data.createCompany.id // empty' <<<"$resp")
  [[ -n $id ]] || die "createCompany failed: $(jq -c '.errors[0].message // .' <<<"$resp" | cut -c1-200)"
  echo "BENCH_PROBE created company id=$id name=$marker env=$name"
}

probe_find_company() {
  local name=$1 marker=$2 tokens access body resp count
  tokens=$(auth_tokens "$name" admin) || die "sign-in failed"
  access=${tokens%% *}
  body=$(jq -nc --arg n "$marker" '{query:"query($n:String){companies(filter:{name:{eq:$n}}){totalCount edges{node{id name createdAt}}}}",variables:{n:$n}}')
  resp=$(gql "$name" graphql "$body" "$access")
  count=$(jq -r '.data.companies.totalCount // empty' <<<"$resp")
  [[ -n $count ]] || die "companies query failed: $(jq -c '.errors[0].message // .' <<<"$resp" | cut -c1-200)"
  echo "BENCH_PROBE found $count company(ies) named $marker env=$name: $(jq -c '[.data.companies.edges[].node]' <<<"$resp")"
  [[ $count -ge 1 ]]
}
