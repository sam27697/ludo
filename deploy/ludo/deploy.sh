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
# the environment name, brings that image up, polls its health over the
# published loopback port with a bounded number of attempts, and rolls back
# to whatever image was running before if the new one never comes healthy.
# It prints the sha deployed and the health result as its last line either
# way, and exits non-zero on a failed deploy after having rolled back.
#
# It never prints .env's contents and never echoes an environment variable
# value; the only things it prints are shas, tags, http status codes, and
# container log lines the application itself already wrote.

set -euo pipefail

ROOT="/srv/apps/ludo"
REPO_DIR="$ROOT/repo"
COMPOSE_FILE="$ROOT/docker-compose.yml"
ENV_FILE="$ROOT/.env"
STATE_FILE="$ROOT/.current_image_tag"
DOCKERFILE="packages/ludo_server/Dockerfile"
SERVICE_NAME="ludo-server"
IMAGE_NAME="ludo-server"
ENVIRONMENT_NAME="${LUDO_ENVIRONMENT:-staging}"
HEALTH_URL="http://127.0.0.1:8199/"
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

require_file "$COMPOSE_FILE" "docker-compose.yml"
require_file "$ENV_FILE" ".env"

[[ -d "$REPO_DIR/.git" ]] || fail "no checkout at $REPO_DIR -- clone it first, see README.md"

log "fetching origin into $REPO_DIR"
git -C "$REPO_DIR" fetch --quiet origin

if git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$REF" >/dev/null; then
  RESET_TARGET="origin/$REF"
else
  RESET_TARGET="$REF"
fi
git -C "$REPO_DIR" reset --hard --quiet "$RESET_TARGET"

SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
log "resolved ref '$REF' to sha $SHA"

NEW_TAG="${IMAGE_NAME}:${ENVIRONMENT_NAME}-${SHA}"

PREVIOUS_TAG=""
if [[ -f "$STATE_FILE" ]]; then
  PREVIOUS_TAG="$(cat "$STATE_FILE")"
fi

log "building $NEW_TAG"
docker build \
  -f "$REPO_DIR/$DOCKERFILE" \
  -t "$NEW_TAG" \
  "$REPO_DIR"

bring_up() {
  local tag="$1"
  LUDO_IMAGE_TAG="$tag" docker compose \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    up -d --remove-orphans
}

log "bringing up $NEW_TAG"
bring_up "$NEW_TAG"

healthy="no"
attempt=1
while [[ "$attempt" -le "$HEALTH_ATTEMPTS" ]]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || true)"
  # No dedicated health endpoint exists yet (see README.md); every
  # non-WebSocket request gets a fixed 404 from shelf_web_socket, and that
  # 404 is only reachable if the process is bound and serving, so it is
  # used as the liveness signal here.
  if [[ "$code" == "404" ]]; then
    healthy="yes"
    break
  fi
  attempt=$((attempt + 1))
  sleep "$HEALTH_INTERVAL_SECONDS"
done

if [[ "$healthy" != "yes" ]]; then
  log "health check failed for $NEW_TAG after $HEALTH_ATTEMPTS attempts (last status: ${code:-none})"
  log "last 50 lines of container log:"
  LUDO_IMAGE_TAG="$NEW_TAG" docker compose \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    logs --no-color --tail 50 "$SERVICE_NAME" || true

  if [[ -n "$PREVIOUS_TAG" ]]; then
    log "rolling back to $PREVIOUS_TAG"
    bring_up "$PREVIOUS_TAG"
  else
    log "no previous image recorded -- nothing to roll back to, container left as-is for inspection"
  fi

  log "sha=$SHA health=fail"
  exit 1
fi

echo "$NEW_TAG" > "$STATE_FILE"
log "sha=$SHA health=ok"
