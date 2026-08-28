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
cp repo/deploy/ludo/env.example .env
# edit .env now: set PORT (leave at 8080 unless you also change the
# container-side half of the port mapping in docker-compose.yml) and
# TRUSTED_PROXIES (see the comments in .env for why this needs confirming
# against the real network path before it is anything but empty)
chmod 600 .env
bash repo/deploy/ludo/deploy.sh main
```

`.env` is copied out of the checkout once, by hand, at install time -- not
symlinked into `repo/`, so a later `git reset --hard` inside `repo/` during a
deploy never touches it. `deploy.sh` reads it from `/srv/apps/ludo/.env`
directly, not from inside `repo/`.

`docker-compose.yml` is **not** copied anywhere. `deploy.sh` reads it
straight out of the checkout, at `repo/deploy/ludo/docker-compose.yml`, after
resetting that checkout to the ref being deployed -- so whatever compose
change is merged is what runs, the same way a code change is. It passes
`--project-directory /srv/apps/ludo` on every `docker compose` call so the
compose file's own relative paths (its `env_file: .env` entry) still resolve
against `/srv/apps/ludo/`, where `.env` actually lives, and so the project
name stays `ludo` regardless of where inside the checkout the file sits.

If this box was set up before this changed, there is a stale hand-placed
copy sitting at `/srv/apps/ludo/docker-compose.yml`. `deploy.sh` no longer
reads it. It is not load-bearing and can be deleted; nothing refers to it
anymore.

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
tagged `ludo-server:staging-<short-sha>`, brings it up with `LUDO_VERSION`
set to that same short sha, and polls `GET /health` over the loopback port
for the environment being deployed -- `127.0.0.1:8199` for staging,
`127.0.0.1:8099` for production, `LUDO_ENVIRONMENT` selects which and
`LUDO_HEALTH_PORT` overrides the port directly if a deploy ever needs a
non-default one -- until it answers `200` or the attempt budget runs out.
Once it answers `200`, the script fetches `/health` once more and compares
the `version` field it reports against the sha it just deployed. If it never
answers `200`, or if it answers but reports a different sha, the script
prints the last 50 lines of the container's log, brings the
previously-deployed image back up, and exits non-zero. Nothing succeeds
silently and nothing fails silently.

An `ENVIRONMENT_NAME` deploy.sh does not recognise fails immediately, before
anything is built or brought up, rather than quietly polling staging's port
on a deploy meant for somewhere else.

The last line the script prints is always `sha=<short-sha>
health=ok version=<short-sha>` or `sha=<short-sha> health=fail`, whether or
not it rolled back.

## Rolling back by hand

The script rolls back automatically on a failed health check or a version
mismatch. To roll back manually to a specific previously-built image (they
are never deleted by this script, only superseded):

```
cd /srv/apps/ludo
docker images ludo-server
LUDO_IMAGE_TAG=ludo-server:staging-<short-sha> \
LUDO_VERSION=<short-sha> docker compose \
  --project-name ludo --project-directory /srv/apps/ludo \
  -f repo/deploy/ludo/docker-compose.yml --env-file .env up -d --remove-orphans
```

`--project-name ludo --project-directory /srv/apps/ludo` matter here, not
just for `deploy.sh`: without them `docker compose` derives both from the
directory the `-f` file sits in (`repo/deploy/ludo/`), which resolves the
compose file's `env_file: .env` entry to a `.env` that does not exist there
and, if the derived name ever stopped matching, would bring up a second
container beside the one already running instead of replacing it.

Then update `/srv/apps/ludo/.current_image_tag` to match, so the next
`deploy.sh` run rolls back to the right place if it needs to.

## What tells you it broke, and what each answer means

Run, from anywhere with network access to the staging hostname:

```
curl -sS https://stg.ludo.provefair.app/health
```

Then, from the `deploy` account on the box itself:

```
curl -sS http://127.0.0.1:8199/health
```

A healthy process answers both with `200` and a small JSON body:
`{"status":"ok","version":"<short-sha>","uptime_s":<n>,"rooms":<n>}`. The
`version` field is what `deploy.sh` set `LUDO_VERSION` to on the last deploy
that succeeded; read it and confirm it is the sha you expect running, not
just that the status code came back `200`.

- Both commands return `200` and agree on `version`: the container is up,
  the reverse proxy is forwarding correctly, TLS terminates correctly, and
  it is running the build you think it is. If a player still reports a
  problem, it is at the protocol layer above this, not here.
- The loopback command (`127.0.0.1:8199`) returns `200` but the public one
  fails, times out, or returns something from a different server: the
  container is fine. The break is DNS, TLS, or the reverse proxy, none of
  which this deploy account can see or fix -- escalate to whoever holds the
  proxy and the DNS zone.
- The loopback command fails to connect at all (connection refused, or
  curl reports it cannot connect): the container is down or never came up.
  Run, from `/srv/apps/ludo/`:
  ```
  docker compose --project-name ludo --project-directory /srv/apps/ludo \
    -f repo/deploy/ludo/docker-compose.yml --env-file .env ps
  docker compose --project-name ludo --project-directory /srv/apps/ludo \
    -f repo/deploy/ludo/docker-compose.yml --env-file .env logs --tail 100 \
    ludo-server
  ```
  and read what the process actually said on its way down.
- The loopback command connects but returns something other than `200`
  (a `502`, a connection reset mid-response, anything else): something is
  listening on `127.0.0.1:8199` but it is not this container answering
  normally -- check `docker compose ps` for a crash-looping container before
  assuming anything about the proxy.

## What we found, for the next order

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

- `deploy.sh` now derives the port it polls from `LUDO_ENVIRONMENT`
  (`8199` staging, `8099` production), but `docker-compose.yml`'s `ports:`
  entry is still the literal `127.0.0.1:8199:8080` -- it does not read
  `LUDO_ENVIRONMENT` at all. A deploy run with `LUDO_ENVIRONMENT=production`
  today would build and tag a production image correctly, bring it up, and
  still publish it on `8199`, the same host port staging uses, while
  `deploy.sh` polls `8099` and finds nothing there -- the deploy fails loudly
  and rolls back rather than reporting a false `health=ok`, but it will
  never succeed until the compose file's port mapping is made to follow
  `LUDO_ENVIRONMENT` the same way the image tag already does. That is a
  change to `docker-compose.yml` and is not part of this order.

## Out of scope here

Production (`ludo.provefair.app`, port 8099), TLS, the reverse proxy
configuration, and the Android release build are not this deploy's concern.
Before staging's setup is reused for production, `docker-compose.yml`'s
`ports:` mapping needs to stop being the literal `8199` and start following
`LUDO_ENVIRONMENT` the way `deploy.sh` itself now does (see the finding
above) -- `LUDO_ENVIRONMENT=production` alone is not enough yet.
