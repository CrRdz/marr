# Marr outline UI icons

Created on 2026-10-23 using the built-in **imagegen** tool. The visual direction is the user-provided Claude desktop screenshots: quiet monochrome contours, rounded caps, clear small-size silhouettes. These are generated original UI glyphs, not extracted product logos.

## Files

- `source/core-atlas.png`: original generated 64-icon transparent atlas.
- `source/sidebar-no-bars.png`: sidebar override edited with built-in imagegen on 2026-10-31; keeps the outer frame and vertical divider, removes both interior horizontal strokes. The first manifest source takes precedence over the original atlas cell.
- `source/extended-atlas.png`: original generated 32-icon transparent atlas; two duplicate glyphs reuse the core artwork.
- `manifest.json`: atlas layout, 94 unique asset names, and semantic aliases.
- Contact sheets and offscreen panel captures are generated locally and ignored.
- `../../Marr/Assets.xcassets/MarrIcon-*.imageset`: shipped template PNGs at 1x, 2x and 3x.
- `../../Marr/DesignSystem/MarrIcons.swift`: shared SwiftUI / AppKit adapter and semantic aliases.

Run `swift scripts/package-marr-icons.swift` from the repository root to reproduce the asset slicing and contact sheets. The packager checks for clipped cells, trims transparent margins and fits the original artwork within a consistent optical box. No image generation is needed at build time. Runtime rendering uses bundled, cached template assets; it performs no network request or atlas slicing. Existing control colors, accessible button labels and explicit icon sizes remain in the views.

The thin-line refinement was rejected because it changed icon meanings and ordering. It is not shipped. The two accepted atlases are preserved unmodified above.

## Integration and validation

All app-owned SF Symbol image constructors were migrated across 16 UI source files. The adapter covers 130 semantic aliases, including dynamic activity, attachment, settings and composer states. SwiftUI labels, buttons and menus and the native status menu all use the same bundled artwork. System-drawn controls and the existing app identity remain platform-managed/existing artwork.

Final validation: `scripts/test-marr.sh` executed 586 tests: 556 passed, 30 configured skips, zero failures. This includes bundle loading, nonempty alpha, transparent corners, independent icon sizes, and real panel rendering in both appearances. Release build succeeded. No application was launched and no visible-window tests were enabled. Logs: `build/validation/icons-final.log`, `build/validation/icons-final.xcresult`, `build/validation/icons-release.log`.

The staged tree still matches `refs/checkpoints/pre-open-claude-ui-fixes-20261023`; this change remains unstaged and uncommitted.

## Accepted generation prompts

### Core atlas

Use case: logo-brand. Create ONE production icon sprite atlas for Marr, a native macOS screenshot and AI workspace application. A precisely regular 8 by 8 grid of 64 monochrome outline glyphs on genuinely transparent background, square 2048x2048 canvas. Each cell is exactly 256x256; each glyph centered in its cell, within 160x160 bounding area, stroke thickness 12 pixels, rounded stroke caps and rounded joins. Match the restrained warm humanist outline UI icon aesthetic of Claude desktop: quiet, spare, slightly softened geometric forms, consistent optical weight. Pure solid black strokes, transparent counters and background. No shading, gradients, shadows, text, labels, dividers, grid lines, tiles or colored backgrounds. Each glyph clearly recognizable at small size. Exact row-major order: row1 sidebar panel, magnifying glass search, plus, close X, chevron down, chevron right, chevron left, arrow up; row2 arrow down, curved return arrow, circular refresh arrow, external link arrow from square, branching path fork, opposing horizontal arrows, check mark, minus; row3 folder, folder with plus, archive box, document page, two overlapping documents copy, document with plus, trash bin, paperclip; row4 speech bubble, two speech bubbles, square with pencil new chat, pencil edit, image landscape, camera, crop viewfinder four corner brackets, crosshair target; row5 gear settings, three sliders, toggle switches, desktop window, code brackets, terminal prompt, hammer, wrench; row6 clock, clock with circular history arrow, three bar usage chart, shield with lock privacy, globe network, linked chain, four square grid, stacked layers; row7 sparkle fourpoint, open raised palm stop approval, warning triangle with exclamation, information circle, circled checkmark, circled X, three horizontal dots, pin; row8 magnifier plus, magnifier minus, sun appearance, moon appearance, split half-filled circle, power button, language translation speech with small abstract strokes NO LETTERS, checklist three rows. Maintain strict grid centers at x,y=128,384,640,896,1152,1408,1664,1920. No logo from any existing brand. Output only the atlas.

### Extended atlas

One production sprite atlas, 8 columns by 4 rows, landscape 2:1 transparent canvas. Exactly 32 black outline UI icons. Uniform medium thin rounded strokes, round caps, clean Claude desktop humanist geometric outline style. Every icon centered in equal cell with generous 20% margins. No backgrounds, grid lines, labels or text except symbols explicitly asked. Exact row-major order: row1 person profile in circle, two people, puzzle piece, CPU microchip, light bulb, light bulb crossed out, pause two bars, stop square; row2 hollow circle radio off, circle with center dot radio selected, dotted circle loading, minus in circle, question mark in speech bubble, question mark in circle, rectangle outline, two side-by-side panels rectangle; row3 table grid, aligned text three lines, numbered list with 1 2 3, export arrow rising out of tray, document with magnifying glass, document with gear, shipping package box, pencil nib; row4 eraser, hash number sign, at sign, command key loop symbol, desktop monitor, diagonal arrow northeast, folder with plus, shield lock. Preserve exact meanings and order. Consistent stroke weight near 7% of glyph height. Pure black strokes, truly transparent alpha.

### Sidebar simplification (2026-10-31)

Built-in imagegen edit of the shipped sidebar icon. Prompt: Remove both short horizontal strokes inside the right pane, leaving it transparent. Preserve the rounded rectangular frame, left vertical divider, proportions, stroke thickness and black template color. No text, shadows or additional elements; transparent background.
