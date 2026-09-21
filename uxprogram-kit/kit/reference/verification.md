# Verification reference

## 1. Capability probe (setup; results in facts.md)

Try each item and record YES or NO with its evidence log:

- Shell commands run: `evidence.py probe-shell -- git --version`.
- Python and its command name (`python` or `python3`); Node and npm when the project or the probe needs them.
- The git identity is a human identity: `git config user.name` and `git config user.email`.
- The app builds and starts.
- Web and hybrid: a headless browser starts (`npx playwright --version`, then one probe run).
- Mobile: devices or emulators (`adb devices`, `flutter devices`, `xcrun simctl list devices`).
- Web access: fetch one known page. This decides whether research can be VERIFIED.
- Image viewing: open one screenshot and state one fact the probe can confirm, such as a header's background color or a button's position. If your statement does not match the probe, record NO.
- A subagent tool, only when `DISPATCH: subagent`.

## 2. Freshness: test the build you just made

Before any screenshot, probe or test run:

1. Rebuild, then restart the dev server or the app.
2. Remove caches that can serve an old UI: service workers (the probe blocks them by default), HTTP caches, CDN or proxy caches. In hybrid apps the WebView cache survives installing a new build, so clear it. On mobile, reinstall or clear app data when assets changed.
3. Prove it: a build identifier the check can see matches the build log. On web, pass it to the probe with `--expect <bundle hash or build id>`. On native, read the version name and code, or a build stamp on a debug screen.

Log the proof. A test run without it is invalid.

## 3. Evidence rules

- Only `evidence.py` writes to `.uxprogram/logs/`. Never edit a log; the tools detect edits.
- A screenshot is evidence only next to the instrument log that measured the same screen.
- Visual claims made without viewing images must come from instrument numbers.
- A PASS needs evidence exactly like a FAIL does.

## 4. Instruments by platform

| Need | Web and Odoo | Hybrid (web in a native shell) | Flutter | Android native | iOS native | Game engines |
|---|---|---|---|---|---|---|
| geometry, covered controls, overflow | `ux_probe.mjs` | probe on the web bundle at device sizes, plus a device check for safe areas | widget tests with `tester.getRect` and overlap assertions | `uiautomator dump` bounds, Compose semantics tests | XCUITest element frames | engine UI tests and screenshots per state |
| accessibility | probe `--axe`, keyboard path script, Playwright `ariaSnapshot` | the same, plus the platform scanner on a device | `meetsGuideline` with `androidTapTargetGuideline`, `iOSTapTargetGuideline`, `labeledTapTargetGuideline`, `textContrastGuideline` | Espresso `AccessibilityChecks.enable()`, Accessibility Scanner | `performAccessibilityAudit()` (Xcode 15 or later) | checklist plus human_checklist items |
| flows (drive the promise) | Playwright end-to-end | Playwright against the bundle, device smoke run | `integration_test` | Espresso or Compose UI tests | XCUITest | scripted input playback |
| visual regression | Playwright screenshots with a pixel diff | the same | golden files | Paparazzi or Roborazzi | snapshot tests | screenshot diff per state |
| style inventory | probe `--inventory` | the same | theme usage scan | theme and resource scan | style and asset scan | style guide scan |
| performance | Lighthouse (mobile, median of 3), web vitals | the same, plus device frame timing | profile-mode frame times | Macrobenchmark startup and frame timing | Instruments hitches | frame time at the target rate |

Odoo: JS unit tests (QUnit or Hoot, depending on the version) and tours for flows; run the probe against the running instance with a test user's session through `--storage-state`.

Drive the promise: every behavioral criterion gets a script that does what the user does and checks the real outcome. Undo, for example: act, undo, assert the server has no change; act, wait out the undo window, assert exactly one change.

Look at the result, not the source. Dump computed styles for all nodes a style change should affect (`--dump-styles <selector>`), and measure geometry after every layout change. A screenshot at the top of a page cannot tell "covered by a fixed bar" from "below the fold"; the probe's obscured check scrolls every container and tries start, center and end alignments.

Useful probe runs:

```
node .uxprogram/kit/tools/ux_probe.mjs --url http://localhost:5173/ --out .uxprogram/shots/A-c1/test/home --viewports 320x640,390x844,768x1024,1440x900 --color-scheme both --axe --inventory --expect index-3f2c1ab.js
node .uxprogram/kit/tools/ux_probe.mjs --url http://localhost:5173/match --out .uxprogram/shots/A-c1/test/match-rtl --locale ar-AE --reduced-motion --storage-state .uxprogram/auth.json
```

## 5. Thresholds

- Contrast: text 4.5:1, large text 3:1, UI components and focus indicators 3:1.
- Targets: at least 24x24 CSS px on pointer screens (WCAG 2.5.8, including its spacing exception). On touch: 44x44 CSS px on web, 44x44 pt on iOS, 48x48 dp on Android.
- Reflow at 320 CSS px wide without sideways scrolling; zoom to 200% without losing content or function.
- Focus always visible, no keyboard traps, logical focus order.
- No more than three flashes per second.
- Response: visible feedback within 100 ms, progress for anything longer than 1 s.
- Web vitals (mobile profile, median of 3 runs): LCP 2.5 s or less, INP 200 ms or less, CLS 0.1 or less.
- Motion: 150 to 300 ms for small changes, up to 500 ms for large transitions, reduced motion honored.

## 6. Test matrix

Every condition is covered every cycle. The method depends on what the condition costs to test.

T1, automated sweep, on every changed screen and every core screen:
- sizes: web 320, 390, 768, 1024, 1440 and 1920 wide; mobile: small phone, large phone, tablet, landscape
- themes: light, dark, and forced colors or high contrast where supported
- direction: LTR, plus RTL when a right-to-left language is configured
- motion: normal and reduced
Run with the probe or the platform instruments and save shots under `shots/<X>-c<n>/test/`.

T2, pairwise, on core goal flows:
- network: fast, slow, offline, request failure, timeout
- data: empty, one item, typical, huge (1000 or more items), very long strings, emoji and special characters, RTL text inside an LTR UI and the reverse
- user: first-time, returning, power user, someone making input mistakes
- input: mouse, touch, keyboard only, zoom 200%
- interruption: refresh or background mid-flow, back button, close and return, double submit, rapid repeated taps
- state: loading, empty, error, partial, success, disabled, permission denied, session expired
Generate the combinations with PICT or allpairspy through `evidence.py`; that log is the report's `PAIRWISE_GENERATOR`. Then run each combination on the flows it applies to.

T3, targeted: the risks each task card names, in depth. For a form task, for example: every validation path, paste, autofill, IME and Arabic input, and mobile keyboard types.

T4, regression: the whole existing test suite, every permanent check, and screenshot comparison of unchanged core screens against the previous cycle. An unexplained difference is a note.

Human only: real screen readers end to end (NVDA, VoiceOver, TalkBack), real iOS Safari, the feel on a real low-end device, haptics, sound mix. Add each to `human_checklist.md` with exact steps and mark it HUMAN in the report. Never PASS.

## 7. Scans and their allowlists

- `authorship_scan.py` flags model and tool names, AI phrases, style tells such as "note that" and "this ensures", em dashes, emoji in commit messages, `Co-Authored-By` and `Generated with` trailers, and bot or tool identities.
- `negative_space.py` flags deleted test files, net removed assertions, skip or only markers, lint and type suppressions, empty catch blocks, TODO and placeholder text.
- When a match is a legitimate part of the product (a zodiac sign called Gemini, a character called Claude in the game's story), add the exact text to the allowlist file as `exact text | reason`. The reviewer checks every entry. Never allowlist something to make a gate pass.
