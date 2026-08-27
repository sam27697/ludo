# Deploying ludo_server to staging

Target: `asam-prod-01`, the `deploy` account, `/srv/apps/ludo/`. Rootless
Docker, `DOCKER_HOST=unix:///run/user/1000/docker.sock`. No sudo, no docker
group membership, no access to the reverse proxy. This account only ever
touches `/srv/apps/ludo/`.

## Fresh install, from an empty `/srv/apps/ludo/`

Run as the `deploy` account. Replace `<repo-url>` with the real remote.

```
mkdir -p /srv/apps/ludo
cd /srv/apps/ludo
git clone <repo-url> repo
cp repo/deploy/ludo/docker-compose.yml docker-compose.yml
cp repo/deploy/ludo/env.example .env
# edit .env now: set PORT (leave at 8080 unless you also change the
# container-side half of the port mapping in docker-compose.yml) and
# TRUSTED_PROXIES (see the comments in .env for why this needs confirming
# against the real network path before it is anything but empty)
chmod 600 .env
bash repo/deploy/ludo/deploy.sh main
```

`docker-compose.yml` and `.env` are copied out of the checkout once, by
hand, at install time -- not symlinked into `repo/`, so a later `git reset
--hard` inside `repo/` during a deploy never touches either of them.
`deploy.sh` reads them from `/srv/apps/ludo/` directly, not from inside
`repo/`.

## Deploying

```
cd /srv/apps/ludo
bash repo/deploy/ludo/deploy.sh main
```

or a specific ref:

```
bash repo/deploy/ludo/deploy.sh v0.3.1
bash repo/deploy/ludo/deploy.sh 1c9e072
```

The script fetches, hard-resets `repo/` to the resolved ref, builds an image
tagged `ludo-server:staging-<short-sha>`, brings it up, and polls it over
`127.0.0.1:8199` (the published loopback port, the same port the reverse
proxy already forwards `stg.ludo.provefair.app` to) until it answers or the
attempt budget runs out. If it never answers healthy, the script prints the
last 50 lines of the container's log, brings the previously-deployed image
back up, and exits non-zero. Nothing succeeds silently and nothing fails
silently.

The last line the script prints is always `sha=<short-sha>
health=ok` or `sha=<short-sha> health=fail`, whether or not it rolled back.

## Rolling back by hand

The script rolls back automatically on a failed health check. To roll back
manually to a specific previously-built image (they are never deleted by
this script, only superseded):

```
cd /srv/apps/ludo
docker images ludo-server
LUDO_IMAGE_TAG=ludo-server:staging-<short-sha> docker compose \
  -f docker-compose.yml --env-file .env up -d --remove-orphans
```

Then update `/srv/apps/ludo/.current_image_tag` to match, so the next
`deploy.sh` run rolls back to the right place if it needs to.

## What tells you it broke, and what each answer means

Run, from anywhere with network access to the staging hostname:

```
curl -sS -o /dev/null -w '%{http_code}\n' https://stg.ludo.provefair.app/
```

Then, from the `deploy` account on the box itself:

```
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8199/
```

There is no dedicated health endpoint in `packages/ludo_server` as of this
order (see "What we found" below); a plain `404` with the body `Only
WebSocket connections are supported.` is what a healthy process returns to a
GET, because every request that is not a WebSocket upgrade gets that fixed
response. That is the signal to read, not "some 2xx".

- Both commands return `404`: the container is up, the reverse proxy is
  forwarding correctly, and TLS terminates correctly. The staging server is
  healthy. If a player still reports a problem, it is at the protocol layer
  above this, not here.
- The loopback command (`127.0.0.1:8199`) returns `404` but the public one
  fails, times out, or returns something from a different server: the
  container is fine. The break is DNS, TLS, or the reverse proxy, none of
  which this deploy account can see or fix -- escalate to whoever holds the
  proxy and the DNS zone.
- The loopback command fails to connect at all (connection refused, or
  curl reports it cannot connect): the container is down or never came up.
  Run `docker compose -f docker-compose.yml --env-file .env ps` and
  `docker compose -f docker-compose.yml --env-file .env logs --tail 100
  ludo-server` from `/srv/apps/ludo/` and read what the process actually
  said on its way down.
- The loopback command connects but returns something other than `404`
  (a `502`, a connection reset mid-response, anything else): something is
  listening on `127.0.0.1:8199` but it is not this container answering
  normally -- check `docker compose ps` for a crash-looping container before
  assuming anything about the proxy.

## What we found, for the next order

- `packages/ludo_server` has no HTTP health endpoint. Every GET that is not
  a WebSocket upgrade returns a fixed `404` from `shelf_web_socket`. This is
  used throughout this deploy (Dockerfile `HEALTHCHECK`, compose
  `healthcheck`, and `deploy.sh`'s own poll) as a stand-in liveness signal:
  it proves the process is bound to the port and running its request
  pipeline, but it proves nothing about room state, memory pressure, or
  whether the housekeeping timer is still running. A real `/health` (or
  similar) endpoint is server source, outside this order's file list, and
  is the next order's business.
- `TRUSTED_PROXIES` is read by `bin/server.dart` and is meant to hold the
  addresses of proxies allowed to set `X-Forwarded-For`. What address the
  Dart process actually sees as the immediate TCP peer, once a connection
  has passed through the root-owned reverse proxy and then through rootless
  Docker's userspace port forwarding on the way to `127.0.0.1:8199:8080`,
  is not something this order could determine without shell access to the
  real host. Rootless Docker's default port-publishing path does not always
  preserve the original client address; if it does not, every connection
  looks like it comes from the same forwarding address, and per-IP rate
  limiting (`docs/PROTOCOL.md` section 7) effectively collapses to one
  shared bucket for everybody until this is confirmed and, if needed,
  `TRUSTED_PROXIES` and the reverse proxy's forwarded-for header are wired
  up correctly together. Confirm this on the real box before staging is
  used for anything load-related.

## Out of scope here

Production (`ludo.provefair.app`, port 8099), TLS, the reverse proxy
configuration, and the Android release build are not this deploy's concern.
When staging is proven, these same files get an environment change
(`LUDO_ENVIRONMENT=production`, a different host port already reserved by
the proxy), not a rewrite.
