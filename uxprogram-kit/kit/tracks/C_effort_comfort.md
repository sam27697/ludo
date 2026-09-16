# Track C: effort and comfort

Question: is every core goal done in the fewest steps and decisions possible, without strain, and without ever losing the user's work?

## Measuring effort

Describe every core goal in `.uxprogram/flows.md` and run `effort_calc.py`:

- `T` tap or click, `G` gesture (swipe, scroll, drag), `K*n` keystrokes, `M` a decision, `H` hand move between keyboard and pointer, `W:x` waiting x seconds for the system, `N` a new screen.
- Write each string by walking the real app, not by reading code. Count `M` whenever the user must choose, read to decide, or search.
- Also record: scroll distance to reach primary actions, input mistakes the flow allows, and measured seconds for the slowest steps.

Example:

```
FLOW: start-match | start a match with two friends from app launch
STEPS: N T M T N T K*6 T W:1.5 N
```

## Techniques to consider

- Smart defaults, remembering last choices, prefilling what is already known.
- Inline editing instead of separate edit screens; bulk actions; keyboard shortcuts and a command palette for power users.
- Autocomplete and suggestions; forgiving input formats.
- Collapse wizard steps that are not truly needed; progressive disclosure for rare options.
- Primary actions within thumb reach on mobile; every gesture paired with a visible alternative.
- Optimistic UI where the action is safe to reverse, with honest rollback on failure.
- Never lose input: persist drafts, resume where the user left off, survive refresh, back, app switching and a locked screen.
- Undo instead of confirmation for reversible actions.
- Deep links straight into a goal; quick actions from the launcher or notifications where the platform supports them.

## Comfort

- Nothing jumps: layout shift near zero, stable positions for repeated actions.
- Readable at arm's length, no precision tapping, comfortable density.
- Dark mode and eye comfort for long sessions; never more than three flashes per second.
- Always clear: where am I, what can I do, what happens next.
- Feels instant: skeletons for loading content, visible feedback under 100 ms, progress for anything over 1 s.
- Interruption-safe: phone locked, call received, tab closed, network lost, and nothing is lost.

## Required in cycle 1

- `flows.md` covering every core goal, verified by walking the app.
- An interruption test for each core goal: refresh or background mid-flow, back, network loss.

## Metrics owned

| Metric | How |
|---|---|
| taps, gestures, keystrokes, decisions, screens and effort seconds per core goal | effort_calc.py |
| input lost after an interruption | scripted interruption tests |
| layout shift on core screens | web CLS; native: movement of primary actions between states |
| time to visible feedback | trace or screen-capture timing |

Target: every core goal improves on at least one effort metric against the baseline, or `13_close.md` shows with evidence why it is already optimal.

## Out-of-the-box prompts for Step 5

- What if this goal took one tap from launch?
- What can happen automatically so the user only enjoys the result?
- What would the product do if it knew the user had only 30 seconds right now?
- What would a speedrunner find annoying?
- Which question does the product ask that it could answer itself?
