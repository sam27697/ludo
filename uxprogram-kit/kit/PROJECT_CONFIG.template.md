PROJECT_NAME:
PROJECT_TYPE:
PLATFORMS:
AUDIENCE:
LANGUAGES:
COPY_VOICE:
CORE_GOALS:
FROZEN:
BRAND_LOCKS:
APP_URL:
RUN_NOTES:
TEST_ACCOUNTS:
DISPATCH: runner
PARALLEL: no
PUSH: no
MAX_ROUNDS: 5

## How to fill this file

Fill what you know. Leave a value blank and the program detects it at setup, writes what it found to `facts.md`, and marks it `DETECTED`. It never stops to ask.

- PROJECT_TYPE: game, entertainment, social, content, commerce, productivity, business, other. Decides how Track D reads "engagement".
- PLATFORMS: web, hybrid (web inside a native shell), android, ios, flutter, desktop, unity, godot, odoo. More than one is fine.
- AUDIENCE: adults, teens, children-under-13, families, internal-staff. Children or families turn on the stricter rules in `kit/tracks/D_engagement.md`.
- LANGUAGES: for example `en, ar`. Any right-to-left language turns on RTL checks.
- COPY_VOICE: how the product speaks, for example `plain friendly English; Arabic in Modern Standard Arabic`.
- CORE_GOALS: the 3 to 8 things users come to do, separated by `;`. Example: `start a match with friends; resume a match; change avatar`.
- FROZEN: anything beyond the always-frozen list (business logic, API contracts, data models, database schema, auth, permissions) that must not change. Paths or plain words.
- BRAND_LOCKS: what the redesign must keep. Blank means the logo and the product name only.
- APP_URL: for web or hybrid, the local address once the app runs.
- RUN_NOTES: anything needed to start the app that the code does not show (a database to start first, a seed command).
- TEST_ACCOUNTS: where seeded test logins live. Never real user accounts.
- DISPATCH: `runner` when run_program.py starts every role in a fresh process (recommended). `subagent` when you run the agent by hand and it has a subagent tool.
- PARALLEL: `yes` lets independent implementation tasks run in separate git worktrees.
- PUSH: `yes` lets the program push its own branches to the remote. It never touches the default branch either way.
- MAX_ROUNDS: 3 scheduled rounds plus extra rounds while tracks still have high-value work, up to this number.
