#!/usr/bin/env bash
# Drives real traffic against VAmPI, ingests it into Karaxys, then fires every
# scanner suite preset against a spread of endpoints and aggregates everything
# (requests, inventory, suite status, findings) into a timestamped log
# directory for offline review.
set -euo pipefail

API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:8081}"
# Where this script drives real traffic (from the host, via VAmPI's published port).
VAMPI_BASE_URL="${VAMPI_BASE_URL:-http://127.0.0.1:5000}"
# The host:port recorded in the ingested conversation — becomes the inventory
# BaseURL and therefore the scanner-worker's scan target, so it must resolve
# from INSIDE the backend containers (VAmPI attached to the compose network).
VAMPI_INGEST_HOST="${VAMPI_INGEST_HOST:-vampi:5000}"
AGENT_TOKEN="${KARAXYS_AGENT_TOKEN:-docker-agent-token-with-at-least-24-chars}"
EMAIL="${KARAXYS_VERIFY_EMAIL:-verify+$(date +%s)@karaxys.local}"
PASSWORD="${KARAXYS_VERIFY_PASSWORD:-change-me-now-123}"
ACCOUNT_NAME="${KARAXYS_VERIFY_ACCOUNT:-Karaxys Suite Verify}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROOT="${SCRIPT_DIR}/../scan-verification-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${LOG_ROOT}"
SUMMARY="${LOG_ROOT}/SUMMARY.txt"
FINDINGS="${LOG_ROOT}/findings.jsonl"
: >"${SUMMARY}"
: >"${FINDINGS}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
need curl
need jq

log() { printf '%s\n' "$1" | tee -a "${SUMMARY}"; }
section() { printf '\n=== %s ===\n' "$1" | tee -a "${SUMMARY}"; }

# ---------------------------------------------------------------------------
# Setup: dashboard account + VAmPI users
# ---------------------------------------------------------------------------
section "Setup"

wait_for_api() {
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE_URL}/inventory" || true)"
    [ "${code}" = "401" ] || [ "${code}" = "200" ] && { log "api reachable"; return; }
    sleep 1
  done
  log "FATAL: api did not become reachable at ${API_BASE_URL}"; exit 1
}

# ensure_vampi keeps the (fragile, debug-mode) VAmPI target alive across a long
# multi-suite run: if it has crashed, restart the container and wait for it.
ensure_vampi() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "${VAMPI_BASE_URL}/" 2>/dev/null || echo 000)"
  if [ "${code}" != "000" ]; then return 0; fi
  log "  (vampi unreachable — restarting container)"
  docker start vampi >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "${VAMPI_BASE_URL}/" 2>/dev/null || echo 000)"
    [ "${code}" != "000" ] && { docker network connect karaxys_default vampi >/dev/null 2>&1 || true; return 0; }
    sleep 3
  done
  log "  WARNING: vampi still unreachable after restart"
}

wait_for_vampi() {
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${VAMPI_BASE_URL}/" || true)"
    [ "${code}" != "000" ] && { log "vampi reachable"; return; }
    sleep 1
  done
  log "FATAL: vampi did not become reachable at ${VAMPI_BASE_URL}"; exit 1
}

signup() {
  resp="${LOG_ROOT}/00-signup.json"
  code="$(curl -s -o "${resp}" -w '%{http_code}' -X POST "${API_BASE_URL}/auth/signup" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"account_name\":\"${ACCOUNT_NAME}\"}")"
  if [ "${code}" = "409" ]; then
    code="$(curl -s -o "${resp}" -w '%{http_code}' -X POST "${API_BASE_URL}/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")"
  fi
  [ "${code}" = "200" ] || [ "${code}" = "201" ] || { log "FATAL: signup/login failed (${code}): $(cat "${resp}")"; exit 1; }
  ACCESS_TOKEN="$(jq -r '.access_token // empty' "${resp}")"
  ACCOUNT_ID="$(jq -r '.account.id // .user.account_id // empty' "${resp}")"
  [ -n "${ACCESS_TOKEN}" ] && [ -n "${ACCOUNT_ID}" ] || { log "FATAL: auth response missing token/account id"; exit 1; }
  log "dashboard account ready (account_id=${ACCOUNT_ID})"
}

vampi_register_and_login() {
  local user="$1" pass="$2" email="$3"
  curl -s -o /dev/null -X POST "${VAMPI_BASE_URL}/users/v1/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\",\"email\":\"${email}\"}" || true
  resp="$(curl -s -X POST "${VAMPI_BASE_URL}/users/v1/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}")"
  printf '%s' "${resp}" | jq -r '.auth_token // empty'
}

wait_for_api
wait_for_vampi
signup

curl -s -o /dev/null "${VAMPI_BASE_URL}/createdb" || true
ALICE_TOKEN="$(vampi_register_and_login alice AlicePass123! alice@example.com)"
BOB_TOKEN="$(vampi_register_and_login bob BobPass123! bob@example.com)"
[ -n "${ALICE_TOKEN}" ] && [ -n "${BOB_TOKEN}" ] || { log "FATAL: failed to obtain VAmPI auth tokens"; exit 1; }
log "vampi users ready (alice, bob)"

# ---------------------------------------------------------------------------
# Traffic generation: real requests against VAmPI, real responses ingested
# into Karaxys as captured conversations (mirrors what the eBPF agent would
# produce, without requiring kernel/root privileges for a scanner-only test).
# ---------------------------------------------------------------------------
section "Traffic generation"

TRAFFIC_LOG="${LOG_ROOT}/01-traffic.jsonl"
: >"${TRAFFIC_LOG}"

ingest_conversation() {
  local method="$1" path="$2" req_body="$3" auth_header="$4" status_code="$5" resp_body="$6"
  local oid ts payload code
  oid="$(printf '%08x%04x%04x%04x%04x' "$(date +%s)" "${RANDOM}" "${RANDOM}" "${RANDOM}" "${RANDOM}" | cut -c1-24)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  payload="$(jq -n \
    --arg oid "${oid}" --arg ts "${ts}" --arg tenant "${ACCOUNT_ID}" \
    --arg method "${method}" --arg path "${path}" --arg host "${VAMPI_INGEST_HOST}" \
    --arg url "http://${VAMPI_INGEST_HOST}${path}" --arg reqBody "${req_body}" \
    --arg auth "${auth_header}" --arg statusLine "${status_code} X" \
    --argjson statusCode "${status_code}" --arg respBody "${resp_body}" \
    '{
      "_id": {"$oid": $oid},
      schema_version: "http.conversation.v1",
      tenant_id: $tenant,
      agent_id: "verify-script",
      capture_source: "ebpf",
      capture_mode: "container",
      captured_at: {"$date": $ts},
      connection: {src_ip:"127.0.0.1", src_port:44000, dst_ip:"127.0.0.1", dst_port:5000, protocol:"tcp", family:"ipv4", role:"outbound"},
      process: {pid: 9999, name: "verify-script", exe: "/usr/bin/curl"},
      loss: {truncated:false, sequence_gap:false},
      http: {
        request: ({
          method: $method, url: $url, host: $host, path: $path,
          headers: (if $auth == "" then {"Accept":["application/json"],"Content-Type":["application/json"]} else {"Accept":["application/json"],"Content-Type":["application/json"],"Authorization":[$auth]} end),
          body: $reqBody
        }),
        response: {
          status: $statusLine, status_code: $statusCode,
          headers: {"Content-Type":["application/json"]},
          body: $respBody
        }
      }
    }')"
  code="$(curl -s -o "${LOG_ROOT}/ingest-last.json" -w '%{http_code}' -X POST "${API_BASE_URL}/v1/ingest/conversations" \
    -H "Authorization: Bearer ${AGENT_TOKEN}" -H "Content-Type: application/json" --data-binary "${payload}")"
  printf '%s %s -> ingest %s\n' "${method}" "${path}" "${code}" | tee -a "${TRAFFIC_LOG}" >>"${SUMMARY}"
  [ "${code}" = "202" ] || log "  WARNING: ingest returned ${code}: $(cat "${LOG_ROOT}/ingest-last.json")"
}

drive_and_ingest() {
  local method="$1" path="$2" req_body="$3" bearer="$4"
  local resp status
  if [ -n "${req_body}" ]; then
    resp="$(curl -s -w '\n%{http_code}' -X "${method}" "${VAMPI_BASE_URL}${path}" \
      -H "Content-Type: application/json" ${bearer:+-H "Authorization: Bearer ${bearer}"} -d "${req_body}")"
  else
    resp="$(curl -s -w '\n%{http_code}' -X "${method}" "${VAMPI_BASE_URL}${path}" \
      ${bearer:+-H "Authorization: Bearer ${bearer}"})"
  fi
  status="$(printf '%s' "${resp}" | tail -n1)"
  body="$(printf '%s' "${resp}" | sed '$d')"
  ingest_conversation "${method}" "${path}" "${req_body}" "${bearer:+Bearer ${bearer}}" "${status}" "${body}"
}

drive_and_ingest POST "/users/v1/login" '{"username":"alice","password":"AlicePass123!"}' ""
drive_and_ingest GET  "/users/v1/_debug" "" ""
drive_and_ingest GET  "/users/v1/alice" "" "${ALICE_TOKEN}"
drive_and_ingest PUT  "/users/v1/alice/email" '{"email":"alice.updated@example.com"}' "${ALICE_TOKEN}"
drive_and_ingest GET  "/books/v1" "" ""
drive_and_ingest POST "/books/v1" '{"book_title":"Karaxys Verify Book","book_pages_count":100,"book_price":9.99}' "${ALICE_TOKEN}"
drive_and_ingest GET  "/books/v1/Karaxys%20Verify%20Book" "" ""
drive_and_ingest PUT  "/books/v1/Karaxys%20Verify%20Book" '{"book_title":"Karaxys Verify Book","book_pages_count":120,"book_price":12.99,"is_secret":false}' "${ALICE_TOKEN}"

log "traffic generated and ingested (8 conversations)"

# ---------------------------------------------------------------------------
# Wait for the runtime-analyzer to build inventory from ingested traffic
# ---------------------------------------------------------------------------
section "Inventory"

INVENTORY_JSON="${LOG_ROOT}/02-inventory.json"
wait_for_inventory() {
  for _ in $(seq 1 60); do
    curl -s "${API_BASE_URL}/inventory?limit=200" -H "Authorization: Bearer ${ACCESS_TOKEN}" >"${INVENTORY_JSON}"
    total="$(jq -r '.total // 0' "${INVENTORY_JSON}")"
    if [ "${total}" -ge 6 ]; then
      log "inventory populated (${total} endpoints)"
      return
    fi
    sleep 2
  done
  log "FATAL: inventory did not populate (found $(jq -r '.total // 0' "${INVENTORY_JSON}"))"; exit 1
}
wait_for_inventory

jq -r '.data[] | "\(.ID)\t\(.Method)\t\(.PathPattern)"' "${INVENTORY_JSON}" | tee -a "${SUMMARY}"

inventory_id_for() {
  # $1 = method, $2 = substring of path pattern
  jq -r --arg m "$1" --arg p "$2" '.data[] | select(.Method==$m and (.PathPattern | contains($p))) | .ID' "${INVENTORY_JSON}" | head -n1
}

ID_LOGIN="$(inventory_id_for POST /users/v1/login)"
ID_USER_DETAIL="$(inventory_id_for GET /users/v1/)"
ID_USER_EMAIL="$(inventory_id_for PUT /email)"
ID_BOOK_GET="$(inventory_id_for GET /books/v1/)"
ID_BOOK_CREATE="$(inventory_id_for POST /books/v1)"

# ---------------------------------------------------------------------------
# Sanity-check the new registry/preset endpoints
# ---------------------------------------------------------------------------
section "Registry endpoints"

curl -s "${API_BASE_URL}/scan/test-types" -H "Authorization: Bearer ${ACCESS_TOKEN}" >"${LOG_ROOT}/03-test-types.json"
log "test-types registered: $(jq -r '.data | length' "${LOG_ROOT}/03-test-types.json")"
curl -s "${API_BASE_URL}/scan/suite-presets" -H "Authorization: Bearer ${ACCESS_TOKEN}" >"${LOG_ROOT}/04-suite-presets.json"
log "suite presets: $(jq -r '.data[].id' "${LOG_ROOT}/04-suite-presets.json" | paste -sd, -)"

# ---------------------------------------------------------------------------
# Fire every suite preset against a representative endpoint each
# ---------------------------------------------------------------------------
section "Suite runs"

AUTH_CONTEXTS="$(jq -n --arg a "Bearer ${BOB_TOKEN}" --arg v "Bearer ${ALICE_TOKEN}" --arg ad "Bearer ${ALICE_TOKEN}" '{attacker:$a, victim:$v, admin:$ad}')"

run_suite() {
  # $1 = inventory_id, $2 = suite preset id (or "" for FULL)
  local inv="$1" suite="$2" label="$3"
  if [ -z "${inv}" ]; then
    log "SKIP ${label}: no matching inventory endpoint found"
    return
  fi
  ensure_vampi
  local suite_arg="${suite:-FULL}"
  local req resp code suite_id
  req="$(jq -n --arg inv "${inv}" --arg suite "${suite_arg}" --argjson ctx "${AUTH_CONTEXTS}" \
    '{inventory_id:$inv, suite:$suite, auth_contexts:$ctx, attack_method:"DELETE", timeout_seconds:60}')"
  resp="${LOG_ROOT}/suite-${suite_arg}-${label}.json"
  code="$(curl -s -o "${resp}" -w '%{http_code}' -X POST "${API_BASE_URL}/scan/suite" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" --data-binary "${req}")"
  if [ "${code}" != "202" ]; then
    log "FAIL ${label} (suite=${suite_arg}): trigger returned ${code}: $(cat "${resp}")"
    return
  fi
  suite_id="$(jq -r '.suite_id' "${resp}")"
  job_count="$(jq -r '.job_count' "${resp}")"
  skipped="$(jq -c '.skipped // []' "${resp}")"
  log "STARTED ${label} suite=${suite_arg} suite_id=${suite_id} jobs=${job_count} skipped=${skipped}"

  local status_resp="${LOG_ROOT}/suite-status-${suite_arg}-${label}.json"
  local completed="false"
  for _ in $(seq 1 150); do
    curl -s "${API_BASE_URL}/scan/suites/${suite_id}" -H "Authorization: Bearer ${ACCESS_TOKEN}" >"${status_resp}" 2>/dev/null || true
    completed="$(jq -r '.completed // false' "${status_resp}" 2>/dev/null || echo false)"
    [ "${completed}" = "true" ] && break
    sleep 2
  done
  if [ "${completed}" != "true" ]; then
    log "TIMEOUT ${label} suite=${suite_arg} suite_id=${suite_id} (did not complete within 300s)"
  fi
  local counts findings
  counts="$(jq -c '.status_counts' "${status_resp}" 2>/dev/null || echo '{}')"
  findings="$(jq -r '.total_findings // 0' "${status_resp}" 2>/dev/null || echo 0)"
  log "RESULT  ${label} suite=${suite_arg} suite_id=${suite_id} status_counts=${counts} findings=${findings}"

  local results_resp="${LOG_ROOT}/suite-results-${suite_arg}-${label}.json"
  curl -s "${API_BASE_URL}/scan-results?suite_id=${suite_id}&limit=200" -H "Authorization: Bearer ${ACCESS_TOKEN}" >"${results_resp}" 2>/dev/null || true
  jq -c --arg label "${label}" --arg suite "${suite_arg}" '.data[]? | . + {_suite_label:$label, _suite_preset:$suite}' "${results_resp}" 2>/dev/null >>"${FINDINGS}" || true
  return 0
}

run_suite "${ID_USER_EMAIL}"    ""                   "user-email-full"
run_suite "${ID_USER_DETAIL}"   "ACCESS_CONTROL"      "user-detail"
run_suite "${ID_LOGIN}"         "AUTHENTICATION"      "login"
run_suite "${ID_LOGIN}"         "INJECTION"           "login"
run_suite "${ID_BOOK_GET}"      "SSRF"                "book-get"
run_suite "${ID_BOOK_GET}"      "MISCONFIGURATION"    "book-get"
run_suite "${ID_BOOK_CREATE}"   "OWASP_API_TOP_10"    "book-create"

# ---------------------------------------------------------------------------
# Aggregate
# ---------------------------------------------------------------------------
section "Aggregate findings"

total_findings="$(wc -l <"${FINDINGS}" | tr -d ' ')"
log "total findings recorded: ${total_findings}"
if [ "${total_findings}" -gt 0 ]; then
  log "findings by test_type:"
  jq -r '.test_type' "${FINDINGS}" | sort | uniq -c | sort -rn | tee -a "${SUMMARY}"
  log "findings by severity:"
  jq -r '.severity' "${FINDINGS}" | sort | uniq -c | sort -rn | tee -a "${SUMMARY}"
fi

log ""
log "Full logs: ${LOG_ROOT}"
log "Findings (JSONL): ${FINDINGS}"
log "Summary: ${SUMMARY}"
