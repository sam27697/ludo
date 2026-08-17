# Stack

Decided 2026-08-18, run 1, from the research in work order 001. Sam delegated
this decision rather than asking for a menu, so this file is the decision, the
alternatives rejected, the measured reason for each rejection, and the one fact
that would reverse it.

## The decision

**Dart, on both sides, with the rules engine written once.**

| Part | Choice |
|---|---|
| Client | Flutter, board drawn with `CustomPainter` on `Canvas` |
| Server | Dart, `shelf` plus `shelf_web_socket` |
| Rules engine | a plain Dart package, no I/O, no framework, consumed by both |
| Repository shape | a pub workspace: one lockfile for engine, client and server |
| Transport | WebSocket over TLS, JSON, per `docs/PROTOCOL.md` |
| Room framework | none. We write the rooms. |
| Android | `targetSdk` 36, `minSdk` 24, App Bundle, Play App Signing |

Layout:

    packages/ludo_engine/    pure rules, the thing that must never diverge
    apps/server/             authoritative server
    apps/client/             Flutter app
    pubspec.yaml             workspace root

## Why

The whole project rests on one component: a deterministic rules engine that the
server uses to decide legality and the client uses to grey out illegal moves
before the round trip. If two copies of that engine ever disagree by one square,
the result is a desync in front of testers, and desyncs are the most expensive
class of bug in this build. So the decision was weighted, above everything else,
on which stack makes one engine serve both sides with the least ceremony and the
least chance of skew.

1. **Dart is the only candidate with a primary-source production precedent for
   exactly this architecture.** Google's I/O FLIP was a Flutter client with a
   Dart backend, sharing the game logic, keeping outcome computation server-side
   specifically to stop clients sending fabricated results. That is this project,
   described by the vendor.
2. **Pub workspaces structurally prevent engine skew.** One `pubspec.lock` at
   the workspace root resolves the engine identically for client and server. The
   failure mode being designed out is not a bug in the engine, it is two builds
   pinning different versions of it, and this closes that by construction.
3. **One toolchain on both sides.** Client and server compile the same Dart
   source with the same SDK. There is no second runtime executing the "same"
   engine with different semantics.
4. **Every source file is text.** Nothing introduces a binary scene or asset
   format that a GUI editor owns, so parallel workers can hold different files
   in one round without a merge that cannot be reviewed. This is a working-method
   requirement, not a taste.
5. **Memory.** On the one comparable measurement found, Dart AOT executables sit
   around 8.7 to 20.5 MB against Node's 60 to 144 MB. On the smallest VPS that
   is real headroom. Flagged honestly: those are generic CPU microbenchmarks,
   not a WebSocket workload, and no primary-source idle-RSS figure for a Dart
   WebSocket server was found.
6. **RTL and Arabic.** Flutter's `Directionality` is framework-level. The one
   candidate with a documented open Arabic backlog is rejected below.
7. **Licence cost zero, no revenue share, no seat.**

## Rejected, with the measured reason

**TypeScript, React Native client plus Node server.** Rejected on two findings,
either of which is sufficient.
- React Native ships Hermes; a Node server runs V8. The shared engine would be
  executed by two different JavaScript engines with different optimisation
  strategies. The engine's entire value is that it is byte-identical on both
  sides, and this option is the only one of the three that runs it on two
  runtimes. That is the exact risk the shared engine exists to eliminate.
- React Native's own issue tracker carries multiple currently-open Arabic and
  RTL defects: `I18nManager.isRTL` incorrect (51647), Arabic text clipping
  (55220), `forceRTL` requiring a full reload (16215), `forceRTL(false)` failing
  under Arabic and Urdu device locales (39414). Half this app's testers will
  read Arabic. Also against it: Metro's symlink and hoisting handling is the
  documented breaking point for workspace monorepos in CI.

**Kotlin, Compose client plus Ktor server, shared KMP module.** The closest
call, and it wins on client quality outright: Compose is native, its `Canvas` is
native Skia, and there is no runtime tax at all. Rejected on:
- No verifiable production precedent of a KMP game sharing a rules module with a
  Ktor server. JetBrains' own case-study page yields one client-and-server
  sharing example and it is a yoga app. For the single most load-bearing
  decision in the project, "nobody has published doing this" is a real cost.
- The shared module's release path is asymmetric: R8 and ProGuard act on the
  Android release build and not on the server, and `kotlinx.serialization` has
  an open R8 warning issue from v1.9.0. So the two consumers of the shared
  module do not go through the same final build step, which is precisely the
  seam where divergence hides.
- JVM baseline memory is the heaviest of the three on one small VPS. Not
  measured against a primary source, and weighted accordingly, which is to say
  lightly.

**Godot 4.** Scored better than expected and deserves its reasons written out
rather than a dismissal. In its favour, measured: MIT, zero cost; `.tscn` and
`.tres` are UTF-8 text by design, not binary; `_draw()` is a real immediate-mode
2D API and Godot is 2D-native; its `TextServerAdvanced` is ICU and HarfBuzz
backed with genuine Arabic positional shaping and a bidi override; and it has a
first-party dedicated-server export that runs the identical GDScript headless,
which is a direct answer to the shared-engine requirement. Rejected on four
measured points:
- The scene structure is authored through the GUI editor even though the file
  is text. Two workers adding or reordering nodes in one `.tscn` produce a
  conflict in GUIDs and a node tree, which is exactly the merge the working
  method has to avoid, and being textual does not make it hand-resolvable.
- The test runner, GUT, is community-maintained and not first-party. The golden
  corpus is the load-bearing part of the harness and it should not sit on a
  third-party addon.
- Every CI invocation restarts the whole engine, reported as slower per test.
  A 500-game replay corpus is the thing that runs on every single order.
- Its default and maximum `targetSdk` could not be verified from the official
  export documentation, and 2026 forum threads show users manually raising it to
  36. Thirteen days from the deadline, that is the wrong kind of unknown.
- The authoritative server would be a full Godot binary on the smallest VPS,
  against a Dart AOT executable measured in the tens of megabytes.

**Unity.** Rejected on three independent grounds, any one sufficient. It has no
native RTL or bidirectional support at all: Arabic requires a third-party
TextMeshPro extension, which the criteria disqualify by their own wording, and
half the testers read Arabic. Its `.unity` and `.prefab` files are GUI-authored,
GUID-laden and merge badly, and can be forced to actual binary. And Unity
Personal is free only below a $200,000 trailing-twelve-month threshold, with
Pro at roughly $2,310 per seat per year above it, which is not "no revenue
share, no seat cost". It is also the only candidate with no documented one-line
headless AAB command; the build must be hand-rolled as a custom Editor script.

## Rejected: every off-the-shelf room framework

The question was whether one earns its dependency for private friend rooms, no
matchmaking, no persistence beyond a live room, one small VPS. None does.

- **Colyseus.** Would force game state into its `Schema` model, which is not the
  engine's own state shape, and it has no first-party Dart or Kotlin client. We
  would write and maintain an unofficial client against its binary protocol.
- **Nakama.** Requires CockroachDB or a Postgres-compatible database alongside
  it. That is a second service to run and back up for a game that persists
  nothing beyond a live room. Authoritative logic must live in its Go, Lua or
  JavaScript runtime, none of which is Dart, so the engine would be ported.
- **Socket.IO rooms.** Not a room framework. Its own documentation describes
  rooms as a broadcast-grouping primitive. It solves none of the hard parts:
  seat ownership, reconnect-to-the-same-seat, the turn timer, server-owned
  dice. Those are all still ours to write, and a `Map<code, Set<Connection>>`
  gives the grouping for nothing.
- **Firebase Realtime Database and Firestore.** Three independent
  disqualifications. It cannot be self-hosted, so it fails the one-VPS
  requirement outright. It is a data store, not compute, so it cannot be
  authoritative and cannot own a CSPRNG dice roll or a turn timer without
  Cloud Functions, which is a second cloud environment. And it makes Google a
  third-party data processor, which collides directly with this app declaring
  zero data collection on the Data safety form and carrying no third-party SDK.

The rooms are ours. They are a few hundred lines against a written protocol,
and every one of them is testable.

## Server library: shelf, not dart_frog

`dart_frog` is the more convenient framework and it was not chosen. It moved out
of Very Good Ventures into an independent community organisation around July
2025. It is not abandoned, but this project needs a dependency it can reason
about for years, and we are writing the room logic ourselves regardless, so its
routing convenience buys little. `shelf` is published by the Dart team, is
deliberately finished rather than stale, and `shelf_web_socket` 3.0.0 comes from
the verified `tools.dart.dev` publisher. Fewer moving parts under the one thing
that must not move.

## What would reverse this

The reversal condition was **whether Flutter can produce a signed release App
Bundle at `targetSdk` 36 from a headless container today.** It landed after the
decision was drafted and it did not reverse it:

- `flutter build appbundle` is a single documented command producing
  `build/app/outputs/bundle/release/app.aab`. Signing is configured once through
  `key.properties` and a Gradle `signingConfigs` block, and every build after
  that is unattended. No GUI editor is in the loop at any point.
- Flutter stable is 3.47.0, released 2026-08-12, and it bundles **Dart 3.13.0**,
  which is the same Dart stable the server side resolves. Client and server run
  one SDK version, which is the point.
- One thing is **not** fully closed and run 2 must close it: the researcher
  could not read Flutter's Gradle template directly to confirm the literal
  default `targetSdkVersion`, and corroborated 36 only from secondary sources.
  This is a weak risk rather than a reversal risk, because `targetSdk` is an
  explicit line in `build.gradle.kts` and setting it is routine. **The first
  client order sets it explicitly and does not rely on the toolchain default,
  and the artifact gate asserts the value in the built bundle.** An assumed
  default is exactly the kind of thing that is discovered at upload time.

Secondary, weaker reversal condition: if the four-client simulator shows the
Dart server cannot hold the room count on the chosen VPS. That would move the
server and leave the client and the engine alone, because the engine is a plain
package and the protocol is JSON over WebSocket. The blast radius of being wrong
about the server is one component. That is deliberate.

Honest note on what is thin: no primary-source idle-memory figure for a Dart
WebSocket server was found, and the Dart-versus-Node memory comparison rests on
generic CPU microbenchmarks rather than a WebSocket workload. The decision does
not rest on that number, and it is recorded so nobody later mistakes it for a
measurement of this application.

## Play constraints this stack must satisfy

Confirmed from the primary sources, work order 001 question (d):

- `targetSdk` 36 for new apps from **31 August 2026**. Extension possible to
  1 November 2026, requested from the Policy Status page.
- App Bundle mandatory for new apps, and Play App Signing is required in order
  to use it. Correction to the project's standing assumption: with Play App
  Signing enrolled, losing the **upload** keystore is recoverable through an
  upload key reset in the Play Console. It is the **app signing** key that can
  never be lost, and Google holds it. The upload keystore is still protected
  like a secret; it is simply not the end of the app.
- `assetlinks.json` must carry the SHA-256 of the **app signing key**, taken
  from the Play Console App integrity page, not the fingerprint `keytool`
  prints locally from the upload keystore. Using the local one is the standard
  silent failure: links just open in the browser. The Play Console generates the
  correct snippet.
- It must be served from `https://<domain>/.well-known/assetlinks.json` as
  `application/json`, over HTTPS, with no redirects.
- A privacy policy URL is mandatory even declaring zero collection. It must name
  the developer and the app, state retention and deletion, be labelled as a
  privacy policy, live at a public non-geofenced URL, and not be a PDF.
- Closed testing: 12 testers opted in **continuously** for 14 days, counted on
  opt-in status. An opt-out breaks the streak and it restarts. Production access
  review then takes about seven days.
