#!/usr/bin/env bash
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Regression tests for issue #83: hosted discovery must report the container
# ports reachable from the Compose network, not only host-published ports.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/hosted.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/hosted-service-discovery.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

DOCKER_CALL_LOG="$TMPDIR/docker-calls.log"
DOCKER_PS_JSON=""
DOCKER_PS_RC=0
DOCKER_PS_Q_OUTPUT=""
DOCKER_PS_Q_RC=0
DOCKER_INSPECT_RC=0
DOCKER_INSPECT_FORMAT_OUTPUT=""
DOCKER_INSPECT_JSON_OUTPUT=""
DOCKER_RUN_RESPONSES=""
LOG_WARN_MESSAGES=""

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle', got '${haystack:0:240}')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (did not expect '$needle')"
  fi
}

assert_zero_rc() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

set_docker_run_response() {
  local service="$1" port="$2" output="$3" rc="$4"
  DOCKER_RUN_RESPONSES="${DOCKER_RUN_RESPONSES}${service}|${port}|${output}|${rc}"$'\n'
}

reset_docker_stub() {
  DOCKER_PS_JSON=""
  DOCKER_PS_RC=0
  DOCKER_PS_Q_OUTPUT=""
  DOCKER_PS_Q_RC=0
  DOCKER_INSPECT_RC=0
  DOCKER_INSPECT_FORMAT_OUTPUT=""
  DOCKER_INSPECT_JSON_OUTPUT=""
  DOCKER_RUN_RESPONSES=""
  LOG_WARN_MESSAGES=""
  : > "$DOCKER_CALL_LOG"
  HOSTED_NETWORK="issue83_default"
  HOSTED_SERVICES=""
  HOSTED_SERVICES_DETAIL=""
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced hosted helpers.
log_warn() {
  LOG_WARN_MESSAGES="${LOG_WARN_MESSAGES}${1}"$'\n'
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced hosted helpers.
docker() {
  printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"

  if [[ "${1:-}" == "compose" ]]; then
    if [[ "$*" == *" ps --format json"* ]]; then
      printf '%s\n' "$DOCKER_PS_JSON"
      return "$DOCKER_PS_RC"
    fi
    if [[ "$*" == *" ps -q"* ]]; then
      printf '%s\n' "$DOCKER_PS_Q_OUTPUT"
      return "$DOCKER_PS_Q_RC"
    fi
  fi

  if [[ "${1:-}" == "inspect" ]]; then
    if [[ "$DOCKER_INSPECT_RC" -ne 0 ]]; then
      return "$DOCKER_INSPECT_RC"
    fi
    if [[ "$*" == *"--format"* ]]; then
      printf '%s\n' "$DOCKER_INSPECT_FORMAT_OUTPUT"
    else
      printf '%s\n' "$DOCKER_INSPECT_JSON_OUTPUT"
    fi
    return 0
  fi

  if [[ "${1:-}" == "run" ]]; then
    local url="${!#}" service port rule_service rule_port rule_output rule_rc
    if [[ "$url" =~ ^http://([^:/]+):([0-9]+)/ ]]; then
      service="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      while IFS='|' read -r rule_service rule_port rule_output rule_rc; do
        [[ -z "$rule_service" ]] && continue
        if [[ "$rule_service" == "$service" && "$rule_port" == "$port" ]]; then
          printf '%s' "$rule_output"
          return "${rule_rc:-0}"
        fi
      done <<< "$DOCKER_RUN_RESPONSES"
    fi
    printf '000'
    return 7
  fi

  echo "unexpected docker invocation: $*" >&2
  return 127
}

run_discovery() {
  discover_services "$TMPDIR/compose.yml" "issue83"
}

docker_calls() {
  cat "$DOCKER_CALL_LOG"
}

echo ""
echo "=== Test Suite: hosted service discovery internal ports (issue #83) ==="
echo ""

echo "Test 1: parser exposes container ID and target port when the port is not published"
reset_docker_stub
parsed="$(_parse_service_json '{"Service":"web","Image":"example/web","ID":"web-container","Publishers":[{"URL":"","TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}')"
assert_contains "parser keeps service name" "web" "$parsed"
assert_contains "parser keeps image" "example/web" "$parsed"
assert_contains "parser exposes container id" "web-container" "$parsed"
assert_contains "parser exposes target port 80" "80" "$parsed"

echo ""
echo "Test 2: discover_services uses NDJSON TargetPort values for scanner URLs"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"URL":"","TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","Ports":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
assert_eq "compact service list uses internal ports" "web:80,api:8080" "$HOSTED_SERVICES"
assert_contains "web detail uses service name and internal port" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "api detail uses service name and internal port" "http://api:8080" "$HOSTED_SERVICES_DETAIL"
assert_contains "internal detail is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "internal-only services are not described as unpublished" "no published port" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 3: host-published ports are secondary when target port differs"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"URL":"0.0.0.0","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list prefers Docker-network port" "web:80" "$HOSTED_SERVICES"
assert_contains "detail points scanners at target port" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "detail preserves host-published port as metadata" "published host port 8080" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "detail does not point scanner at host-published port" "http://web:8080" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 4: discovery falls back to docker inspect ExposedPorts"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"worker","Image":"example/worker","ID":"worker-id","Publishers":[]}'
DOCKER_INSPECT_FORMAT_OUTPUT="$(cat <<'EOF_FORMAT'
9000/udp
9090/tcp
EOF_FORMAT
)"
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{"9000/udp":{},"9090/tcp":{}}}}]'
run_discovery
assert_eq "compact service list uses inspected TCP exposed port" "worker:9090" "$HOSTED_SERVICES"
assert_contains "detail uses inspected TCP port" "http://worker:9090" "$HOSTED_SERVICES_DETAIL"
assert_contains "inspect fallback is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 5: discovery resolves container ID before inspect when Compose JSON omits it"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"api","Image":"example/api","Publishers":[]}'
DOCKER_PS_Q_OUTPUT='api-container'
DOCKER_INSPECT_FORMAT_OUTPUT='8080/tcp'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{"8080/tcp":{}}}}]'
run_discovery
calls="$(docker_calls)"
assert_eq "compact service list uses inspected port after ID lookup" "api:8080" "$HOSTED_SERVICES"
assert_contains "service-specific ps -q resolves missing ID" "ps -q api" "$calls"
assert_contains "resolved container ID is inspected" "api-container" "$calls"

echo ""
echo "Test 6: inspect failures are non-fatal and leave an explicit no-port detail"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"job","Image":"example/job","ID":"job-id","Publishers":[]}'
DOCKER_INSPECT_RC=42
run_discovery
rc=$?
assert_zero_rc "discover_services tolerates inspect failure" "$rc"
assert_eq "compact service list falls back to none" "job:none" "$HOSTED_SERVICES"
assert_contains "detail uses discovered-port wording" "no discovered port" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 7: JSON array compose output still uses internal target ports"
reset_docker_stub
DOCKER_PS_JSON='[{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]},{"Service":"api","Image":"example/api","ID":"api-id","Ports":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}]'
run_discovery
assert_eq "array output compact list uses internal ports" "web:80,api:8080" "$HOSTED_SERVICES"
assert_contains "array output has web internal URL" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "array output has api internal URL" "http://api:8080" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 8: published-only metadata remains a fallback when no internal port is known"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"admin","Image":"example/admin","ID":"admin-id","Publishers":[{"URL":"0.0.0.0","PublishedPort":9443,"Protocol":"tcp"}]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
run_discovery
assert_eq "compact service list falls back to published port" "admin:9443" "$HOSTED_SERVICES"
assert_contains "detail points at published fallback port" "http://admin:9443" "$HOSTED_SERVICES_DETAIL"
assert_contains "detail labels published-only fallback" "(published, example/admin)" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 9: Ports[].PrivatePort is accepted as an internal port"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"legacy","Image":"example/legacy","ID":"legacy-id","Ports":[{"PrivatePort":5000,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list uses private port" "legacy:5000" "$HOSTED_SERVICES"
assert_contains "detail uses private port URL" "http://legacy:5000" "$HOSTED_SERVICES_DETAIL"
assert_contains "private port detail is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 10: Compose UDP ports are ignored for HTTP scanner URLs"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"metrics","Image":"example/metrics","ID":"metrics-id","Publishers":[{"TargetPort":8125,"PublishedPort":8125,"Protocol":"udp"},{"TargetPort":9090,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list skips UDP and uses TCP target" "metrics:9090" "$HOSTED_SERVICES"
assert_contains "detail uses TCP target port" "http://metrics:9090" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "detail does not use UDP port" "http://metrics:8125" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 11: Compose health status is surfaced without probing"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Health":"healthy","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","Status":"Up 5 seconds (unhealthy)","Publishers":[{"TargetPort":8000,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"worker","Image":"example/worker","ID":"worker-id","Health":"starting","Publishers":[{"TargetPort":9000,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
calls="$(docker_calls)"
assert_contains "healthy healthcheck appears in details" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "unhealthy healthcheck appears in details" "api: http://api:8000 (internal, example/api) [unhealthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "starting healthcheck appears in details" "worker: http://worker:9000 (internal, example/worker) [starting]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "explicit health statuses skip curl probe" "run --rm --network" "$calls"

echo ""
echo "Test 12: unknown health services are probed and 2xx/4xx responses count as responding"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","State":"running","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"admin","Image":"example/admin","ID":"admin-id","Status":"running","Publishers":[{"TargetPort":9443,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
set_docker_run_response "web" "80" "200" "0"
set_docker_run_response "admin" "9443" "404" "0"
run_discovery
calls="$(docker_calls)"
assert_contains "probe uses compose network" "run --rm --network issue83_default" "$calls"
assert_contains "HTTP 200 probe appears healthy" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "HTTP 404 probe appears responding, not unhealthy" "admin: http://admin:9443 (internal, example/admin) [responding HTTP 404]" "$HOSTED_SERVICES_DETAIL"
assert_eq "responding probes do not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 13: all unhealthy or unreachable HTTP services trigger a pre-scan warning"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"api","Image":"example/api","ID":"api-id","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"down","Image":"example/down","ID":"down-id","State":"running","Publishers":[{"TargetPort":8081,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
set_docker_run_response "api" "8080" "503" "0"
set_docker_run_response "down" "8081" "000" "7"
run_discovery
assert_contains "HTTP 503 probe appears unhealthy" "api: http://api:8080 (internal, example/api) [unhealthy HTTP 503]" "$HOSTED_SERVICES_DETAIL"
assert_contains "nonzero curl probe appears unreachable" "down: http://down:8081 (internal, example/down) [unreachable]" "$HOSTED_SERVICES_DETAIL"
assert_contains "all-unhealthy case warns before scanning" "All discovered hosted HTTP services are unhealthy or unreachable" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 14: mixed responding and unhealthy services do not warn"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Health":"healthy","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
set_docker_run_response "api" "8080" "503" "0"
run_discovery
assert_contains "mixed case keeps healthy service status" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "mixed case keeps unhealthy service status" "api: http://api:8080 (internal, example/api) [unhealthy HTTP 503]" "$HOSTED_SERVICES_DETAIL"
assert_eq "mixed case does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 15: missing hosted network produces unknown health and does not run curl"
reset_docker_stub
# shellcheck disable=SC2034  # Read by sourced hosted helpers during discovery.
HOSTED_NETWORK=""
DOCKER_PS_JSON='{"Service":"web","Image":"example/web","ID":"web-id","State":"running","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
calls="$(docker_calls)"
assert_contains "missing network appears as unknown health" "web: http://web:80 (internal, example/web) [unknown]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "missing network skips curl probe" "run --rm --network" "$calls"
assert_eq "unknown probe state does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 16: services without HTTP ports are not probed or counted"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"job","Image":"example/job","ID":"job-id","Publishers":[]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
run_discovery
calls="$(docker_calls)"
assert_contains "no-port service gets not-probed status" "job: no discovered port (example/job) [not probed]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "no-port service is not probed" "run --rm --network" "$calls"
assert_eq "no-port service does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 17: object health and exited statuses are normalized without probing"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Health":{"Status":"healthy"},"Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","State":"exited","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
calls="$(docker_calls)"
assert_contains "object health status appears healthy" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "exited state appears unhealthy" "api: http://api:8080 (internal, example/api) [unhealthy]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "object and exited statuses skip curl probe" "run --rm --network" "$calls"
assert_eq "healthy service prevents all-unhealthy warning" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 18: published-only services are probed on the published fallback port"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"admin","Image":"example/admin","ID":"admin-id","State":"running","Publishers":[{"URL":"0.0.0.0","PublishedPort":9443,"Protocol":"tcp"}]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
set_docker_run_response "admin" "9443" "302" "0"
run_discovery
calls="$(docker_calls)"
assert_contains "published-only probe targets published port" "http://admin:9443/" "$calls"
assert_contains "HTTP 302 probe appears healthy" "admin: http://admin:9443 (published, example/admin) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_eq "3xx published fallback does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 19: unparseable successful probes remain unknown and do not warn"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"api","Image":"example/api","ID":"api-id","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}'
set_docker_run_response "api" "8080" "curl output without status" "0"
run_discovery
assert_contains "malformed probe output appears unknown" "api: http://api:8080 (internal, example/api) [unknown]" "$HOSTED_SERVICES_DETAIL"
assert_eq "unknown successful probe does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "=========================================="
echo "Results: $PASS/$TOTAL passed ($FAIL failed)"
echo "=========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
