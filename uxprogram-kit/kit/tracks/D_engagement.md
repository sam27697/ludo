# Track D: engagement

Question: do people want to come back because the product is genuinely good for them, and would they thank you if they understood exactly how it works?

Read `PROJECT_TYPE` and `AUDIENCE` first. They change what engagement means for this product.

## Build `engagement_model.md` in cycle 1

1. The core loop as a diagram: trigger, action, reward, investment. For games and entertainment, also the moment-to-moment loop, the session loop and the long-term loop.
2. A motivation map using Self-Determination Theory: autonomy (meaningful choice), competence (visible mastery and progress), relatedness (friends, sharing, community).
3. A drive check using the Octalysis split. White-hat drives (meaning, accomplishment, creativity with feedback) should carry engagement. Ownership and social influence are fine when honest. Black-hat drives (scarcity, unpredictability, loss avoidance) may appear only mildly, transparently, and never as the main reason to return.
4. Flow: challenge matched to skill, clear goals, immediate feedback, a way to recover from failure.
5. Progress systems tied to real progress: levels, collections, milestones, personal bests.
6. Delight at peak moments and at the end of a session (peak-end rule), and personality in empty and success states.
7. Honest reasons to return: new content, unfinished goals the user chose, friends' activity, fair streaks with a freeze or forgiveness.
8. Personalization from in-product behavior, on device where possible, never from tracking the user elsewhere.
9. Session endings: end on a high point, with a clean exit and a reason to return, never a trap.
10. The ethics log: every engagement feature with its answer to the ethics question below.

## By product type

- Games: juice (screen shake, particles, sound and haptic feedback, hit-stop) used with restraint; game feel; onboarding through play rather than text; fail fast and retry fast; a difficulty curve; quick rematch; transparent reward schedules. In games of chance, perceived fairness decides trust: players read streaks as rigging, so show fairness honestly (roll history, odds, verifiable results where the product supports them).
- Entertainment and content: continue watching or reading, balance between discovery and comfort, zero-friction resume, natural stopping points.
- Social: meaningful interactions over counters, safe defaults, easy muting, blocking and leaving.
- Productivity and business: engagement means mastery and satisfaction. Celebrate completed work, show time saved, offer growth paths for power users. No streaks or badges that pressure people at work.

## Ethics gate (every track; reviewed in Steps 6, 7 and 12)

Allowed: real progress, earned rewards, reminders the user opted into, fair streaks, meaningful social features, delight.

Forbidden. Each occurrence is S0:

- confirmshaming ("No thanks, I prefer losing")
- fake scarcity, fake urgency, countdowns that reset
- hidden costs, hidden cancel or unsubscribe, flows that are easy to enter and hard to leave
- pre-checked consent, items sneaked into a cart
- disguised ads, trick questions
- infinite feeds or autoplay without stopping cues where that harms the user
- guilt or loss-aversion notifications ("Your pet is dying!"), notification spam
- paid randomized rewards without clearly shown odds
- progress or data held hostage to continued use or payment
- asking for notification permission before the user has seen value; ask in context instead
- mechanics built for compulsion rather than enjoyment

Every engagement feature must pass one question, answered in the ethics log: "Would the user thank us for this if they fully understood how it works?" No or unsure means rejected.

Children and families (`AUDIENCE` is children-under-13 or families) add: no streak loss penalties, no social comparison pressure, no time-limited offers, no purchase or ad prompts inside play or on reward screens, a parental gate before purchases, external links and sharing, no personalization based on tracking, notifications only when a parent opts in, and clear stopping points. R1 verifies the current Google Play Families policy, Apple's rules for the Kids category, COPPA and the UK Age Appropriate Design Code with VERIFIED references whenever a plan touches engagement. Any doubt: do not ship the mechanic, escalate.

Store and legal rules change. Whenever a plan touches randomized paid items, subscriptions, notifications or children, R1 verifies the current Apple App Store and Google Play rules.

## Metrics owned (the program never adds tracking; existing analytics are read-only)

| Metric | How |
|---|---|
| time to first fun or first value | effort_calc.py on the first-run flow plus measured seconds |
| taps from launch to the core loop | effort_calc.py |
| honest reasons to return | count from the ethics log, each one passing the question |
| sessions that end on a dead end or an error | walk plus forced failures |
| ethics gate violations | review; must be 0 |
| retention D1, D7, D30 and session length | only if analytics already exist; read-only |

## Out-of-the-box prompts for Step 5

- What is the single most satisfying moment in this product, and how do we make it ten times better?
- What would make someone tell a friend about this today?
- What would make the last 10 seconds of a session feel great?
- What could this product celebrate that nobody else does?
- What can we give users that makes them feel smart, skilled or connected?
