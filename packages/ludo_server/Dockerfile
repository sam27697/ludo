# syntax=docker/dockerfile:1.7
#
# Build context is the repository root, not this directory -- the pub
# workspace root has to be present for `dart pub get` to resolve
# packages/ludo_server at all, because ludo_engine is a workspace sibling
# resolved by path from the root pubspec.yaml. Build with:
#
#   docker build -f packages/ludo_server/Dockerfile -t <tag> .
#
# from the repository root. deploy/ludo/deploy.sh does exactly this.

# ---- build stage ----------------------------------------------------------
# Full Dart SDK. Pinned by tag and digest to the exact toolchain this repo is
# developed and tested against (Dart 3.13.1, environment: sdk: ^3.5.0 in
# pubspec.yaml). The digest pin means this stays byte-identical even if the
# tag were ever repointed upstream; the tag is kept alongside it so a human
# reading this file does not have to resolve a hash to know what it is.
FROM dart:3.13.1-sdk@sha256:d3f19cf5c18a7939d6af3f0896b2e9fec3f31f7ba3a2f88bfe6181e903084a51 AS build

WORKDIR /workspace

# Manifests first, and the whole workspace's manifests before any source, so
# `pub get` resolves once and the layer caches on manifest changes only.
COPY pubspec.yaml pubspec.lock ./
COPY packages/ludo_engine/pubspec.yaml packages/ludo_engine/pubspec.yaml
COPY packages/ludo_server/pubspec.yaml packages/ludo_server/pubspec.yaml

# --enforce-lockfile: the committed pubspec.lock is the single resolution
# for the whole workspace and the build fails rather than silently resolving
# something else if it and the manifests have drifted apart.
RUN dart pub get --enforce-lockfile

COPY packages/ludo_engine packages/ludo_engine
COPY packages/ludo_server packages/ludo_server

# Re-run against the now-complete source tree, --offline because nothing
# about the dependency set changed and this is not allowed to reach the
# network a second time; --enforce-lockfile again for the same reason as
# above.
RUN dart pub get --enforce-lockfile --offline

RUN dart compile exe packages/ludo_server/bin/server.dart -o /server

# ---- runtime stage ---------------------------------------------------------
# dart compile exe links against glibc; it is not a static binary, so a bare
# `scratch` stage will not start it without also carrying glibc and a
# handful of other shared objects into the image by hand. The Dart team
# documents doing exactly that: copying a `/runtime/` directory the SDK
# image ships out of the build stage onto `scratch`
# (https://github.com/dart-lang/dart-docker), and that does produce a
# runnable image around 10 MB -- but that image has no shell and no HTTP
# client, and this Dockerfile has to carry a HEALTHCHECK that makes a real
# HTTP request against the running process. Scratch cannot do that.
# debian:trixie-slim is the same distribution the SDK image's /runtime/
# files are extracted from, stays small, and gives HEALTHCHECK a shell and
# curl to work with. Also pinned by tag and digest.
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS runtime

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /server /server

# Rootless Docker on the deploy host already maps this container's root to
# an unprivileged host uid, so this is defence in depth rather than the only
# defence. A fixed, unused numeric uid:gid; no /etc/passwd entry is needed
# for the process to run as it, and none is created.
USER 10001:10001

ENV PORT=8080
EXPOSE 8080

# packages/ludo_server has no dedicated health endpoint as of this order --
# see deploy/ludo/README.md for the finding. Every HTTP request that is not
# a WebSocket upgrade gets a fixed 404 Not Found from shelf_web_socket; that
# response is only reachable at all if the process is bound to the port and
# running its request pipeline, so it is used here as the liveness signal
# until a real endpoint exists. This checks the exact status code, not
# merely that curl connected, so a proxy or stub answering on the port with
# something else still fails the check.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/bin/sh", "-c", "code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/) && [ \"$code\" = \"404\" ]"]

ENTRYPOINT ["/server"]
