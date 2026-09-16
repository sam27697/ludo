# Track B: UI visual and interaction design

Question: does it look, move and feel distinctive, consistent, polished and alive, while staying readable and accessible?

## Lens for Explore and Understand

- Hierarchy: the single most important thing on each screen is obvious within one second (squint test).
- Design system: count distinct colors, font sizes, spacing values, radii and shadows in use (probe `--inventory` on web, a style scan elsewhere). Inconsistency is a metric.
- Typography: a real type scale, line length of 45 to 75 characters, comfortable line height, clear weight contrast. For Arabic: a typeface designed for Arabic, sizes and line heights tuned for the script (Arabic usually needs more line height than Latin), no letter-spacing, numerals that match the locale.
- Color: palette logic, semantic roles, light and dark values, WCAG contrast, and never color alone to carry meaning.
- Layout: grid, spacing rhythm, alignment, density, whitespace, safe areas and notches on mobile.
- Components: buttons, inputs, cards, lists, dialogs, sheets and navigation, each with hover, focus, pressed, disabled, loading and error states.
- Icons and imagery: one consistent style, meaning before decoration, directional icons mirrored in RTL.
- Motion: purposeful; 150 to 300 ms for small changes and up to 500 ms for large transitions; consistent easing; animate transform and opacity rather than layout; reduced motion honored.
- Micro-interactions: every interactive element answers a touch or click.
- Identity: with the logo hidden, could someone recognize this product from a screenshot?

## Cycle 1 builds the foundation, because it survives later restructuring

- `tokens.md` version 1, with the same tokens implemented in code (CSS variables, a theme file, a Tailwind config, Flutter `ThemeData`, or the platform's theme): color with semantic aliases and light and dark values, a type scale, a spacing scale on a 4 or 8 base, radii, elevation, motion durations and easings, z-index layers.
- A component inventory: existing components against target components, with merge or replace decisions.
- A visual direction board with three directions (Safe, Bold, Wild), each with palette, type pairing, shape language, motion personality and a reference mood. Score them like concepts; the winner becomes the direction.
- One signature element chosen (creativity.md section 2).

Cycles 2 and later: screen-level craft on core screens, the motion system, micro-interactions, dark mode quality, empty and error state design, and higher token adoption.

## Metrics owned

| Metric | How |
|---|---|
| distinct font sizes, colors, radii, shadows, spacing values on core screens | probe `--inventory` (web) or a style scan |
| token adoption: style values that reference tokens / all style values in core and changed files | static scan, logged |
| contrast failures | axe color-contrast or the platform checker |
| unexpected visual changes on unchanged screens | screenshot comparison with the previous cycle |
| recognizability | logo-hidden test recorded by the reviewer |

## Out-of-the-box prompts for Step 5

- What if the interface reacted to context: time of day, progress, streak, the content itself?
- What signature interaction could become the thing people remember and imitate?
- What would a luxury brand, a game studio and a Swiss poster designer each do with this screen?
- Where can motion carry meaning (spatial continuity, cause and effect) instead of decorating?
- What can be removed entirely?
