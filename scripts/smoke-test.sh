#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:8081}"
AGENT_TOKEN="${KARAXYS_AGENT_TOKEN:-docker-agent-token-with-at-least-24-chars}"
EMAIL="${KARAXYS_SMOKE_EMAIL:-smoke+$(date +%s)@karaxys.local}"
PASSWORD="${KARAXYS_SMOKE_PASSWORD:-change-me-now-123}"
ACCOUNT_NAME="${KARAXYS_SMOKE_ACCOUNT:-Karaxys Smoke}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

need curl
need jq

wait_for_api() {
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE_URL}/inventory" || true)"
    if [ "${code}" = "401" ] || [ "${code}" = "200" ]; then
      pass "api reachable"
      return
    fi
    sleep 1
  done
  fail "api did not become reachable at ${API_BASE_URL}"
}

signup() {
  response_file="${tmp_dir}/signup.json"
  code="$(curl -s -o "${response_file}" -w '%{http_code}' -X POST "${API_BASE_URL}/auth/signup" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"account_name\":\"${ACCOUNT_NAME}\"}")"
  if [ "${code}" = "409" ]; then
    code="$(curl -s -o "${response_file}" -w '%{http_code}' -X POST "${API_BASE_URL}/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")"
  fi
  [ "${code}" = "200" ] || [ "${code}" = "201" ] || fail "signup/login failed with status ${code}: $(cat "${response_file}")"
  ACCESS_TOKEN="$(jq -r '.access_token // empty' "${response_file}")"
  [ -n "${ACCESS_TOKEN}" ] || fail "auth response did not include access_token"
  ACCOUNT_ID="$(jq -r '.account.id // .user.account_id // empty' "${response_file}")"
  [ -n "${ACCOUNT_ID}" ] || fail "auth response did not include account id"
  pass "auth session created"
}

ingest_sample() {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  oid="$(printf '%024x' "$(date +%s)")"
  payload="${tmp_dir}/conversation.json"
  cat >"${payload}" <<JSON
{
  "_id": {"\$oid": "${oid}"},
  "schema_version": "http.conversation.v1",
  "tenant_id": "${ACCOUNT_ID}",
  "agent_id": "smoke-agent",
  "capture_source": "ebpf",
  "capture_mode": "container",
  "captured_at": {"\$date": "${now}"},
  "connection": {
    "src_ip": "127.0.0.1",
    "src_port": 41234,
    "dst_ip": "127.0.0.1",
    "dst_port": 3000,
    "protocol": "tcp",
    "family": "ipv4",
    "role": "outbound"
  },
  "process": {
    "pid": 4242,
    "name": "smoke-api",
    "exe": "/usr/local/bin/smoke-api"
  },
  "loss": {
    "truncated": false,
    "sequence_gap": false
  },
  "http": {
    "request": {
      "method": "POST",
      "url": "http://smoke.karaxys.local/users/v1/login",
      "host": "smoke.karaxys.local",
      "path": "/users/v1/login",
      "headers": {
        "Accept": ["application/json"],
        "Content-Type": ["application/json"],
        "User-Agent": ["karaxys-smoke-test"]
      },
      "body": "{\"username\":\"smoke\",\"password\":\"secret-password\"}"
    },
    "response": {
      "status": "200 OK",
      "status_code": 200,
      "headers": {
        "Content-Type": ["application/json"]
      },
      "body": "{\"status\":\"success\",\"auth_token\":\"eyJhbGciOiJIUzI1NiJ9.smoke.signature\"}"
    }
  }
}
JSON

  code="$(curl -s -o "${tmp_dir}/ingest.out" -w '%{http_code}' -X POST "${API_BASE_URL}/v1/ingest/conversations" \
    -H "Authorization: Bearer ${AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${payload}")"
  [ "${code}" = "202" ] || fail "conversation ingest failed with status ${code}: $(cat "${tmp_dir}/ingest.out")"
  pass "sample conversation ingested"
}

wait_for_inventory() {
  for _ in $(seq 1 60); do
    response="$(curl -s "${API_BASE_URL}/inventory?limit=50" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    total="$(printf '%s' "${response}" | jq -r '.total // 0')"
    if [ "${total}" -gt 0 ]; then
      printf '%s\n' "${response}" | jq '.data[] | {ID, Method, PathPattern, RiskLevel}' || true
      pass "inventory populated"
      return
    fi
    sleep 1
  done
  fail "inventory did not populate within 60 seconds"
}

main() {
  wait_for_api
  signup
  ingest_sample
  wait_for_inventory
  pass "karaxys deployment smoke test completed"
}

main "$@"
