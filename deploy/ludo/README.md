# Deploying ludo_server

Target: `asam-prod-01`, the `deploy` account, `/srv/apps/ludo/`. Rootless
Docker, `DOCKER_HOST=unix:///run/user/1000/docker.sock`. No sudo, no docker
group membership, no access to the reverse proxy. This account only ever
touches `/srv/apps/ludo/`.

## Layout

```
/srv/apps/ludo/                     $ROOT, shared
  repo/                             the git checkout, shared, one clone
  staging/
    .env                            staging's own
    .current_image_tag              staging's own, deploy.sh's rollback record
  production/
    .env                            production's own
    .current_image_tag              production's own
```

Only `repo/` is shared. Staging and production each get their own directory
holding their own `.env` and their own `.current_image_tag`, and `deploy.sh`
runs docker compose with `--project-name ludo-staging` /
`--project-name ludo-production` and `--project-directory` pointed at the
matching directory, so the two environments never share a compose project,
never read or write each other's `.env`, and a rollback in one can never
land an image the other environment built. `LUDO_ENVIRONMENT` picks which
of `staging/` or `production/` a given `deploy.sh` run uses; it is not read
from either `.env`.

## Fresh install, from an empty `/srv/apps/ludo/`

Run as the `deploy` account. Replace `<repo-url>` with the real remote. Do
this once for the checkout, then once per environment for its `.env`.

```
mkdir -p /srv/apps/ludo
cd /srv/apps/ludo
git clone <repo-url> repo

mkdir -p staging
cp repo/deploy/ludo/env.example staging/.env
# edit staging/.env now: set PORT (leave at 8080 unless you also change the
# container-side half of the port mapping in docker-compose.yml) and
# TRUSTED_PROXIES to the gateway of the ludo-staging_default network (see
# "What we found" below for how to read it; deploy.sh will tell you if you
# got it wrong)
chmod 600 staging/.env
bash repo/deploy/ludo/deploy.sh main
# deploy.sh's own gateway check cannot run before the container exists, so
# the first deploy above will report trusted_proxy=MISSING if .env was left
# at the empty default. Read the gateway it reports, put it in
# staging/.env, and deploy again.

mkdir -p production
cp repo/deploy/ludo/env.example production/.env
# edit production/.env the same way, against production's own network path
chmod 600 production/.env
LUDO_ENVIRONMENT=production bash repo/deploy/ludo/deploy.sh main
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
deploy never touches it. `deploy.sh` reads it from `/srv/apps/ludo/staging/.env`
or `/srv/apps/ludo/production/.env` directly, whichever `LUDO_ENVIRONMENT`
selects, never from inside `repo/` and never from the other environment's
directory.

`docker-compose.yml` is **not** copied anywhere. `deploy.sh` reads it
straight out of the checkout, at `repo/deploy/ludo/docker-compose.yml`, after
resetting that checkout to the ref being deployed -- so whatever compose
change is merged is what runs, the same way a code change is. It passes
`--project-directory /srv/apps/ludo/staging` (or `.../production`) on every
`docker compose` call so the compose file's own relative paths (its
`env_file: .env` entry) resolve against that environment's own directory,
where its `.env` actually lives, and the project name is `ludo-staging` /
`ludo-production` -- one compose project per environment, never shared,
so a production deploy cannot recreate the staging container and a staging
deploy cannot touch production's.

If this box was set up before this changed, there is a stale hand-placed
copy sitting at `/srv/apps/ludo/docker-compose.yml`. `deploy.sh` no longer
reads it. It is not load-bearing and can be deleted; nothing refers to it
anymore.

## The first deploy after the environment split

Before this change, everything staging and production would ever have run
under -- `.env`, `.current_image_tag`, and the compose project itself --
lived directly under `/srv/apps/ludo`, and the compose project name was the
single literal `ludo`. The box today still has a staging container running
under that old `ludo` project, plus `/srv/apps/ludo/.env` and
`/srv/apps/ludo/.current_image_tag` sitting in the old shared locations.
`deploy.sh` as of this change no longer knows about any of that: the project
name it computes is `ludo-staging` / `ludo-production`, and it reads and
writes `.env` and `.current_image_tag` only under `staging/` or
`production/`. It will not find, adopt, or touch the old `ludo`-project
container, because docker compose matches containers to a project by the
project's name, and `ludo` and `ludo-staging` are different names -- this is
not the `container_name`-only rename order 036 reasoned through, where the
project stayed `ludo` throughout; the project itself now changes.

This means the old container is not migrated automatically and is not this
script's job to migrate. Before the first deploy under this change:

1. Move `/srv/apps/ludo/.env` to `/srv/apps/ludo/staging/.env` (`mkdir -p
   /srv/apps/ludo/staging` first). `deploy.sh` refuses to run and names
   this exact move if it finds the old `.env` and not the new one. Moving
   `/srv/apps/ludo/.current_image_tag` to
   `/srv/apps/ludo/staging/.current_image_tag` alongside it is optional but
   recommended: `deploy.sh` treats a missing state file as "no previous
   deploy on record", which is correct for a genuinely fresh environment
   but here means the next failed deploy has nothing recorded to roll back
   to, and just leaves the failed container up for inspection instead.
2. Stop and remove the old `ludo`-project staging container by hand
   (`docker compose --project-name ludo --project-directory /srv/apps/ludo
   -f repo/deploy/ludo/docker-compose.yml --env-file /srv/apps/ludo/staging/.env
   down`, or `docker stop`/`docker rm` directly on the container) so the
   next deploy is not publishing `8199` against a container already holding
   it.
3. Run `LUDO_ENVIRONMENT=staging bash repo/deploy/ludo/deploy.sh main` and
   confirm with `docker compose --project-name ludo-staging
   --project-directory /srv/apps/ludo/staging -f
   repo/deploy/ludo/docker-compose.yml --env-file
   /srv/apps/ludo/staging/.env ps` that exactly one container exists, named
   `ludo-server-staging`, under the `ludo-staging` project.

Production has never been deployed, so it needs no migration -- only the
fresh-install steps above, followed by a first
`LUDO_ENVIRONMENT=production` deploy.

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

## The live-room guard

Rooms live only in the running server's memory. Before touching anything
else, `deploy.sh` reads `rooms` off the target environment's own `/health`
and refuses to go on if that count is above zero, so a deploy cannot
silently end a game in progress. This runs before the checkout is fetched
and before any image is built, so a refusal here leaves the running
container completely untouched.

- `LUDO_DEPLOY_FORCE=1` deploys anyway, whatever the count.
- `LUDO_DEPLOY_WAIT_SECONDS=<n>` polls until the count reaches zero or `<n>`
  seconds have passed, instead of refusing outright.
- `LUDO_DEPLOY_POLL_SECONDS=<n>` sets the interval between polls while
  waiting (default `30`).

A container that cannot be reached, or that answers without a `rooms`
field (too old, or simply down), is treated as having nothing worth
protecting and the deploy proceeds. A room's longest possible life is 60
minutes, so a wait long enough to cover that is always enough to see it
through on its own:

```
LUDO_DEPLOY_WAIT_SECONDS=4200 bash repo/deploy/ludo/deploy.sh main
```

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
  --project-name ludo-staging --project-directory /srv/apps/ludo/staging \
  -f repo/deploy/ludo/docker-compose.yml --env-file staging/.env \
  up -d --remove-orphans
```

Use `LUDO_ENVIRONMENT=production LUDO_PORT=8099` and the `production`
equivalents of the `--project-name`, `--project-directory`, and
`--env-file` values above if this is a production box. `LUDO_ENVIRONMENT`
and `LUDO_PORT` are required on every `docker compose` invocation against
this file now, hand-run ones included; without them compose refuses to
start rather than publishing on whatever port the file happened to default
to.

`--project-name ludo-<environment> --project-directory
/srv/apps/ludo/<environment>` matter here, not just for `deploy.sh`:
without them `docker compose` derives both from the directory the `-f`
file sits in (`repo/deploy/ludo/`), which resolves the compose file's
`env_file: .env` entry to a `.env` that does not exist there, and using
the wrong environment's project name or directory here brings up or
recreates the other environment's container instead of this one's.

Then update `/srv/apps/ludo/staging/.current_image_tag` (or
`production/.current_image_tag`) to match, so the next `deploy.sh` run
rolls back to the right place if it needs to.

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
  docker compose --project-name ludo-staging \
    --project-directory /srv/apps/ludo/staging \
    -f repo/deploy/ludo/docker-compose.yml --env-file staging/.env ps
  LUDO_ENVIRONMENT=staging LUDO_PORT=8199 \
  docker compose --project-name ludo-staging \
    --project-directory /srv/apps/ludo/staging \
    -f repo/deploy/ludo/docker-compose.yml --env-file staging/.env \
    logs --tail 100 ludo-server
  ```
  and read what the process actually said on its way down. (Use
  `LUDO_ENVIRONMENT=production LUDO_PORT=8099` and the `production`
  equivalents of `--project-name`, `--project-directory`, and
  `--env-file` on a production box. All of these are required for any
  hand-run `docker compose` command against this file now, `ps` and `logs`
  included -- compose parses the whole file, so even a read-only command
  needs `container_name` and `ports:` to resolve, and the wrong
  `--project-name` or `--project-directory` points the command at the
  other environment's project instead of this one's.)
- The loopback command connects but returns something other than `200`
  (a `502`, a connection reset mid-response, anything else): something is
  listening on `127.0.0.1:8199` but it is not this container answering
  normally -- check `docker compose ps` for a crash-looping container before
  assuming anything about the proxy.

## What we found, for the next order

- Resolved (order 199): `TRUSTED_PROXIES` is read by `bin/server.dart` and
  holds the addresses of proxies allowed to set `X-Forwarded-For` for the
  per-client rate limiting in `docs/PROTOCOL.md` section 7. What address the
  Dart process actually sees as the immediate TCP peer is now measured, not
  guessed: read from `/proc/net/tcp` inside each running container while a
  WebSocket was held open through the public hostname, it is the Docker
  network gateway in every case -- `172.18.0.1` on `ludo-staging_default`
  (subnet `172.18.0.0/16`), `172.20.0.1` on `ludo-production_default`
  (subnet `172.20.0.0/16`). Separately, five `create_room` from one public
  address followed by a sixth from a different address, with
  `TRUSTED_PROXIES` empty, made the sixth answer `RATE_LIMITED`: with
  nothing trusted, every client fell into the one bucket the gateway address
  owns. With the gateway trusted, five creates each carrying a different
  forged `X-Forwarded-For` from one address were followed by a refused
  sixth -- the shipped reverse proxy replaces a client-supplied
  `X-Forwarded-For` rather than appending to it, so a trusted gateway cannot
  be tricked into believing a forged header from the client past it.

  `TRUSTED_PROXIES` is set to `172.18.0.1` in
  `/srv/apps/ludo/staging/.env` and `172.20.0.1` in
  `/srv/apps/ludo/production/.env`. Both were measured scoping per client
  correctly afterwards.

  To re-measure by hand: `docker network inspect ludo-staging_default
  --format '{{(index .IPAM.Config 0).Gateway}}'` (swap in
  `ludo-production_default` for production) reads the gateway from the
  Docker side; `cat /proc/net/tcp` run with `docker exec` inside the
  container while a client connection is held open and cross-referenced
  against the container's own `hostname -i` confirms it from the inside.
  The two should always agree, because the container's only route off its
  own network is through that gateway.

  This can drift: the gateway above is whatever subnet Docker assigned the
  compose network when it was created, not a fixed address, and a
  `docker compose down` followed by `up` (a full reset of the network, not
  a normal deploy) can bring the network back on a different subnet.
  `deploy.sh` now checks this on every deploy and reports it in its summary
  line as `trusted_proxy=ok`, `trusted_proxy=MISSING`, or
  `trusted_proxy=UNKNOWN` (the last when the container is not on exactly
  one network, or that network reports no gateway -- check by hand in that
  case). A `MISSING` result means the current gateway is not in
  `TRUSTED_PROXIES`, and the deploy's log will have named both values right
  above the summary line; the fix is to edit the environment's `.env` on
  the box, set `TRUSTED_PROXIES` to the gateway the log line just reported,
  and deploy again (`deploy.sh` never edits `.env` itself and does not roll
  back for this -- the previous image was running under the same `.env`,
  so a rollback would not have helped either).

- Resolved: `docker-compose.yml`'s `ports:` and `container_name` used to be
  the literals `127.0.0.1:8199:8080` and `ludo-server`, so a
  `LUDO_ENVIRONMENT=production` deploy built a production image, published
  it on staging's port, and would have collided with a running staging
  container on the container name besides. Both now read `LUDO_PORT` and
  `LUDO_ENVIRONMENT` from the same `docker compose` invocation `deploy.sh`
  drives -- `LUDO_PORT` is set from the exact `HEALTH_PORT` variable
  `deploy.sh` polls with, not recomputed separately, so the published port
  and the polled port cannot read different values by construction.

- Resolved (order 040): `ROOT` in `deploy.sh` is still the hard-coded
  literal `/srv/apps/ludo`, and stays that way -- the checkout under
  `repo/` is genuinely shared and duplicating it bought nothing. What
  changed is that `.env`, `.current_image_tag`, and the compose project
  name no longer come from `ROOT` directly. `ENV_ROOT="$ROOT/$ENVIRONMENT_NAME"`
  is computed after `ENVIRONMENT_NAME` is validated, and `.env` and
  `.current_image_tag` live under it, one copy per environment, so a
  production deploy and a staging deploy no longer write or read the same
  state file. `PROJECT_NAME` is `ludo-$ENVIRONMENT_NAME` rather than
  `basename($ROOT)`, so the two environments are two separate compose
  projects and a production deploy cannot recreate or adopt staging's
  container. The prefix-strip in `roll_back_and_fail`
  (`${PREVIOUS_TAG#"$IMAGE_NAME:$ENVIRONMENT_NAME-"}`) no longer has an
  "other environment's tag" to silently fail to strip, because
  `STATE_FILE` is now a different file per environment -- a tag written by
  the other environment is not reachable from this one at all, not even
  by mistake.

  The box still has the pre-040 shared files at `/srv/apps/ludo/.env` and
  `/srv/apps/ludo/.current_image_tag`, and a staging container running
  under the old `ludo` compose project. See "The first deploy after the
  environment split" above for the one-time move and cleanup this
  requires; `deploy.sh` deliberately does not do that move itself.

## Verification records

Every finished game's proof (docs/VERIFY.md) lives at `/data/verify` inside
the container, on a named volume declared in `docker-compose.yml`: one
volume per environment, since compose prefixes an unqualified volume name
with the project name -- `ludo-staging_verify-data` and
`ludo-production_verify-data`, never shared, the same as the two compose
projects themselves. The image creates `/data/verify` owned by
`10001:10001` before the volume is ever mounted, so a fresh volume inherits
that ownership.

Retention is 90 days and the server purges its own records on every room
reap (`RoomRegistry.reap()` calling `verifyStore.purgeOlderThan`); nothing
else deletes them, and nothing else needs to -- there is no cron job or
external purge for this to keep in sync with the code.

`provefair.app` and `www.provefair.app` are proxied by the host's reverse
proxy to `127.0.0.1:8080`, and only the **production** container publishes
that port, from `docker-compose.production.yml`, an override `deploy.sh`
loads only for a production deploy. Staging never loads it and never
publishes 8080 -- publishing it from staging would mean provefair.app could
answer out of the wrong environment's records depending on which container
happened to hold the port.

To list what a volume holds, from the `deploy` account:

```
docker run --rm -v ludo-production_verify-data:/d debian:trixie-slim ls /d
```

(`ludo-staging_verify-data` for staging). Removing the volume
(`docker volume rm`, or a `docker compose down -v`) deletes every player's
proof permanently -- there is no other copy anywhere. `docker compose down`
without `-v` leaves the volume alone; a normal deploy never runs `down` at
all, only `up -d`, so a redeploy is not a risk to these records by itself.

What tells you it broke: a finished game's `verify_url` not answering `200`
from outside (`curl -sS https://provefair.app/v/<game_id>`, or
`https://stg.ludo.provefair.app/v/<game_id>` on staging). `deploy.sh`
already checks the production side of this on every production deploy --
it polls `127.0.0.1:8080/health` after the ordinary health check and rolls
back if that does not answer `200`, so a production container that came up
without the second port never gets called a successful deploy. That check
cannot see past the container's own loopback port, though: if it passes but
`provefair.app/v/<id>` still fails from outside, the break is DNS, TLS, or
the reverse proxy, the same as any other hostname-level failure described
above, not this volume or this container.

## Out of scope here

TLS, the reverse proxy configuration, and the Android release build are
not this deploy's concern. Hostnames (`stg.ludo.provefair.app`,
`ludo.provefair.app`) are root policy on the box and are not changed here;
nothing in this order needed a hostname change.

Actually bringing up production -- the one-time `.env` and
`.current_image_tag` migration and container cleanup described above, and
the first `LUDO_ENVIRONMENT=production` deploy itself -- is the master's,
from the box.
