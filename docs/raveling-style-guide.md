# Raveling — Sandbox & Dashboard HTML Style Guide

Rules for all generated HTML pages: sandboxes, dashboards, and project apps.
These are non-negotiable defaults; deviate only with explicit human sign-off.

---

## Theme

Dark background always. The three structural tones:

| Layer | Value | Source |
|---|---|---|
| Page background | `#181818` | Ink Black |
| Section / card surface | `#303030` | Dark Ink |
| Component stage well | `#222222` | (derived mid-tone) |

The light palette entries — `Paper` (#E6E2D3) and `White Paper` (#FFFFFF) — are for **text only**. Never use them as page or surface backgrounds.

---

## Typography

Load both fonts in one request:

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Silkscreen&family=Quantico:ital,wght@0,400;0,700;1,400;1,700&display=swap" rel="stylesheet">
```

**Silkscreen** is the default display font — use it for everything: headings, labels, chips, nav, UI text. Set it on `body` so it inherits everywhere. Never set `font-weight: 700` on Silkscreen elements; the face is bold enough at 400.

**Quantico** is the prose font — use it only for blocks of descriptive copy (paragraphs, doc text, long-form labels). Apply via a `.text` class rather than a blanket element selector.

```css
body   { font-family: 'Silkscreen', monospace; }
.text  { font-family: 'Quantico', monospace, sans-serif; }
```

Scale minimums:

| Element | Size | Weight |
|---|---|---|
| H1 (Silkscreen) | ≥ 3rem | 400 |
| H2 (Silkscreen) | ≥ 1.25rem | 400 |
| Body / labels (Silkscreen) | ≥ 1rem | 400 |
| Prose `.text` (Quantico) | ≥ 1rem | 400 or 700 |

Line-height 1.4–1.6. Never drop below 1rem for any visible text.

Decorative rules (h1 underline, `<hr>` separators): **10px**.

---

## Color Palette

All accent colors come from `core/utilities/RavelColors.ts`. Sandbox color roles:

| Role | Color name | Value |
|---|---|---|
| Page background | Ink Black | `#181818` |
| Section / card surface | Dark Ink | `#303030` |
| Component stage well | (derived) | `#222222` |
| Body text | Paper | `#E6E2D3` |
| Headings | White Paper | `#FFFFFF` |
| Muted labels / subtitles | Pencil | `#666666` |
| Structural borders / rules | Pencil @ 30% | `rgba(102,102,102,.30)` |
| Gidget accents | Thread Cyan | `#20C8D8` |
| Gadget accents | Thread Magenta | `#FF4FB3` |
| Broker accents | Thread Green | `#00CC00` |

**Fluoro colors** (Lime `#A7FF00`, Pink `#FF37A8`, Orange `#FE6810`, Cyan `#00F0FF`, Violet `#B300FF`) pop on dark backgrounds and work well for chips, LEDs, and small highlights — not for large surface backgrounds.

**Thread Blue** (`#0000CC`) and **Thread Purple** (`#6401DA`) are too dark on dark surfaces; prefer Thread Cyan or Fluoro Violet for readable accents in dark UI.

### Indicator colors

All status indicators — dots, LEDs, borders, badges, progress rings — must use the Fluoro palette exclusively. No off-system greens, ambers, or reds. Suggested semantic assignments (not mandatory, but consistent across the system):

| State | Color | Value |
|---|---|---|
| Loading / pending | Fluoro Orange | `#FE6810` |
| Ready / success | Fluoro Lime | `#A7FF00` |
| Active / playing | Fluoro Cyan | `#00F0FF` |
| Error / failure | Fluoro Pink | `#FF37A8` |
| Warning / caution | Fluoro Violet | `#B300FF` |

Idle / off states use the neutral dot background: `rgba(255,255,255,0.15)` on dark surfaces.

---

## Sandbox Layout

`index.html` is the master system sandbox — every registered component appears here.

- Organise by category: **Gidgets**, **Gadgets**, **Brokers**, **Assemblies** (omit empty categories).
- Within each section, use a **flex column** — one `.element-cell` per component, stacking vertically.
- Each cell: an `.element-label` (1rem, Pencil) above a `.stage` container.
- All stages: `overflow: hidden` to bound contents, sized generously for the component.

### Stage patterns by component display mode

| Display mode | Stage class | Setup |
|---|---|---|
| `inline-block` — button, help, trombone, glottalizer | `.stage` fixed w×h | `position:relative; overflow:hidden`; size to component default + comfortable padding |
| `position:absolute` fill-parent — sequence, card (`100vw × 100vh`) | `.stage-fullscreen` + `.scale-wrap` | Stage is `50vw × 50vh`; wrap component in a div: `position:absolute; top:0; left:0; width:200%; height:200%; transform:scale(0.5); transform-origin:top left` |
| `position:absolute` sized-self — roll-perf | `.stage` fixed w×h | Component sets its own `position:absolute` in JS; parent **must** be `position:relative` and `overflow:hidden`; size stage to the component's default footprint + padding |
| `display:block` fill-width — roll, roll-track | `.stage-block` full-width, fixed h | `position:relative; width:100%`; set an explicit height in px |
| `position:fixed` / viewport — alert | — none — | Place at page root; show a trigger button in a regular `.stage` instead |

### Minimal CSS skeleton

```css
.stage {
  position: relative;
  background: #222222;
  border: 2px dotted rgba(102,102,102,.40);
  border-radius: 4px;
  overflow: hidden;
}

.stage-block {
  position: relative;
  background: #222222;
  border: 2px dotted rgba(102,102,102,.40);
  border-radius: 4px;
  overflow: hidden;
  width: 100%;
}

.stage-fullscreen {
  position: relative;
  background: #222222;
  border: 2px dotted rgba(102,102,102,.40);
  border-radius: 4px;
  overflow: hidden;
  width: 50vw;
  height: 50vh;
}

.scale-wrap {
  position: absolute;
  top: 0;
  left: 0;
  width: 200%;
  height: 200%;
  transform: scale(0.5);
  transform-origin: top left;
}
```

A sandbox body should have a yellow and red border like this:

      border: 10px solid #ff0000;
      box-shadow: 0px 0px 0px 10px inset #ffcc00;

---

## Script Imports

Always load through the root entry point — never `./core/index.ts` directly (that file only exports utilities, not custom element registrations):

```html
<script src="/core/libs/p5.min.js"></script>
<script type="module" src="./index.ts"></script>
```

---

## What to Avoid

- Off-system colors — any hex not in `core/utilities/RavelColors.ts` or the three structural tones above.
- Inline styles that could be a class.
- `<style>` blocks inside `<body>`.
- Light backgrounds on the page or card surfaces.
