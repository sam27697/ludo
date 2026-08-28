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

`LUDO_ENVIRONMENT` is not set in `.env` and is never read from it. It is an
environment variable the operator sets on the `deploy.sh` invocation itself
(`LUDO_ENVIRONMENT=production bash repo/deploy/ludo/deploy.sh main`, or left
unset for staging). `deploy.sh` validates it, derives the health port from
it, and passes it straight through to `docker compose` as `LUDO_ENVIRONMENT`
and `LUDO_PORT`, which the compose file uses to name the container
(`ludo-server-staging` / `ludo-server-production`) and to publish it on the
right loopback port (`8199` / `8099`). Neither has a default inside the
compose file: calling `docker compose` on this file directly, without
either variable set, is refused rather than silently publishing on the
wrong port under the wrong name.

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

## The first deploy after container_name became environment-scoped

Before this change, `docker-compose.yml` gave the container the fixed name
`ludo-server`. After it, the name is `ludo-server-${LUDO_ENVIRONMENT}`, so a
box already running a container literally named `ludo-server` will meet a
compose file that no longer says that name on the very next deploy.

Docker compose does not use `container_name` to decide whether a container
already belongs to a service; it uses its own labels
(`com.docker.compose.project`, `.service`, `.container-number`), which were
already on the running container and do not change here. The service key
is still `ludo-server`, the project name is still `ludo`
(`--project-name`/`--project-directory` are unchanged, pinned by order
031). So `docker compose up` should recognise the existing container as
the current instance of the `ludo-server` service, see that its
`container_name` no longer matches the desired config, and recreate it
under the new name in place -- not leave a duplicate running under the old
name, and not treat it as an orphan `--remove-orphans` has to clear (an
orphan is a container for a service no longer defined in the file at all;
`ludo-server` is still defined, just renamed).

This is reasoned from how compose is documented to match containers to
services, not measured -- there is no `docker` binary available while
writing this, so it has not been run against a real running container.
Before relying on it: after the first deploy following this change, run
`docker compose --project-name ludo --project-directory /srv/apps/ludo -f
repo/deploy/ludo/docker-compose.yml --env-file .env ps` and confirm there
is exactly one container for the `ludo-server` service and its name is
`ludo-server-staging` (or `-production`), not a second container sitting
alongside a leftover `ludo-server`. If a stray `ludo-server` container is
still present, stop and remove it by hand
(`docker stop ludo-server && docker rm ludo-server`) before deploying
again -- do not assume the next run will clear it on its own.

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
LUDO_VERSION=<short-sha> \
LUDO_ENVIRONMENT=staging LUDO_PORT=8199 docker compose \
  --project-name ludo --project-directory /srv/apps/ludo \
  -f repo/deploy/ludo/docker-compose.yml --env-file .env up -d --remove-orphans
```

Use `LUDO_ENVIRONMENT=production LUDO_PORT=8099` instead of the staging
values above if this is a production box. `LUDO_ENVIRONMENT` and
`LUDO_PORT` are required on every `docker compose` invocation against this
file now, hand-run ones included; without them compose refuses to start
rather than publishing on whatever port the file happened to default to.

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
  LUDO_ENVIRONMENT=staging LUDO_PORT=8199 \
  docker compose --project-name ludo --project-directory /srv/apps/ludo \
    -f repo/deploy/ludo/docker-compose.yml --env-file .env ps
  LUDO_ENVIRONMENT=staging LUDO_PORT=8199 \
  docker compose --project-name ludo --project-directory /srv/apps/ludo \
    -f repo/deploy/ludo/docker-compose.yml --env-file .env logs --tail 100 \
    ludo-server
  ```
  and read what the process actually said on its way down. (Use
  `LUDO_ENVIRONMENT=production LUDO_PORT=8099` on a production box. Both
  are required for any hand-run `docker compose` command against this file
  now, `ps` and `logs` included -- compose parses the whole file, so even a
  read-only command needs `container_name` and `ports:` to resolve.)
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

- Resolved: `docker-compose.yml`'s `ports:` and `container_name` used to be
  the literals `127.0.0.1:8199:8080` and `ludo-server`, so a
  `LUDO_ENVIRONMENT=production` deploy built a production image, published
  it on staging's port, and would have collided with a running staging
  container on the container name besides. Both now read `LUDO_PORT` and
  `LUDO_ENVIRONMENT` from the same `docker compose` invocation `deploy.sh`
  drives -- `LUDO_PORT` is set from the exact `HEALTH_PORT` variable
  `deploy.sh` polls with, not recomputed separately, so the published port
  and the polled port cannot read different values by construction.

- Not resolved, and outside what this order's file list allowed touching:
  `ROOT` in `deploy.sh` is the hard-coded literal `/srv/apps/ludo`,
  independent of where the script is invoked from. For staging and
  production to truly coexist on one box, each needs its own `.env`
  (different `PORT`/`TRUSTED_PROXIES` are not the concern here, but a
  shared `.env` means a shared `TRUSTED_PROXIES` even if the concern
  someday becomes environment-specific) and, more urgently, its own
  `.current_image_tag`. With one shared `ROOT`, a production deploy and a
  staging deploy write and read the same `$ROOT/.current_image_tag`, and
  `roll_back_and_fail`'s prefix-strip
  (`${PREVIOUS_TAG#"$IMAGE_NAME:$ENVIRONMENT_NAME-"}`) only produces a bare
  sha when the recorded tag was written by a deploy of the *same*
  environment; if the last deploy to touch that file was the other
  environment, the strip silently no-ops (bash leaves the string alone
  when the prefix does not match) and a subsequent rollback would try to
  bring up the other environment's image tag under the wrong
  `LUDO_VERSION`. This order made the container-level identity
  (name, port) environment-safe; the deploy-state level (one `ROOT`, one
  `.env`, one state file) is not, and running staging and production from
  the same `$ROOT` is not safe until that is addressed -- most likely by
  giving each environment its own `$ROOT` directory and its own checkout,
  which means `ROOT` in `deploy.sh` stopping being a single hard-coded
  path. That is a `deploy.sh` restructure, not a variable pass-through,
  and was out of this order's file list.

## Out of scope here

TLS, the reverse proxy configuration, and the Android release build are
not this deploy's concern. Hostnames (`stg.ludo.provefair.app`,
`ludo.provefair.app`) are root policy on the box and are not changed here;
nothing in this order needed a hostname change.

Actually bringing up production -- deciding where its checkout and `.env`
live, and resolving the shared-`ROOT` finding above -- is the master's,
from the box, after staging is deployed and verified with this change
first.
