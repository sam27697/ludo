# Track A: UX structure and flow

Question: can people reach their goals easily, understand what is happening, and recover when something goes wrong?

## Lens for Explore and Understand

- Information architecture: navigation depth to each core goal, labels, grouping, findability, match with users' mental models.
- Flows: every core goal from entry to completion, including branches, back, cancel, and resuming after an interruption.
- Heuristics: score Nielsen's 10 usability heuristics for each core flow, 0 to 4, where 4 means fully satisfied. Every score names its evidence.
- Cognitive load: decisions per screen, jargon, and what users must remember between screens.
- Feedback: every action acknowledged within 100 ms, progress shown for anything over 1 s, a clear result at the end.
- Errors: prevention first (constraints, good defaults, confirmation only for irreversible actions), then recovery messages that say what happened and how to fix it, in plain words.
- First run: time to first value, empty states that teach, progressive disclosure.
- Content: verb-first button labels, consistent terms, copy in the configured voice and languages.
- Forms: field count, smart defaults, inline validation, autofill, correct input types and mobile keyboards, Arabic input and mixed-direction text where relevant.
- Search, filter and sort wherever the product has lists.
- Trust: undo instead of confirm where possible, clear consequences before destructive actions, no surprises.

## Required in cycle 1

- A sitemap and one flow diagram per core goal, in Mermaid, before (in `01_explore.md`) and after (in `13_close.md`).
- The heuristic scorecard as this track's baseline.
- `principles.md` version 1.
- `CORE_GOALS` confirmed in `facts.md` when the project config left it blank.

## Metrics owned

| Metric | How |
|---|---|
| heuristic score per core flow (0 to 40) | scorecard, evidence for every score |
| navigation depth to each core goal | count from launch or home, from `flows.md` |
| dead ends (screens without a clear next action) | inventory walk |
| error recovery coverage: error states with a recovery path / error states found | walk plus forced failures |
| time to first value on first run | effort_calc.py on the first-run flow, plus measured seconds |

## Out-of-the-box prompts for Step 5

- What if this flow had zero screens: done inline, by default, or automatically?
- What if the product anticipated the next action and offered it, or simply did it?
- What would this flow look like as a conversation, as a game, as a physical object?
- What if every destructive action became undoable instead of confirmed?
- What single change would make a first-time user succeed in under 60 seconds?
- What would this flow be for someone holding the phone in one hand on a moving bus?
