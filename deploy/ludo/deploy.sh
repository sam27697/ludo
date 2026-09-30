#!/usr/bin/env bash
# Deploys ludo_server to /srv/apps/ludo/ on the deploy account of the target
# box. Run by that account only, never as root, never with sudo -- there is
# none in this script and none should ever be added to it.
#
# Usage, from /srv/apps/ludo/:
#
#   bash deploy/ludo/deploy.sh [ref]
#
# [ref] is a branch, tag, or commit sha to deploy; defaults to main.
#
# What it does, in order: fetches the repo checkout and hard-resets it to
# the resolved ref, builds an image tagged with the resulting short sha and
# the environment name, brings that image up with LUDO_VERSION set to that
# sha, polls /health over the published loopback port with a bounded number
# of attempts, and rolls back to whatever image was running before if the
# new one never comes healthy or if the version /health reports once it is
# healthy disagrees with the sha just deployed. For a production deploy
# only, it then also polls /health over 127.0.0.1:8080 -- the port
# provefair.app is proxied to (docs/VERIFY.md section 8) -- and rolls back
# the same way if that does not answer 200 either, so a deploy cannot be
# called healthy while the public verification hostname would still 503.
# Once a deploy is healthy and confirmed, it also checks whether the
# container's Docker network gateway is covered by TRUSTED_PROXIES in
# $ENV_FILE, appending trusted_proxy=ok, trusted_proxy=MISSING, or
# trusted_proxy=UNKNOWN to that same last line; this never fails the deploy
# and never rolls back on its own, and it never edits .env. It prints the
# sha deployed and the health result as its last line either way, and exits
# non-zero on a failed deploy after having rolled back.
#
# It never prints .env's contents and never echoes an environment variable
# value; the only things it prints are shas, tags, http status codes, and
# container log lines the application itself already wrote. The one
# exception is the trusted-proxy check at the end: it names the configured
# TRUSTED_PROXIES value when it does not cover the container's network
# gateway, because that value is a list of IP addresses, not a secret, and
# the point of the check is to say what does not match.

set -euo pipefail

ROOT="${LUDO_ROOT:-/srv/apps/ludo}"
REPO_DIR="$ROOT/repo"
COMPOSE_FILE="$REPO_DIR/deploy/ludo/docker-compose.yml"
PRODUCTION_COMPOSE_FILE="$REPO_DIR/deploy/ludo/docker-compose.production.yml"
DOCKERFILE="packages/ludo_server/Dockerfile"
SERVICE_NAME="ludo-server"
IMAGE_NAME="ludo-server"
ENVIRONMENT_NAME="${LUDO_ENVIRONMENT:-staging}"
HEALTH_ATTEMPTS=30
HEALTH_INTERVAL_SECONDS=2

REF="${1:-main}"

log() {
  printf '%s\n' "$*"
}

fail() {
  log "deploy.sh: $*"
  exit 1
}

require_file() {
  local path="$1" label="$2"
  [[ -f "$path" ]] || fail "missing $label: $path (see deploy/ludo/README.md)"
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

require_command git
require_command docker
require_command curl

# The port polled has to be the port the environment being deployed actually
# publishes, not a literal that happens to be right for staging. Unknown
# environments fail loudly here rather than falling back to staging's port
# and going on to print a health=ok that describes the wrong container.
case "$ENVIRONMENT_NAME" in
  staging)    DEFAULT_HEALTH_PORT=8199 ;;
  production) DEFAULT_HEALTH_PORT=8099 ;;
  *) fail "no known health port for LUDO_ENVIRONMENT='$ENVIRONMENT_NAME' -- set LUDO_HEALTH_PORT explicitly, or deploy with LUDO_ENVIRONMENT unset (staging) or LUDO_ENVIRONMENT=production" ;;
esac
HEALTH_PORT="${LUDO_HEALTH_PORT:-$DEFAULT_HEALTH_PORT}"
HEALTH_URL="http://127.0.0.1:${HEALTH_PORT}/health"

# provefair.app is proxied straight to 127.0.0.1:8080 on the host
# (docs/VERIFY.md section 8), a port only the production container ever
# publishes, so there is nothing to poll here for staging -- this is a
# fixed loopback address, not derived from HEALTH_PORT, and is only ever
# used once ENVIRONMENT_NAME is confirmed production, below.
PRODUCTION_VERIFY_HEALTH_URL="http://127.0.0.1:8080/health"

# staging and production are two independent deployments on this box, not
# one project split by an environment variable at deploy time: each gets
# its own directory under $ROOT to hold its own .env and its own record of
# what is currently running, so that a production deploy can never read,
# write, or roll back onto staging's state or the reverse. The case
# statement above has already rejected any ENVIRONMENT_NAME other than
# staging or production, so it is safe to build a path out of it here.
ENV_ROOT="$ROOT/$ENVIRONMENT_NAME"
ENV_FILE="$ENV_ROOT/.env"
STATE_FILE="$ENV_ROOT/.current_image_tag"

# docker compose derives the project name, and the base directory it
# resolves a compose file's own relative paths against (env_file:, volumes,
# build.context), from the "project directory" -- the directory holding the
# compose file, unless --project-directory says otherwise. COMPOSE_FILE
# lives inside the checkout, which staging and production share, so
# --project-directory has to point somewhere environment-specific or both
# environments would resolve the compose file's env_file: .env entry to
# the same file and would be the same compose project. Pin it to
# $ENV_ROOT, where this environment's own .env actually lives, and derive
# PROJECT_NAME from ENVIRONMENT_NAME rather than from $ROOT so the two
# environments can never end up owning the same set of containers.
PROJECT_NAME="ludo-$ENVIRONMENT_NAME"

# The compose file's ports: entry and container_name both read these two
# from the environment `docker compose` is invoked with (see bring_up()
# below and the logs call in roll_back_and_fail()). LUDO_PORT is set from
# HEALTH_PORT itself, not recomputed, so the port the container publishes
# and the port curl polls above are read from the same variable and cannot
# drift apart. LUDO_ENVIRONMENT is set from ENVIRONMENT_NAME, which the
# case statement above has already forced to a known value (staging or
# production) before either variable is used.
LUDO_ENVIRONMENT="$ENVIRONMENT_NAME"
LUDO_PORT="$HEALTH_PORT"

# Every `docker compose` call below reads this same list, built once, so a
# call added later cannot forget the production override by omission --
# there is one array to extend, not one `-f` flag to remember at each call
# site. Staging's list is exactly the base file, unchanged from before this
# override existed. The production override file's own existence is checked
# after the checkout is reset below, alongside COMPOSE_FILE, since both live
# inside it.
COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [[ "$ENVIRONMENT_NAME" == "production" ]]; then
  COMPOSE_ARGS+=(-f "$PRODUCTION_COMPOSE_FILE")
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ROOT/.env" ]]; then
    fail "missing $ENV_FILE -- found $ROOT/.env instead, which is the old shared location from before staging and production got their own directories. Fix by hand, once: mkdir -p \"$ENV_ROOT\" && mv \"$ROOT/.env\" \"$ENV_FILE\" (see deploy/ludo/README.md)"
  fi
  fail "missing .env: $ENV_FILE (see deploy/ludo/README.md)"
fi

[[ -d "$REPO_DIR/.git" ]] || fail "no checkout at $REPO_DIR -- clone it first, see README.md"

# Rooms live only in the running server process's memory (RoomRegistry,
# packages/ludo_server/lib/src/registry.dart), so recreating the container
# below without looking at how many rooms that process holds would silently
# end every game in progress. This guard reads that count off $HEALTH_URL,
# already computed above, and refuses, waits, or proceeds depending on the
# count -- before the first git or docker command below runs. A room's
# longest possible life is 60 minutes (registry.dart's reap interval), so
# waiting here is always bounded.

is_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" != "0" ]]
}

if [[ -n "${LUDO_DEPLOY_WAIT_SECONDS:-}" ]] && ! is_positive_integer "$LUDO_DEPLOY_WAIT_SECONDS"; then
  fail "LUDO_DEPLOY_WAIT_SECONDS must be a positive integer"
fi
if [[ -n "${LUDO_DEPLOY_POLL_SECONDS:-}" ]] && ! is_positive_integer "$LUDO_DEPLOY_POLL_SECONDS"; then
  fail "LUDO_DEPLOY_POLL_SECONDS must be a positive integer"
fi
LUDO_DEPLOY_POLL_SECONDS="${LUDO_DEPLOY_POLL_SECONDS:-30}"

# One curl call per read, body parsed with sed alone -- same reasoning as
# the version check further down: no jq or python assumed on the box.
read_live_rooms() {
  local body rooms
  if ! body="$(curl -s --max-time 5 "$HEALTH_URL")"; then
    printf 'unknown\n'
    return
  fi
  rooms="$(printf '%s' "$body" \
    | sed -n 's/.*"rooms"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  if [[ -z "$rooms" ]]; then
    printf 'unknown\n'
    return
  fi
  printf '%s\n' "$rooms"
}

live_rooms="$(read_live_rooms)"

if [[ "$live_rooms" == "unknown" ]]; then
  log "live_rooms=unknown"
elif [[ "$live_rooms" -eq 0 ]]; then
  log "live_rooms=0"
elif [[ "${LUDO_DEPLOY_FORCE:-}" == "1" ]]; then
  log "live_rooms=$live_rooms forced by LUDO_DEPLOY_FORCE=1"
elif [[ -z "${LUDO_DEPLOY_WAIT_SECONDS:-}" ]]; then
  fail "refusing: live_rooms=$live_rooms, nothing changed -- set LUDO_DEPLOY_WAIT_SECONDS to wait for rooms to end, or LUDO_DEPLOY_FORCE=1 to deploy anyway"
else
  waited=0
  while [[ "$waited" -lt "$LUDO_DEPLOY_WAIT_SECONDS" ]]; do
    sleep "$LUDO_DEPLOY_POLL_SECONDS"
    waited=$((waited + LUDO_DEPLOY_POLL_SECONDS))
    live_rooms="$(read_live_rooms)"
    if [[ "$live_rooms" == "unknown" ]]; then
      log "live_rooms=unknown"
      break
    fi
    if [[ "$live_rooms" -eq 0 ]]; then
      log "live_rooms=0 after waiting"
      break
    fi
  done
  if [[ "$live_rooms" != "unknown" ]] && [[ "$live_rooms" -gt 0 ]]; then
    fail "refusing: live_rooms=$live_rooms after waiting, nothing changed -- set LUDO_DEPLOY_FORCE=1 to deploy anyway"
  fi
fi

log "fetching origin into $REPO_DIR"
git -C "$REPO_DIR" fetch --quiet origin

if git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$REF" >/dev/null; then
  RESET_TARGET="origin/$REF"
else
  RESET_TARGET="$REF"
fi
git -C "$REPO_DIR" reset --hard --quiet "$RESET_TARGET"

# COMPOSE_FILE lives inside $REPO_DIR, so it only exists to be checked once
# the reset above has put the right ref's copy on disk; checking it earlier
# would be checking whatever the previous deploy left behind. Same reasoning
# for the production override, checked only when this deploy is production.
require_file "$COMPOSE_FILE" "docker-compose.yml (inside the checkout -- see deploy/ludo/README.md)"
if [[ "$ENVIRONMENT_NAME" == "production" ]]; then
  require_file "$PRODUCTION_COMPOSE_FILE" "docker-compose.production.yml (inside the checkout -- see deploy/ludo/README.md)"
fi

SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
log "resolved ref '$REF' to sha $SHA"

NEW_TAG="${IMAGE_NAME}:${ENVIRONMENT_NAME}-${SHA}"

PREVIOUS_TAG=""
PREVIOUS_SHA=""
if [[ -f "$STATE_FILE" ]]; then
  PREVIOUS_TAG="$(cat "$STATE_FILE")"
  # The tag this script writes to STATE_FILE is always
  # "$IMAGE_NAME:$ENVIRONMENT_NAME-<sha>"; strip that prefix back off to
  # recover the sha the previous image was actually built from, so a
  # rollback reports the version it is actually rolling back to rather than
  # the sha of the deploy that just failed.
  PREVIOUS_SHA="${PREVIOUS_TAG#"$IMAGE_NAME:$ENVIRONMENT_NAME-"}"
fi

log "building $NEW_TAG"
docker build \
  -f "$REPO_DIR/$DOCKERFILE" \
  -t "$NEW_TAG" \
  "$REPO_DIR"

bring_up() {
  local tag="$1" version="$2"
  LUDO_IMAGE_TAG="$tag" LUDO_VERSION="$version" \
  LUDO_ENVIRONMENT="$LUDO_ENVIRONMENT" LUDO_PORT="$LUDO_PORT" \
  docker compose \
    --project-name "$PROJECT_NAME" \
    --project-directory "$ENV_ROOT" \
    "${COMPOSE_ARGS[@]}" \
    --env-file "$ENV_FILE" \
    up -d --remove-orphans
}

# Rolls back to whatever was running before (if anything was), prints the
# expected-vs-reported sha, and exits non-zero. Shared by both ways a deploy
# can fail: the readiness poll never turning up 200, and the readiness poll
# turning up 200 from a process that is not the sha just deployed.
roll_back_and_fail() {
  log "$*"
  log "last 50 lines of container log:"
  LUDO_IMAGE_TAG="$NEW_TAG" \
  LUDO_ENVIRONMENT="$LUDO_ENVIRONMENT" LUDO_PORT="$LUDO_PORT" \
  docker compose \
    --project-name "$PROJECT_NAME" \
    --project-directory "$ENV_ROOT" \
    "${COMPOSE_ARGS[@]}" \
    --env-file "$ENV_FILE" \
    logs --no-color --tail 50 "$SERVICE_NAME" || true

  if [[ -n "$PREVIOUS_TAG" ]]; then
    log "rolling back to $PREVIOUS_TAG"
    bring_up "$PREVIOUS_TAG" "$PREVIOUS_SHA"
  else
    log "no previous image recorded -- nothing to roll back to, container left as-is for inspection"
  fi

  log "sha=$SHA health=fail"
  exit 1
}

log "bringing up $NEW_TAG"
bring_up "$NEW_TAG" "$SHA"

healthy="no"
attempt=1
while [[ "$attempt" -le "$HEALTH_ATTEMPTS" ]]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    healthy="yes"
    break
  fi
  attempt=$((attempt + 1))
  sleep "$HEALTH_INTERVAL_SECONDS"
done

if [[ "$healthy" != "yes" ]]; then
  roll_back_and_fail "health check failed for $NEW_TAG after $HEALTH_ATTEMPTS attempts (last status: ${code:-none})"
fi

# The status code alone only proves a process is listening and answering;
# the body proves it is the sha just built. /health's body is the flat
# four-key object health_test.dart pins down, so a plain pattern match on
# the version field is enough -- no JSON tool is assumed to be on the box.
health_body="$(curl -s "$HEALTH_URL" 2>/dev/null || true)"
reported_version="$(printf '%s' "$health_body" \
  | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [[ "$reported_version" != "$SHA" ]]; then
  roll_back_and_fail "version mismatch after deploy: expected sha $SHA, /health reported '${reported_version:-<empty>}'"
fi

# provefair.app is proxied straight to 127.0.0.1:8080 (docs/VERIFY.md
# section 8), and only docker-compose.production.yml publishes that port on
# this container. The poll above already proved the container itself is
# healthy on its own environment port; this proves the second, production-
# only port mapping actually took, so a compose file that failed to load
# the override -- or an override that stopped adding the port -- fails the
# deploy instead of leaving provefair.app answering 503 under a "healthy"
# deploy.
if [[ "$ENVIRONMENT_NAME" == "production" ]]; then
  verify_port_healthy="no"
  verify_port_attempt=1
  while [[ "$verify_port_attempt" -le "$HEALTH_ATTEMPTS" ]]; do
    verify_port_code="$(curl -s -o /dev/null -w '%{http_code}' "$PRODUCTION_VERIFY_HEALTH_URL" 2>/dev/null || true)"
    if [[ "$verify_port_code" == "200" ]]; then
      verify_port_healthy="yes"
      break
    fi
    verify_port_attempt=$((verify_port_attempt + 1))
    sleep "$HEALTH_INTERVAL_SECONDS"
  done

  if [[ "$verify_port_healthy" != "yes" ]]; then
    roll_back_and_fail "health check failed on $PRODUCTION_VERIFY_HEALTH_URL for $NEW_TAG after $HEALTH_ATTEMPTS attempts (last status: ${verify_port_code:-none}) -- provefair.app would answer 503"
  fi
fi

echo "$NEW_TAG" > "$STATE_FILE"

# The rate limiter in bin/server.dart scopes by client address, trusting
# X-Forwarded-For only from peers listed in TRUSTED_PROXIES. The only peer
# any connection ever has inside this container is the Docker network
# gateway (measured 2026-09-26: /proc/net/tcp inside the container while a
# connection was held open through the public hostname), so TRUSTED_PROXIES
# has to name that gateway or every client collapses into one shared
# bucket. The gateway is whatever subnet Docker handed the compose network
# when it was created, not a fixed address, so this reads it from the
# container actually running rather than assuming it. This never fails the
# deploy and never touches .env: the previous image ran under the same
# .env, so rolling back on a mismatch here would fix nothing.
check_trusted_proxy() {
  local container="$SERVICE_NAME-$LUDO_ENVIRONMENT"
  local networks
  networks="$(docker inspect --format \
    '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}={{$conf.Gateway}}{{"\n"}}{{end}}' \
    "$container" 2>/dev/null || true)"

  local net_count
  net_count="$(printf '%s\n' "$networks" | grep -c '=' || true)"

  if [[ "$net_count" -ne 1 ]]; then
    log "trusted_proxy check: '$container' is attached to $net_count networks, expected exactly 1 -- cannot tell which gateway matters"
    TRUSTED_PROXY_RESULT="UNKNOWN"
    return
  fi

  local gateway="${networks#*=}"
  gateway="${gateway%$'\n'}"

  if [[ -z "$gateway" ]]; then
    log "trusted_proxy check: the network gateway reported for '$container' is empty"
    TRUSTED_PROXY_RESULT="UNKNOWN"
    return
  fi

  local configured
  configured="$(sed -n 's/^TRUSTED_PROXIES=//p' "$ENV_FILE" | tail -n1)"

  local proxy_list ip
  IFS=',' read -ra proxy_list <<< "$configured"
  for ip in "${proxy_list[@]:-}"; do
    ip="${ip//[[:space:]]/}"
    if [[ -n "$ip" && "$ip" == "$gateway" ]]; then
      TRUSTED_PROXY_RESULT="ok"
      return
    fi
  done

  log "trusted_proxy check: gateway is $gateway, TRUSTED_PROXIES is ${configured:-<empty>} -- every client will share one rate-limit bucket"
  TRUSTED_PROXY_RESULT="MISSING"
}

TRUSTED_PROXY_RESULT=""
check_trusted_proxy
log "sha=$SHA health=ok version=$reported_version trusted_proxy=$TRUSTED_PROXY_RESULT"
