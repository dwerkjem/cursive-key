# shellcheck shell=bash
# Check helpers for issue #16, sourced by wizard.sh. Every resource this
# creates is named with the "ck16-" prefix so teardown can find it.
#
# Results are appended to results/results.json (gitignored). Raw API
# responses go to results/raw/.

RESULTS=results/results.json
RAW=results/raw
JAR=results/raw/cookies.txt

ck_init_results() {
  mkdir -p "$RAW"
  [[ -s "$RESULTS" ]] || echo '[]' > "$RESULTS"
}

# record CHECK LABEL JSON appends one observation. Non-JSON is stored as text.
record() {
  local tmp value="$3"
  { [[ -n "$value" ]] && jq . >/dev/null 2>&1 <<<"$value"; } || value=$(jq -Rn --arg v "$3" '$v')
  tmp=$(mktemp)
  jq --arg c "$1" --arg l "$2" --argjson v "$value" --arg t "$(date -u +%FT%TZ)" \
    '. + [{check: $c, label: $l, at: $t, observed: $v}]' "$RESULTS" > "$tmp" && mv "$tmp" "$RESULTS"
}

# want "Question" is a Y/n gate (default yes), for stages a re-run may skip.
want() {
  local reply=""
  printf '  %s? %s [Y/n] ' "$YELLOW" "$1"
  read -r reply || true
  [[ ! "$reply" =~ ^[Nn] ]]
}

# countdown SECONDS "why"
countdown() {
  local s=$1
  while (( s > 0 )); do printf '\r  %swaiting %3ss: %s%s ' "$DIM" "$s" "$2" "$RESET"; sleep 5; s=$((s - 5)); done
  printf '\r%60s\r' ''
}

wr() { CLOUDFLARE_ACCOUNT_ID="${CK_ACCOUNT_ID:-}" npx --no-install wrangler "$@"; }

# ── Cloudflare API ────────────────────────────────────────────────────────

# cf METHOD PATH [JSON] calls /accounts/{id}PATH with the check token.
cf() {
  local args=(-sS -X "$1" "https://api.cloudflare.com/client/v4/accounts/${CK_ACCOUNT_ID}$2"
    -H "Authorization: Bearer ${CK_API_TOKEN}")
  [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' --data "$3")
  curl "${args[@]}" || echo '{"success":false,"errors":[{"message":"curl failed"}]}'
}
cf_ok()  { jq -e '.success == true' >/dev/null 2>&1 <<<"$1"; }
cf_err() { jq -c '.errors // .' 2>/dev/null <<<"$1" || printf '%s' "$1"; }

graphql() { # QUERY VARIABLES_JSON
  local body
  body=$(jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')
  curl -sS https://api.cloudflare.com/client/v4/graphql \
    -H "Authorization: Bearer ${CK_API_TOKEN}" -H 'Content-Type: application/json' --data "$body"
}

ck_preflight() {
  local failed=0 name path out
  for pair in "Access apps|/access/apps" "Access policies|/access/policies" \
              "Service tokens|/access/service_tokens" "Zero Trust org|/access/organizations" \
              "Users and seats|/access/users"; do
    name=${pair%%|*}; path=${pair#*|}
    out=$(cf GET "$path")
    if cf_ok "$out"; then printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$name"
    else warn "$name refused: $(cf_err "$out")"; failed=1; fi
  done
  out=$(graphql 'query($a: String!) { viewer { accounts(filter: {accountTag: $a}) { accountTag } } }' \
    "$(jq -nc --arg a "$CK_ACCOUNT_ID" '{a: $a}')")
  if jq -e '.errors == null and .data.viewer.accounts[0].accountTag != null' >/dev/null 2>&1 <<<"$out"; then
    printf '  %s✓%s Analytics (GraphQL)\n' "$GREEN" "$RESET"
  else warn "Analytics refused: $(jq -c '.errors' <<<"$out" 2>/dev/null)"; failed=1; fi
  return $failed
}

# ck_policy NAME DECISION INCLUDE_JSON prints the new reusable policy's id.
ck_policy() {
  local body out
  body=$(jq -nc --arg n "$1" --arg d "$2" --argjson i "$3" '{name: $n, decision: $d, include: $i}')
  out=$(cf POST /access/policies "$body")
  printf '%s\n' "$out" > "$RAW/policy-$1.json"
  if ! cf_ok "$out"; then warn "policy $1 failed: $(cf_err "$out")"; return 1; fi
  jq -r '.result.id' <<<"$out"
}

# ck_policy_exists ID
ck_policy_exists() { [[ -n "${1:-}" ]] && cf_ok "$(cf GET "/access/policies/$1")"; }

# ck_app NAME DOMAIN POLICY_ID... creates a self-hosted app. Records the
# domain Cloudflare stored, since normalisation (e.g. a trailing "/") is
# itself part of check 1.
ck_app() {
  local name=$1 domain=$2; shift 2
  local pols body out
  pols=$(printf '%s\n' "$@" | jq -R . | jq -sc 'to_entries | map({id: .value, precedence: (.key + 1)})')
  body=$(jq -nc --arg n "$name" --arg d "$domain" --argjson p "$pols" \
    '{name: $n, type: "self_hosted", domain: $d, session_duration: "1h", app_launcher_visible: false, policies: $p}')
  out=$(cf POST /access/apps "$body")
  printf '%s\n' "$out" > "$RAW/app-$name.json"
  record "api" "create app $name" "$(jq -c --arg asked "$domain" \
    '{asked: $asked, ok: .success, stored_domain: .result.domain, destinations: .result.destinations, errors: .errors}' <<<"$out")"
  if cf_ok "$out"; then
    printf '  %s✓%s app %s → %s\n' "$GREEN" "$RESET" "$name" "$(jq -r '.result.domain' <<<"$out")"
  else
    warn "app $name ($domain) refused: $(cf_err "$out")"; return 1
  fi
}

# ck_delete_named KIND PREFIX deletes every apps/policies/service_tokens entry
# whose name starts with PREFIX.
ck_delete_named() {
  local kind=$1 prefix=$2 out id name
  out=$(cf GET "/access/$kind")
  cf_ok "$out" || { warn "couldn't list $kind: $(cf_err "$out")"; return 1; }
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" ]] && continue
    if cf_ok "$(cf DELETE "/access/$kind/$id")"; then note "deleted $kind $name"
    else warn "couldn't delete $kind $name ($id)"; fi
  done < <(jq -r --arg p "$prefix" '.result[]? | select(.name | startswith($p)) | [.id, .name] | @tsv' <<<"$out")
}

# ── Probing ───────────────────────────────────────────────────────────────

# classify STATUS LOCATION BODYFILE
classify() {
  case "$1" in
    30[1278])
      if [[ "$2" == *cloudflareaccess.com* || "$2" == */cdn-cgi/access/* ]]; then echo GATED
      else echo REDIRECT; fi ;;
    200) if grep -q CK16-MARKER "$3"; then echo OPEN; else echo "200-NO-MARKER"; fi ;;
    401|403) echo BLOCKED ;;
    *) echo "OTHER-$1" ;;
  esac
}

# probe CHECK LABEL METHOD PATH [none|token|cookie] [BASE]
# Prints one table row and records the full observation.
probe() {
  local check=$1 label=$2 method=$3 path=$4 auth=${5:-none} base=${6:-https://$CK_HOST}
  local hdr body code loc cls saw echo_json args
  hdr=$(mktemp); body=$(mktemp)
  args=(-s -o "$body" -D "$hdr" -w '%{http_code}' -X "$method" --max-time 20)
  [[ "$method" == POST ]] && args+=(-H 'Content-Type: application/json' --data '{"email":"probe@example.invalid"}')
  case "$auth" in
    token)  args+=(-H "CF-Access-Client-Id: $CK_SVC_CLIENT_ID" -H "CF-Access-Client-Secret: $CK_SVC_CLIENT_SECRET" -c "$JAR") ;;
    cookie) args+=(-b "$JAR") ;;
  esac
  code=$(curl "${args[@]}" "$base$path") || code=000
  loc=$(grep -i '^location:' "$hdr" | tail -n1 | cut -d' ' -f2- | tr -d '\r' || true)
  saw=$(grep -i '^x-ck16-saw-jwt:' "$hdr" | cut -d' ' -f2- | tr -d '\r' || true)
  cls=$(classify "$code" "$loc" "$body"); LAST_CLASS=$cls
  echo_json=$(jq -c . "$body" 2>/dev/null || true)
  { [[ -n "$echo_json" ]] && jq . >/dev/null 2>&1 <<<"$echo_json"; } || echo_json=null
  printf '  %-9s %-6s %-6s %-30s %s%s\n' "$cls" "$method" "$auth" "$path" \
    "$( [[ -n "$saw" ]] && echo "worker saw JWT: $saw" )" \
    "$( [[ "$echo_json" != null ]] && jq -r '"jwt header: \(.jwtHeader | tostring)  CF_Authorization cookie: \(.cfAuthorizationCookie | tostring)"' <<<"$echo_json" 2>/dev/null )"
  record "$check" "$label" "$(jq -nc --arg m "$method" --arg p "$path" --arg a "$auth" --arg s "$code" \
    --arg l "$loc" --arg c "$cls" --arg w "$saw" --argjson e "$echo_json" \
    '{method: $m, path: $p, auth: $a, status: ($s | tonumber? // $s), location: $l, class: $c, worker_saw_jwt: $w, echo: $e}')"
  rm -f "$hdr" "$body"
}

# wait_for PATH CLASS TIMEOUT: poll until PATH (no auth) classifies as CLASS.
wait_for() {
  local path=$1 want_cls=$2 timeout=$3 waited=0 hdr body code loc cls
  hdr=$(mktemp); body=$(mktemp)
  while (( waited <= timeout )); do
    code=$(curl -s -o "$body" -D "$hdr" -w '%{http_code}' --max-time 15 "https://$CK_HOST$path") || code=000
    loc=$(grep -i '^location:' "$hdr" | tail -n1 | cut -d' ' -f2- | tr -d '\r' || true)
    cls=$(classify "$code" "$loc" "$body")
    printf '\r  %swaiting for %s to be %s: now %s (%ss)%s   ' "$DIM" "$path" "$want_cls" "$cls" "$waited" "$RESET"
    if [[ "$cls" == "$want_cls" ]]; then printf '\n'; rm -f "$hdr" "$body"; return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  printf '\n'; warn "$path never became $want_cls within ${timeout}s (last: $cls)"
  rm -f "$hdr" "$body"; return 1
}

table_head() { printf '  %s%-9s %-6s %-6s %-30s %s%s\n' "$BOLD" CLASS METHOD AUTH PATH NOTES "$RESET"; }

# hits TAG_PREFIX reads the Worker's D1 log for browser visits.
hits() {
  local out
  out=$(wr d1 execute ck16-db --remote --json \
    --command "SELECT ts, tag, path, method, jwt_header, jwt_type, jwt_email IS NOT NULL AS has_email, cookie_names, cf_auth_cookie FROM hits WHERE tag LIKE '$1%' ORDER BY ts" 2>/dev/null) || true
  jq -c '.[0].results // []' <<<"$out" 2>/dev/null || echo '[]'
}

# ── Gate layouts (check 1, plus checks 2, 3 and 5 on each) ───────────────

H() { printf '%s%s' "$CK_HOST" "$1"; }

# Layout A: whole host gated, Bypass app on exactly "/".
layout_a() {
  ck_delete_named apps ck16-A- >/dev/null
  rm -f "$JAR"
  say "Gating the whole host first..."
  ck_app ck16-A-gate "$CK_HOST" "$CK_POL_ALLOW" "$CK_POL_TOKEN" || return 1
  wait_for /secret/ GATED 180 || record check1 "A: gate never applied" '"timeout"'
  say "Adding a Bypass app on exactly '/'..."
  if ck_app ck16-A-root "$(H /)" "$CK_POL_BYPASS"; then
    wait_for / OPEN 120 || record check1 "A: / never opened" '"timeout"'
  fi
  countdown 20 "letting Access settle"
  table_head
  for p in / /index.html /welcome/ /_astro/app.css /secret/ /learn/ /api/echo /anything; do
    probe check1 "A: $p" GET "$p"
  done
  probe check2 "A: JWT reaches Worker route (service token)" GET /api/echo token
  probe check2 "A: JWT reaches run_worker_first asset (service token)" GET /secret/ token
  probe check5 "A: Allow + Service Auth on one app (service token)" GET /learn/ token
}

# Layout B: whole host gated, Bypass apps for /welcome, assets and the form.
layout_b() {
  ck_delete_named apps ck16-B- >/dev/null
  rm -f "$JAR"
  say "Gating the whole host first..."
  ck_app ck16-B-gate "$CK_HOST" "$CK_POL_ALLOW" "$CK_POL_TOKEN" || return 1
  wait_for /secret/ GATED 180 || record check1 "B: gate never applied" '"timeout"'
  say "Adding Bypass apps..."
  ck_app ck16-B-welcome      "$(H /welcome)"             "$CK_POL_BYPASS"
  ck_app ck16-B-welcome-star "$(H '/welcome/*')"         "$CK_POL_BYPASS"
  ck_app ck16-B-assets       "$(H '/_astro/*')"          "$CK_POL_BYPASS"
  ck_app ck16-B-form         "$(H /api/access-requests)" "$CK_POL_BYPASS"
  wait_for /welcome/ OPEN 120 || record check1 "B: /welcome/ never opened" '"timeout"'
  countdown 20 "letting Access settle"
  table_head
  for p in / /welcome /welcome/ /_astro/app.css /api/access-requests /secret/ /learn/ /api/echo; do
    probe check1 "B: $p" GET "$p"
  done
  probe check1 "B: form POST" POST /api/access-requests
  probe check2 "B: JWT reaches Worker route (service token)" GET /api/echo token
  probe check2 "B: JWT reaches run_worker_first asset (service token)" GET /secret/ token
  probe check5 "B: Allow + Service Auth on one app (service token)" GET /learn/ token
  record check3 "B: service token set a CF_Authorization cookie" \
    "$(grep -q CF_Authorization "$JAR" 2>/dev/null && echo true || echo false)"
  probe check3 "B: cookie sent to Bypass path" GET /api/access-requests cookie
}

# Layout C: only prefixes gated; everything else public by default.
layout_c() {
  ck_delete_named apps ck16-C- >/dev/null
  rm -f "$JAR"
  say "Gating /learn and /api/* ..."
  ck_app ck16-C-learn      "$(H /learn)"    "$CK_POL_ALLOW" "$CK_POL_TOKEN" || return 1
  ck_app ck16-C-learn-star "$(H '/learn/*')" "$CK_POL_ALLOW" "$CK_POL_TOKEN"
  ck_app ck16-C-api        "$(H '/api/*')"   "$CK_POL_ALLOW" "$CK_POL_TOKEN"
  wait_for /learn/ GATED 180 || record check1 "C: gate never applied" '"timeout"'
  say "Adding a Bypass app for the form inside /api/* ..."
  ck_app ck16-C-form "$(H /api/access-requests)" "$CK_POL_BYPASS"
  wait_for /api/access-requests OPEN 120 || record check1 "C: form never opened" '"timeout"'
  countdown 20 "letting Access settle"
  table_head
  for p in / /welcome/ /_astro/app.css /secret/ /learn /learn/ /api/echo /api/access-requests /uncovered/echo; do
    probe check1 "C: $p" GET "$p"
  done
  probe check1 "C: form POST" POST /api/access-requests
  probe check2 "C: JWT reaches Worker route (service token)" GET /api/echo token
  probe check5 "C: Allow + Service Auth on one app (service token)" GET /learn/ token
  record check3 "C: service token set a CF_Authorization cookie" \
    "$(grep -q CF_Authorization "$JAR" 2>/dev/null && echo true || echo false)"
  probe check3 "C: cookie sent to uncovered path" GET /uncovered/echo cookie
  probe check3 "C: cookie sent to Bypass path" GET /api/access-requests cookie
}

# ── Check 8: D1 batch() and the per-invocation query limit ───────────────

d1_checks() {
  local n mode out
  printf '  %s%-6s %-6s %s%s\n' "$BOLD" MODE N RESULT "$RESET"
  for mode in seq batch; do
    for n in 49 50 51 60 1000 1001; do
      out=$(curl -s --max-time 60 "$CK_WORKERS_DEV_URL/api/d1/$mode?n=$n" || echo '{"ok":false,"error":"curl failed"}')
      printf '  %-6s %-6s %s\n' "$mode" "$n" "$(jq -r 'if .ok then "ok" else "FAILED: \(.error)" end' <<<"$out" 2>/dev/null || echo "$out")"
      record check8 "$mode n=$n" "$out"
    done
  done
}

# ── Check 7: do Preview requests count toward the daily Worker limit? ────

# burst URL N fires N GETs, 16 at a time, and prints a status-code tally.
burst() {
  seq "$2" | xargs -P 16 -I{} curl -s -o /dev/null --max-time 20 -w '%{http_code}\n' "$1" | sort | uniq -c | tr '\n' ' '
}

# invocations START END prints Worker requests per script in that window.
invocations() {
  graphql 'query($a: String!, $s: Time!, $e: Time!) { viewer { accounts(filter: {accountTag: $a}) {
      workersInvocationsAdaptive(limit: 100, filter: {datetime_geq: $s, datetime_leq: $e}) {
        sum { requests } dimensions { scriptName } } } } }' \
    "$(jq -nc --arg a "$CK_ACCOUNT_ID" --arg s "$1" --arg e "$2" '{a: $a, s: $s, e: $e}')"
}

# ── Stage bodies too long to sit inline in the wizard ─────────────────────

deploy_worker() {
  local id url
  id=$(wr d1 list --json 2>/dev/null | jq -r '.[]? | select(.name == "ck16-db") | (.uuid // .id)' | head -n1 || true)
  if [[ -z "$id" ]]; then
    say "Creating D1 database ck16-db..."
    wr d1 create ck16-db 2>&1 | tee "$RAW/d1-create.log"
    id=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$RAW/d1-create.log" | head -n1 || true)
  fi
  [[ -n "$id" ]] || { warn "couldn't find the ck16-db database id"; return 1; }
  write_env CK_D1_ID "$id"
  jq --arg id "$id" --arg host "$CK_HOST" \
    '(.d1_databases[0].database_id, .previews.d1_databases[0].database_id) = $id | .routes[0].pattern = $host' \
    wrangler.base.json > wrangler.json
  say "Creating the hits table..."
  wr d1 execute ck16-db --remote -y --file schema.sql > "$RAW/d1-schema.log" 2>&1 \
    || { warn "schema failed: $(tail -n3 "$RAW/d1-schema.log")"; return 1; }
  say "Deploying the Worker to $CK_HOST and workers.dev..."
  wr deploy 2>&1 | tee "$RAW/deploy.log"
  [[ "${PIPESTATUS[0]}" -eq 0 ]] || { warn "deploy failed; see $RAW/deploy.log"; return 1; }
  url=$(grep -oE 'https://ck16-checks\.[A-Za-z0-9-]+\.workers\.dev' "$RAW/deploy.log" | head -n1 || true)
  [[ -n "$url" ]] && write_env CK_WORKERS_DEV_URL "$url"
}

seats_used() {
  local out
  out=$(cf GET '/access/users?per_page=100')
  cf_ok "$out" || out=$(cf GET /access/users)
  printf '%s\n' "$out" > "$RAW/users.json"
  jq -r '[.result[]? | select(.access_seat == true)] | length' <<<"$out" 2>/dev/null || echo "?"
}

# seat_check: fill the free seats with plus-addressed logins, then try one more.
seat_check() {
  local used needed local_part domain emails include i email before after reply
  used=$(seats_used)
  [[ "$used" =~ ^[0-9]+$ ]] || { warn "couldn't count seats (see $RAW/users.json)"; return 1; }
  needed=$((51 - used))
  say "Seats in use now: $used of 50. Reaching the 51st takes $needed sign-ins."
  (( needed >= 1 && needed <= 51 )) || { warn "unexpected seat count; stopping"; return 1; }
  record check4 "seats before test" "$used"
  local_part=${CK_SEAT_EMAIL_BASE%@*}; domain=${CK_SEAT_EMAIL_BASE#*@}
  emails=$(for ((i = 1; i <= needed; i++)); do printf '%s+ck16-%s@%s\n' "$local_part" "$i" "$domain"; done)
  include=$(jq -R '{email: {email: .}}' <<<"$emails" | jq -sc .)
  ck_delete_named apps ck16-S- >/dev/null
  ck_delete_named policies ck16-seat- >/dev/null
  CK_POL_SEAT=$(ck_policy ck16-seat-allow allow "$include") || return 1
  ck_app ck16-S-seat "$(H '/seat/*')" "$CK_POL_SEAT" || return 1
  wait_for /seat/x GATED 180 || return 1

  for ((i = 1; i <= needed; i++)); do
    email="${local_part}+ck16-${i}@${domain}"
    before=$(seats_used)
    if [[ "$before" =~ ^[0-9]+$ ]] && (( before >= 50 )); then
      printf '\n'; warn "All 50 seats are taken. The next sign-in is the 51st."
      warn "If Free bills for overage instead of blocking, this is the login that would start it."
      confirm "Try the 51st sign-in now?" || { record check4 "51st login" '"not attempted"'; return 0; }
    fi
    printf '\n  %s[%s/%s]%s seats in use: %s\n' "$BOLD" "$i" "$needed" "$RESET" "$before"
    open_url "https://$CK_HOST/cdn-cgi/access/logout"
    sleep 2
    open_url "https://$CK_HOST/seat/$i?tag=S-$i"
    step "Sign in as ${BOLD}${email}${RESET} with the PIN that arrives in your inbox."
    ask reply "Enter when signed in, or type what you saw instead (q stops):" || reply=q
    [[ "$reply" == q ]] && { record check4 "stopped at login $i" "$before"; return 0; }
    after=$(seats_used)
    record check4 "login $i" "$(jq -nc --argjson i "$i" --arg b "$before" --arg a "$after" --arg r "$reply" \
      '{login: $i, seats_before: $b, seats_after: $a, reply: $r}')"
    if [[ "$before" =~ ^[0-9]+$ ]] && (( before >= 50 )); then
      ask reply "Describe what the 51st sign-in did (blocked page text, got in, billing prompt...):" || true
      record check4 "51st login outcome" "$reply"
      open_url "https://one.dash.cloudflare.com/"
      step "In Zero Trust, find the plan/billing page (Settings → Account or Billing; the exact menu may differ)."
      ask reply "What plan and seat count does it show now? Any overage notice?" || true
      record check4 "plan after 51st login" "$reply"
      return 0
    fi
  done
}

preview_check() {
  local out url t0 t1 t2 t3 q1 q2
  say "Creating a Preview named ck16..."
  out=$(wr preview --name ck16 --json 2>"$RAW/preview.err") \
    || { warn "wrangler preview failed: $(tail -n3 "$RAW/preview.err")"; return 1; }
  printf '%s\n' "$out" > "$RAW/preview.json"
  url=$(grep -oE 'https://[A-Za-z0-9.-]+\.workers\.dev' "$RAW/preview.json" | grep -m1 '^https://ck16-' || true)
  [[ -z "$url" ]] && url=$(grep -oE 'https://[A-Za-z0-9.-]+\.workers\.dev' "$RAW/preview.json" | head -n1 || true)
  [[ -n "$url" ]] && write_env CK_PREVIEW_URL "$url"
  ask CK_PREVIEW_URL "Preview URL (check it against the JSON above):" || return 1
  write_env CK_PREVIEW_URL "$CK_PREVIEW_URL"
  table_head
  probe check7 "Preview reachable" GET /api/ping none "$CK_PREVIEW_URL"
  if [[ "$LAST_CLASS" != OPEN ]]; then
    warn "The Preview isn't reachable without sign-in (an account-wide Preview Access policy?). Skipping the count."
    return 1
  fi
  say "Window 1: 300 requests to the Preview only..."
  t0=$(date -u +%FT%TZ); say "  $(burst "$CK_PREVIEW_URL/api/ping?src=preview" 300)"; t1=$(date -u +%FT%TZ)
  record check7 "burst to Preview" "$(jq -nc --arg s "$t0" --arg e "$t1" '{start: $s, end: $e, sent: 300}')"
  countdown 60 "gap between the two windows"
  say "Window 2: 300 requests to production only (the control)..."
  t2=$(date -u +%FT%TZ); say "  $(burst "$CK_WORKERS_DEV_URL/api/ping?src=prod" 300)"; t3=$(date -u +%FT%TZ)
  record check7 "burst to production" "$(jq -nc --arg s "$t2" --arg e "$t3" '{start: $s, end: $e, sent: 300}')"
  countdown 240 "letting analytics catch up"
  while true; do
    q1=$(invocations "$t0" "$t1"); q2=$(invocations "$t2" "$t3")
    printf '%s\n%s\n' "$q1" "$q2" > "$RAW/invocations.json"
    say "Worker requests per script, Preview window:"
    jq -r '.data.viewer.accounts[0].workersInvocationsAdaptive[]? | "    \(.dimensions.scriptName): \(.sum.requests)"' <<<"$q1"
    say "Worker requests per script, production window:"
    jq -r '.data.viewer.accounts[0].workersInvocationsAdaptive[]? | "    \(.dimensions.scriptName): \(.sum.requests)"' <<<"$q2"
    record check7 "analytics, Preview window" "$q1"
    record check7 "analytics, production window" "$q2"
    want "Query again? (say yes if the production window still shows ~0; analytics can lag)" || break
  done
}

teardown() {
  local out body
  ck_delete_named apps ck16-
  ck_delete_named policies ck16-
  ck_delete_named service_tokens ck16-
  out=$(cf GET '/access/users?per_page=100'); cf_ok "$out" || out=$(cf GET /access/users)
  body=$(jq -c '[.result[]? | select((.email // "") | contains("+ck16-")) | select(.seat_uid != null)
                 | {seat_uid, access_seat: false, gateway_seat: false}]' <<<"$out" 2>/dev/null || echo '[]')
  if [[ "$body" != "[]" ]]; then
    out=$(cf PATCH /access/seats "$body")
    if cf_ok "$out"; then note "freed $(jq length <<<"$body") test seat(s)"
    else
      warn "couldn't free test seats by API: $(cf_err "$out")"
      SKIPPED+=("Free the +ck16- seats: Zero Trust → Team & Resources → Users → select them → Remove")
    fi
  fi
  wr preview delete --name ck16 || SKIPPED+=("Delete the ck16 Preview: npx wrangler preview delete --name ck16")
  wr delete || SKIPPED+=("Delete the ck16-checks Worker in the dashboard")
  wr d1 delete ck16-db -y || SKIPPED+=("Delete the ck16-db database: npx wrangler d1 delete ck16-db")
  SKIPPED+=("Check the DNS record for $CK_HOST is gone (Custom Domains are normally removed with the Worker)")
  SKIPPED+=("Delete the ck16-checks API token at https://dash.cloudflare.com/profile/api-tokens")
}
