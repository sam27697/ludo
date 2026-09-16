# Creativity reference

## 1. Anti-generic rules

Each of these is an automatic S2 note, or S1 on a core screen:

- the untouched default look of a framework or component library
- generic purple or blue gradients; glassmorphism without a purpose
- emoji used as icons in a professional product; mixed icon styles
- lorem ipsum, "Title here", placeholder images or fake numbers left in
- everything centered in equal-weight cards, with no hierarchy
- the same fade applied to everything
- vague copy such as "Welcome to our platform" or "Something went wrong"

## 2. Mandates for every cycle

- Signature element: at least one interaction, visual motif or moment that belongs only to this product. Test: would a regular user of the top three competitors recognize it as theirs? Then it is not a signature.
- Wild spike: at least one Wild concept built as a spike and measured, even if it never ships. Record KEEP, ADAPT or DROP with evidence.
- Deletion: remove at least one element, option, step or screen that does not earn its place, with the metric that shows why.

## 3. Concept scoring

Every concept gets whole-number scores from 1 to 5 and a one-line reason.

Weighted score = 0.30 Impact + 0.20 Principles + 0.15 Distinctiveness + 0.15 Effort + 0.10 Safety + 0.10 Maintainability, rounded to 2 decimals.

| Criterion | 1 | 3 | 5 |
|---|---|---|---|
| Impact | barely noticed | clearly helps one core goal | transforms a core goal for most users |
| Principles | conflicts with a principle | neutral | embodies a principle |
| Distinctiveness | looks like everyone else | a recognizable twist | memorable; people would describe it to a friend |
| Effort (for the user) | adds steps or decisions | same effort | removes steps or decisions from a core goal |
| Safety (for the code) | touches many files or risky areas, hard to roll back | moderate and contained | small, isolated, trivial to roll back |
| Maintainability | new patterns and special cases | fits existing patterns with some new code | uses only existing components and tokens |

`04_plan_scores.md` format:

```
## Scores
| Area | Concept | Tier | Impact | Principles | Distinctiveness | Effort | Safety | Maintainability | Weighted | Reason |
|---|---|---|---|---|---|---|---|---|---|---|
| onboarding | guided tour | Safe | 3 | 3 | 2 | 3 | 5 | 5 | 3.25 | proven pattern, low risk |
| onboarding | learn by playing | Bold | 4 | 5 | 4 | 4 | 3 | 3 | 4.00 | teaches through the core loop |
| onboarding | no onboarding, smart defaults | Wild | 4 | 4 | 4 | 5 | 3 | 3 | 3.95 | zero screens before first fun |
```

`report_gate.py plan-scores` checks the arithmetic, names the winner of each area, and flags every Wild concept within 10% of the winner with `SPIKE REQUIRED`. Every area needs at least one Safe, one Bold and one Wild concept.

## 4. Spikes

- Branch `ux/spike-<X>-c<n>-<slug>` from the cycle branch. Never merged.
- One R3 dispatch. Build the smallest thing that answers the question.
- Decide before building what to measure: effort numbers, probe results, a side-by-side of shots, a scripted flow.
- Record the verdict in `08_implementation_log.md`: KEEP (plan it as a task next cycle), ADAPT (what to change) or DROP (why), each with evidence.

## 5. Ideation techniques

Use at least two per cycle that this track did not use in its previous cycle, and name them in the plan.

- SCAMPER: substitute, combine, adapt, modify, put to other use, eliminate, reverse
- Cross-industry transfer
- Worst possible idea, then invert it
- Constraints: one screen only, no text, one thumb, a 10-second session, no network
- Extreme users: a first-timer, an expert speedrunner, someone with low vision, one hand on a crowded bus, a child with a parent watching
- Eight fast variants of one screen in one pass, then choose
- "How might we" reframing of the top root cause
- Remove the interface: what if nothing were on screen at all?
- Three contrasting lenses: how would a luxury brand, a game studio and a public transport authority solve this?
- Future back: the product five years from now, and the part of it that can be built today

## 6. Boldness gets a fair test, never a free pass

Bold ideas always get a real score and, when close, a spike. Accessibility, the ethics gate, the frozen areas and the ratchet are never traded for boldness.
