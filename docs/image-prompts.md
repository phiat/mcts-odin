# Image prompts for the mcts-odin homepage

Prompts to hand to Claude Design (or any image-gen tool capable of producing SVG / static raster output) for the `site/` homepage. Each prompt is self-contained and copy-pasteable. Style notes at the bottom apply across all assets — keep them in sync if the site palette changes.

The site lives at `site/index.html` and uses a dark-first theme with an orange accent. The assets below should match it without needing site-side CSS tweaks.

---

## Asset 1 — Animated MCTS tree SVG (recommended primary)

**Goal:** A visual that *shows* what this library does, replacing or augmenting the text-only hero. Educational at a glance (a developer who has never seen MCTS should get the gist) and aesthetically calm — no flashing, no rapid motion.

**Prompt:**

> Produce a self-contained, looping SVG (SMIL animations, no JavaScript) that visualises one full Monte Carlo Tree Search iteration cycle: **Selection → Expansion → Simulation → Backpropagation**.
>
> **Composition:** A tree of small filled circles (nodes) on a dark background. Root at the top, branching downward 3 levels deep with roughly 2–3 children per node. Edges are thin straight lines.
>
> **Animation, looping ~6 seconds total:**
> 1. **Selection (0.0–1.5s):** highlight a path from root to a leaf — edges along the path get the orange accent color and slightly thicker stroke; nodes on the path light up in sequence with a subtle scale-up pulse.
> 2. **Expansion (1.5–2.5s):** two new child circles fade in below the selected leaf with a brief scale-up from 0.
> 3. **Simulation (2.5–3.5s):** a small "value" number (e.g. "0.7") fades in beside the newly expanded child. No literal rollout animation — just the value appearing is enough.
> 4. **Backpropagation (3.5–5.0s):** the value pulses back up the selection path, each node briefly flashing orange as the visit count next to it ticks up by 1.
> 5. **Pause (5.0–6.0s):** everything returns to neutral, ready for the next loop.
>
> **Palette (must match):**
> - Background: `#0d1117` (or transparent — site will provide bg)
> - Default node fill: `#30363d`
> - Default node stroke: `#8b949e`
> - Default edge stroke: `#30363d`
> - Accent (selection path, pulses): `#f47b30`
> - Text/numbers: `#c9d1d9`
>
> **Format constraints:**
> - SVG only, ≤30 KB, no external resources (no `<image href>`, no web fonts — use a generic `font-family: monospace`).
> - Animation via SMIL (`<animate>`, `<animateTransform>`) or pure CSS `<style>` inside the SVG. **No JavaScript.**
> - Width 640, height 400, with `viewBox="0 0 640 400"` and `preserveAspectRatio="xMidYMid meet"` so the host page can scale it.
> - Smooth loop — no jarring snap at the end of the cycle.
> - Respects `prefers-reduced-motion`: include a `@media (prefers-reduced-motion: reduce)` block inside the SVG `<style>` that pauses or hides animation for users who opt out.
> - Decorative: `role="img"`, `aria-label="Animated diagram of a Monte Carlo Tree Search iteration: selection, expansion, simulation, backpropagation."`
>
> **What NOT to include:**
> - No literal Go board, chess pieces, or game-specific iconography — the library is game-agnostic.
> - No company logos, watermarks, or signatures.
> - No gradients, drop shadows, or glow effects (the site is flat).
> - No more than 12 visible nodes in the final frame — readability over completeness.

**Where it lands on the site:** Replace or sit above the current hero header in `site/index.html`. Reference as `<img src="mcts-cycle.svg" alt="..." class="hero-svg">`.

---

## Asset 2 — Wordmark / logo SVG

**Goal:** A small brand mark for the site header, favicon, and the eventual GitHub repo social-preview image. Should read as "mcts-odin" at any size from 32×32 (favicon) to 512×512 (social card).

**Prompt:**

> Produce a clean, geometric wordmark SVG for an open-source Monte Carlo Tree Search library called **mcts-odin**.
>
> **Composition:** The letters "mcts-odin" rendered in a single weight, paired with a small abstract glyph that suggests a tree-search structure — three dots (nodes) connected by two lines forming a tiny triangle or branching motif, sitting either to the left of or directly above the wordmark.
>
> **Two variants in one file** (using SVG `<symbol>` or two `<g>` siblings the consumer can pick by `id`):
> 1. `#wordmark-dark` — for dark backgrounds: glyph + text in `#f47b30` (or `#e6edf3` text + `#f47b30` glyph, your call).
> 2. `#wordmark-light` — for light backgrounds: glyph in `#cc5a16`, text in `#1f2328`.
>
> **Format constraints:**
> - SVG, ≤8 KB, no external resources, no web fonts. Convert the wordmark text to outlined paths so it renders identically everywhere.
> - `viewBox="0 0 320 80"` for the horizontal layout; supply a square `viewBox="0 0 64 64"` favicon-only variant as a third `<symbol>` (`#mark-only`) showing just the glyph centered.
> - No animation.
> - Decorative wordmark: `role="img"`, `aria-label="mcts-odin"`.
>
> **Aesthetic reference points:** htmx.org's wordmark, zig-lang's compass mark, redis.io's logo — geometric, single-color, no chrome.
>
> **What NOT to include:**
> - No literal chess/go pieces, dice, board grids, AI/brain icons, or robot motifs.
> - No serif typefaces, no script, no italics.
> - No "Odin" mythology references (Norse runes, ravens, horns).

**Where it lands on the site:** Replace the plain `<h1>mcts-odin</h1>` text with `<img src="wordmark.svg#wordmark-dark" alt="mcts-odin">`. Use `#mark-only` as the favicon (`<link rel="icon" type="image/svg+xml" href="wordmark.svg#mark-only">`).

---

## Asset 3 — Game showcase strip (optional)

**Goal:** A horizontal SVG strip of seven tiny board snapshots, one per demo game, slotted into the "Seven demo games" section to give it visual weight without dominating the page.

**Prompt:**

> Produce a single SVG containing seven small board snapshots in a horizontal row, one per game. Each snapshot is a minimalist representation of an in-progress position — enough to recognise the game at a glance, not a faithful state.
>
> **Boards, left to right:**
> 1. **Tic-tac-toe** — 3×3 grid, 2 Xs and 2 Os scattered.
> 2. **Connect Four** — 7×6 grid, ~10 filled cells stacking from the bottom in two colors.
> 3. **Reversi** — 8×8 grid, central 4 stones + 6 more nearby in two colors.
> 4. **Hex** — 9×9 hex grid (skewed rhombus), a short connected chain of stones near the centre in one color.
> 5. **Breakthrough** — 8×8 grid, two rows of pawns top and bottom (one color each) with two stones advanced in the middle.
> 6. **Gomoku** — 15×15 grid, a near-five-in-a-row pattern in one color, a couple of opposing stones in the other.
> 7. **Go** — 9×9 grid, a typical middle-game position with ~8 stones per side, including one small captured group.
>
> **Style:**
> - Each board sits in a ~96×96 px tile with `~8 px` internal padding.
> - Grid lines: 1 px, color `#30363d`.
> - Board background: `#161b22` (slightly elevated from page bg).
> - Stones / pieces: filled circles, 6–8 px radius. Player 1 in `#c9d1d9`, player 2 in `#f47b30`.
> - Tile rounded corners (4 px radius) and a 1 px border `#30363d`.
> - Small caption below each tile in 10 px sans-serif `#8b949e`, just the game name.
>
> **Format constraints:**
> - One SVG file, `viewBox="0 0 720 130"`, scales responsively to the 720 px content column.
> - No animation. No external resources.
> - Decorative: `role="img"`, `aria-label="Seven game boards: tic-tac-toe, Connect Four, Reversi, Hex, Breakthrough, Gomoku, Go."`
>
> **What NOT to include:**
> - No game piece *imagery* (no actual pawn silhouettes, kings, queens) — abstract circles only.
> - No game-name text inside the boards themselves — only the small caption below.
> - No flags, country motifs, or cultural decorations.

**Where it lands on the site:** Above the `<ul class="games">` list in the "Seven demo games" section. The list stays as the authoritative reference; the SVG strip is the eye-catch.

---

## Shared style notes (reference for all three assets)

| Token | Dark | Light |
| --- | --- | --- |
| Background | `#0d1117` | `#ffffff` |
| Elevated bg | `#161b22` | `#f6f8fa` |
| Text strong | `#e6edf3` | `#0f1419` |
| Text default | `#c9d1d9` | `#1f2328` |
| Text muted | `#8b949e` | `#59636e` |
| Border | `#30363d` | `#d0d7de` |
| Accent | `#f47b30` | `#cc5a16` |

**Universal constraints:**
- SVG only. No PNG/JPG/WebP unless explicitly fallback.
- No JavaScript inside any SVG.
- No external resources — every asset is a single file.
- Respect `prefers-reduced-motion` for any animated asset (Asset 1).
- Decorative `role="img"` + descriptive `aria-label` for accessibility.
- The site CSS already defines the palette as CSS variables — assets should use raw hex (or `currentColor`) so they work standalone as well as embedded.

**Out of scope:**
- 3D renders, photographic compositions, AI-generated faces or characters.
- Generic stock-illustration aesthetics (no smiling laptops, no abstract isometric workers).
- Norse mythology iconography (the "Odin" in the name refers to the Odin programming language, not the god — Asset 2 explicitly excludes this).

**Test before shipping:**
- Render in Firefox, Chrome, Safari — SVG SMIL works everywhere now, but verify.
- Open the SVG directly in a browser (no host page) to confirm it stands alone.
- Check at 50%, 100%, 200% zoom levels.
- Check both dark and light system theme (assets 1 and 3 should look fine on either; asset 2 needs both variants).
- Check `prefers-reduced-motion: reduce` for asset 1 (DevTools → Rendering pane in Chrome).
