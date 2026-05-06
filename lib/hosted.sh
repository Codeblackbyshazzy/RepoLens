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

# RepoLens — Hosted environment lifecycle management

# Global state
HOSTED_NETWORK=""
HOSTED_SERVICES=""
HOSTED_SERVICES_DETAIL=""
HOSTED_HTTP_SERVICE_COUNT=0
HOSTED_HTTP_RESPONDING_COUNT=0
HOSTED_HTTP_UNHEALTHY_COUNT=0
HOSTED_HTTP_UNKNOWN_COUNT=0
HOSTED_OWNER="false"  # true if we started the compose project (vs reusing existing)

# detect_compose_file <project_path>
#   Prints the path to the first compose file found. Returns 1 if none.
detect_compose_file() {
  local project_path="$1"
  local candidate
  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${project_path}/${candidate}" ]]; then
      printf "%s" "${project_path}/${candidate}"
      return 0
    fi
  done
  return 1
}

# setup_hosted_env <project_path> <run_id>
#   Validates Docker, starts Compose with project isolation, discovers services.
#   Docker Compose creates its own network (<project>_default) which DAST tools join.
#   Side effects: sets HOSTED_NETWORK, HOSTED_SERVICES, HOSTED_SERVICES_DETAIL.
setup_hosted_env() {
  local project_path="$1" run_id="$2" compose_file

  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is not installed or not in PATH"
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin is not available"
    return 1
  fi

  compose_file="$(detect_compose_file "$project_path")" || {
    log_error "No compose file found in ${project_path}"
    return 1
  }
  log_info "Detected compose file: ${compose_file}"

  # Check if compose services are already running (e.g. dev environment).
  # Reuse them instead of starting a second instance — avoids container_name conflicts.
  local existing_running
  existing_running="$(docker compose -f "$compose_file" ps --status running --format json 2>/dev/null | head -1)"

  local project_name
  # Track whether we started the environment (for cleanup decisions)
  HOSTED_OWNER="false"

  if [[ -n "$existing_running" ]]; then
    # Reuse existing running compose project
    project_name="$(docker compose -f "$compose_file" ps --format json 2>/dev/null | head -1 | jq -r '.Project // empty' 2>/dev/null)"
    if [[ -z "$project_name" ]]; then
      # Fallback: derive from directory name (docker compose default)
      project_name="$(basename "$project_path" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
    fi
    log_info "Reusing existing running compose project: ${project_name}"
  else
    # No services running — start our own isolated instance.
    # Docker Compose requires lowercase project names.
    project_name="repolens-$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]')"
    HOSTED_OWNER="true"

    log_info "Starting services (project: ${project_name})..."
    if ! docker compose -f "$compose_file" -p "$project_name" up -d --wait 2>&1; then
      log_error "docker compose up failed for project ${project_name}"
      return 1
    fi
    log_info "Services started successfully"
  fi

  # Discover the network. Compose projects may use custom network names defined
  # in the compose file, or the default "<project>_default" network.
  # Find whichever network the first running container is actually on.
  local first_container
  first_container="$(docker compose -f "$compose_file" -p "$project_name" ps -q 2>/dev/null | head -1)"
  if [[ -n "$first_container" ]]; then
    HOSTED_NETWORK="$(docker inspect "$first_container" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"
  fi
  # Fallback: try standard naming patterns
  if [[ -z "$HOSTED_NETWORK" ]]; then
    HOSTED_NETWORK="${project_name}_default"
    if ! docker network inspect "$HOSTED_NETWORK" >/dev/null 2>&1; then
      HOSTED_NETWORK="$(docker network ls --filter "name=${project_name}" --format '{{.Name}}' | head -1)"
    fi
  fi
  if [[ -z "$HOSTED_NETWORK" ]]; then
    log_error "Failed to find Docker Compose network for project ${project_name}"
    return 1
  fi
  log_info "Using Docker network: ${HOSTED_NETWORK}"

  discover_services "$compose_file" "$project_name"
  if [[ -n "$HOSTED_SERVICES" ]]; then
    log_info "Discovered services: ${HOSTED_SERVICES}"
  else
    log_warn "No running services discovered — containers may have exited"
  fi
  return 0
}

# _parse_service_json <json_line>
#   Extracts service_name, image, container ID, published port, and internal target port.
#   Prints "service_name|image|container_id|published_port|target_port" on stdout.
_parse_service_json() {
  local json="$1"
  local svc img container_id published_port target_port

  svc="$(printf '%s' "$json" | jq -r '.Service // .Name // empty' 2>/dev/null)"
  img="$(printf '%s' "$json" | jq -r '.Image // "unknown"' 2>/dev/null)"
  container_id="$(printf '%s' "$json" | jq -r '.ID // .ContainerID // .ContainerId // empty' 2>/dev/null)"
  # Support both .Publishers (Compose v2.0-2.9) and .Ports (newer versions)
  published_port="$(printf '%s' "$json" | jq -r '
    def tcp: ((.Protocol // "tcp" | tostring | ascii_downcase) == "tcp");
    (.Publishers[]?, .Ports[]?)
    | select(tcp)
    | .PublishedPort
    | select(. != null and . != "" and ((tonumber? // 0) > 0))
    | tostring
  ' 2>/dev/null | head -1)"
  target_port="$(printf '%s' "$json" | jq -r '
    def tcp: ((.Protocol // "tcp" | tostring | ascii_downcase) == "tcp");
    (.Publishers[]?, .Ports[]?)
    | select(tcp)
    | (.TargetPort // .PrivatePort // empty)
    | select(. != null and . != "" and ((tonumber? // 0) > 0))
    | tostring
  ' 2>/dev/null | head -1)"

  [[ -z "$svc" ]] && return
  printf '%s|%s|%s|%s|%s\n' "$svc" "$img" "$container_id" "$published_port" "$target_port"
}

# _inspect_exposed_tcp_port <container_id>
#   Prints the first TCP port exposed by container metadata, if any.
_inspect_exposed_tcp_port() {
  local container_id="$1"
  local port

  [[ -z "$container_id" ]] && return 1
  port="$(docker inspect "$container_id" 2>/dev/null | jq -r '
    (.[0].Config.ExposedPorts // {})
    | keys[]
    | select(endswith("/tcp"))
    | split("/")[0]
    | select(test("^[0-9]+$"))
  ' 2>/dev/null | head -1)"
  [[ -n "$port" ]] && printf '%s\n' "$port"
}

# _parse_service_health_json <json_line>
#   Extracts Compose health/status fields for normalization.
_parse_service_health_json() {
  local json="$1"

  printf '%s' "$json" | jq -r '
    [
      (if ((.Health? | type) == "object") then (.Health.Status // empty) else empty end),
      (if ((.Health? | type) == "string") then .Health else empty end),
      (.Status // empty),
      (.State // empty)
    ]
    | map(select(. != null and . != "") | tostring)
    | join(" ")
  ' 2>/dev/null | tr '\n|' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

# _normalize_service_health <raw_status>
#   Converts Compose/Docker status text into compact prompt-facing labels.
_normalize_service_health() {
  local raw_status="$*"
  local status

  status="$(printf '%s' "$raw_status" | tr '[:upper:]' '[:lower:]')"
  if [[ "$status" == *"unhealthy"* ]]; then
    printf 'unhealthy'
  elif [[ "$status" == *"healthy"* ]]; then
    printf 'healthy'
  elif [[ "$status" == *"starting"* || "$status" == *"restarting"* ]]; then
    printf 'starting'
  elif [[ "$status" == *"exited"* || "$status" == *"dead"* ]]; then
    printf 'unhealthy'
  else
    printf 'unknown'
  fi
}

# _probe_http_service <service_name> <port>
#   Probes an HTTP endpoint from inside the Compose network and prints a label.
_probe_http_service() {
  local service_name="$1" port="$2"
  local output rc http_code

  if [[ -z "${HOSTED_NETWORK:-}" ]]; then
    printf 'unknown'
    return 0
  fi

  output="$(docker run --rm --network "$HOSTED_NETWORK" curlimages/curl \
    -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 2 --max-time 5 \
    "http://${service_name}:${port}/" 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'unreachable'
    return 0
  fi

  http_code="$(printf '%s' "$output" | sed -n 's/.*\([0-9][0-9][0-9]\).*/\1/p' | head -1)"
  if [[ ! "$http_code" =~ ^[0-9][0-9][0-9]$ ]]; then
    printf 'unknown'
  elif [[ "$http_code" =~ ^[23] ]]; then
    printf 'healthy'
  elif [[ "$http_code" =~ ^4 ]]; then
    printf 'responding HTTP %s' "$http_code"
  elif [[ "$http_code" =~ ^5 ]]; then
    printf 'unhealthy HTTP %s' "$http_code"
  else
    printf 'unknown'
  fi
}

# _record_hosted_http_health <health_label>
#   Tracks aggregate HTTP health so hosted mode can warn before scans start.
_record_hosted_http_health() {
  local health_label="$1"

  HOSTED_HTTP_SERVICE_COUNT=$((HOSTED_HTTP_SERVICE_COUNT + 1))
  case "$health_label" in
    healthy|responding\ HTTP\ *)
      HOSTED_HTTP_RESPONDING_COUNT=$((HOSTED_HTTP_RESPONDING_COUNT + 1))
      ;;
    unknown)
      HOSTED_HTTP_UNKNOWN_COUNT=$((HOSTED_HTTP_UNKNOWN_COUNT + 1))
      ;;
    *)
      HOSTED_HTTP_UNHEALTHY_COUNT=$((HOSTED_HTTP_UNHEALTHY_COUNT + 1))
      ;;
  esac
}

_warn_if_all_hosted_http_unhealthy() {
  if [[ "${HOSTED_HTTP_SERVICE_COUNT:-0}" -gt 0 &&
        "${HOSTED_HTTP_RESPONDING_COUNT:-0}" -eq 0 &&
        "${HOSTED_HTTP_UNKNOWN_COUNT:-0}" -eq 0 ]]; then
    if declare -F log_warn >/dev/null 2>&1; then
      log_warn "All discovered hosted HTTP services are unhealthy or unreachable; agents may not be able to scan live targets."
    fi
  fi
}

# discover_services <compose_file> <project_name>
#   Populates HOSTED_SERVICES (compact) and HOSTED_SERVICES_DETAIL (for prompts).
#   Handles both NDJSON (one object per line) and JSON array output from docker compose.
discover_services() {
  local compose_file="$1" project_name="$2"
  local json_output

  HOSTED_SERVICES=""
  HOSTED_SERVICES_DETAIL=""
  HOSTED_HTTP_SERVICE_COUNT=0
  HOSTED_HTTP_RESPONDING_COUNT=0
  HOSTED_HTTP_UNHEALTHY_COUNT=0
  HOSTED_HTTP_UNKNOWN_COUNT=0
  json_output="$(docker compose -f "$compose_file" -p "$project_name" ps --format json 2>/dev/null)" || return 0
  [[ -z "$json_output" ]] && return 0

  # Detect format: JSON array (starts with [) or NDJSON (one object per line)
  local parsed_lines=""
  if [[ "$json_output" == "["* ]]; then
    # Array format: use jq to split into individual objects
    parsed_lines="$(printf '%s' "$json_output" | jq -c '.[]' 2>/dev/null)"
  else
    parsed_lines="$json_output"
  fi

  local line svc_info service_name image container_id port_published target_port raw_health internal_port port_display
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    svc_info="$(_parse_service_json "$line")"
    [[ -z "$svc_info" ]] && continue

    IFS='|' read -r service_name image container_id port_published target_port <<< "$svc_info"
    raw_health="$(_parse_service_health_json "$line")"

    internal_port="$target_port"
    if [[ -z "$internal_port" ]]; then
      if [[ -z "$container_id" ]]; then
        container_id="$(docker compose -f "$compose_file" -p "$project_name" ps -q "$service_name" 2>/dev/null | head -1)"
      fi
      internal_port="$(_inspect_exposed_tcp_port "$container_id")"
    fi

    port_display="${internal_port:-${port_published:-none}}"
    if [[ -n "$HOSTED_SERVICES" ]]; then
      HOSTED_SERVICES="${HOSTED_SERVICES},${service_name}:${port_display}"
    else
      HOSTED_SERVICES="${service_name}:${port_display}"
    fi

    local health_label
    if [[ -n "$internal_port" ]]; then
      health_label="$(_normalize_service_health "$raw_health")"
      if [[ "$health_label" == "unknown" ]]; then
        health_label="$(_probe_http_service "$service_name" "$internal_port")"
      fi
      _record_hosted_http_health "$health_label"

      local port_note="internal"
      if [[ -n "$port_published" && "$port_published" != "$internal_port" ]]; then
        port_note="${port_note}, published host port ${port_published}"
      fi
      HOSTED_SERVICES_DETAIL="${HOSTED_SERVICES_DETAIL}
    - ${service_name}: http://${service_name}:${internal_port} (${port_note}, ${image}) [${health_label}]"
    elif [[ -n "$port_published" ]]; then
      health_label="$(_normalize_service_health "$raw_health")"
      if [[ "$health_label" == "unknown" ]]; then
        health_label="$(_probe_http_service "$service_name" "$port_published")"
      fi
      _record_hosted_http_health "$health_label"

      HOSTED_SERVICES_DETAIL="${HOSTED_SERVICES_DETAIL}
    - ${service_name}: http://${service_name}:${port_published} (published, ${image}) [${health_label}]"
    else
      HOSTED_SERVICES_DETAIL="${HOSTED_SERVICES_DETAIL}
    - ${service_name}: no discovered port (${image}) [not probed]"
    fi
  done <<< "$parsed_lines"
  HOSTED_SERVICES_DETAIL="${HOSTED_SERVICES_DETAIL#$'\n'}"  # trim leading newline
  _warn_if_all_hosted_http_unhealthy
}

# build_hosted_section
#   Prints the prompt section for agent prompt injection. Empty if no services.
build_hosted_section() {
  [[ -z "$HOSTED_SERVICES_DETAIL" ]] && return 0

  cat <<EOF
## Hosted Environment

The target application is running in an isolated Docker Compose environment.
All services are reachable via their service names on the compose network.
You may run DAST tools against these endpoints. Scanning is authorized and safe.

**Docker network:** ${HOSTED_NETWORK}

**Available services:**
${HOSTED_SERVICES_DETAIL}

**Running DAST tools via Docker:**
To run a tool against these services, connect it to the same network:
\`docker run --rm --network ${HOSTED_NETWORK} <image> <command>\`
EOF
}

# cleanup_hosted <run_id>
#   Tears down containers only if we started them (HOSTED_OWNER=true).
#   If we reused an existing compose project, leave it running.
#   Always returns 0 — cleanup failures are non-fatal.
cleanup_hosted() {
  local run_id="$1"

  if [[ "$HOSTED_OWNER" == "true" ]]; then
    local project_name
    project_name="repolens-$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]')"
    log_info "Tearing down hosted environment (project: ${project_name})..."
    docker compose -p "$project_name" down -v --remove-orphans 2>/dev/null
  else
    log_info "Hosted environment was pre-existing — leaving it running."
  fi
  HOSTED_NETWORK=""
  HOSTED_SERVICES=""
  HOSTED_SERVICES_DETAIL=""
  HOSTED_HTTP_SERVICE_COUNT=0
  HOSTED_HTTP_RESPONDING_COUNT=0
  HOSTED_HTTP_UNHEALTHY_COUNT=0
  HOSTED_HTTP_UNKNOWN_COUNT=0
  HOSTED_OWNER="false"
  log_info "Hosted environment cleanup complete"
  return 0
}
