# Marr desktop design system

### Conversation and Work starting pages (2026-11-03)

Empty Conversation and Work share a vertically centered welcome row and composer,
based on the supplied reference. The existing live glass companion sits beside a
28 pt serif greeting; below 520 pt of content width the row stacks without
recreating the Rive instance. The starting composer is capped at 560 pt, with 40–52 pt minimum writing
space scaled to its width and 16 pt insets. The companion is 56 pt with a 20 pt
gap between the welcome row and input. Attachments stay left, model/reasoning and send stay right. Work
places its actual workspace picker and create action in an attached lower row;
project cards no longer compete with the starting prompt. Both modes reserve the
same 48 pt project-strip space, so their heading and composer stay aligned.
Work uses one continuous rounded outer shell; the header no longer duplicates
the workspace picker. Model menus anchor to the actual button before its layout
frame, collapse in 160 ms without spring overshoot, and restore editor focus
only after the animated surface is removed. Their expanded right edge stays at
the model button’s right edge, reserving the send button throughout the transition.
The dismissal backdrop passes through the send control so an eligible draft can
still be sent while the model picker is open. Sending the first
message returns the composer to the compact bottom layout. The 720 pt maximum
reading width, navigation rail, focus semantics and existing draft bindings remain.


### Settings alignment and speed controls (2026-10-26)

Settings uses one leading content edge and one trailing control edge. Search and
the page heading stay above the scrolling body; the heading remains fully visible
when settings scroll. Section content aligns left, including account actions and
supporting text. Fixed-width native menus align to the trailing edge of their
frames rather than centering inside them.

AI & Models owns saved connections and the default model assignments for
conversation and screenshot translation. Connection management never selects a
default implicitly. ChatGPT sign-in and API credentials belong to each connection;
there is no separate Account destination. Multiple connections to the same service
have distinct names and credential references. Translation can follow conversation
or select another saved connection without duplicating credentials. Codex account
and runtime management belong to Work & Integrations. The conversation model menu
shows the model together with its connection name.

The lightning control means speed mode (Standard / Fast) with no fixed speed
multiplier. OAuth reasoning retains the native tick slider in both composer and
Settings. Automatic is its first tick; opening it does not change the preference,
and arrow keys move one supported level at a time.

Verification: macOS build passed; 43 targeted tests passed, 6 visible-window tests
skipped, no failures. Offscreen previews were inspected at narrow and wide widths
in both appearances, including the pinned title after scrolling. No visible
window or real OAuth action was used. Historical preview files were removed during repository cleanup.

Updated 2026-10-23. Applies to the answer panel, workspace/history navigation, settings, composer, tool cards and media controls. Screenshot annotations and translated source typography retain their content-specific geometry.

## Direction

Quiet, neutral-white desktop UI. Give the conversation the strongest hierarchy, keep navigation compact, and reserve color for selection, actions and factual status. Use flat internal surfaces and subtle borders; glass belongs to the outer floating window rather than every list or card. Respect existing accent/bubble preferences.

Reference: locally inspected open-claude-ui `c1f923ae0051a871941b98a0e2e3183a545e6a85`, especially `code-examples/cds-theme.css` (neutral ramp, surface layers, radii, restrained shadows). Web rem values are translated into native points; they are not a global scale transform. UI/UX Pro Max's minimal desktop guidance was used; its generic marketing layout and purple AI palette were not adopted.

## Type and icon pairing

| Role | Text size (pt) | Icon box (pt) | Use |
| --- | ---: | ---: | --- |
| Badge / caption | 10 / 11 | 12 | Counts, compact metadata |
| Secondary | 12 | 12 | Descriptions, supporting status |
| Body / controls | 13 | 14 | Navigation rows, menus, ordinary controls |
| Answer / editor | 14 | 14 | Reading and composing |
| Title | 16 | 16 | Conversation and section titles |
| Page title | 18 | 16 | Settings page headings |
| Brand / hero | 20 / 24 | 24 | Rare empty states and top-level summaries |

Use `MarrTypography` and `marrTextStyle`. Use `MarrIcon` for UI assets: inherited icon geometry follows the text role. Explicit geometry is limited to `MarrUI.Icon` roles (disclosure 10, status 12, inline 14, navigation 16, toolbar 18, hero 24). The generated glyphs occupy 84% of their box. Font modifiers do not size raster icons.

Native menu labels can ignore external image frames. `MarrIcons.viewImage` caches images with correct intrinsic sizes per asset/role; it does not copy/decode a bitmap for each row evaluation. AppKit menus use the same asset map.

## Geometry

- Primary rhythm: 4 / 8 / 12 / 16 / 24 pt. A 6 pt optical small gap remains available for tight legacy controls.
- Controls: 28 pt compact, 32 pt regular, 36 pt spacious. Icon ink is smaller than its hit target.
- Navigation rows: 32 pt; local history rows with summaries: 56 pt.
- Radii: 8 pt controls, 12 pt cards/bubbles, 16 pt panels, 20 pt composer.
- Labels at one hierarchy level use regular weight; selection uses medium. Headings use semibold. Do not add per-screen rounded font variants.
- Preserve focus indicators, readable metadata, accessible button names, reduced motion, and user resizing. Window expansion/collapse semantics remain unchanged.

## Agent transcript hierarchy

- Read each turn as: user request, a collapsed process disclosure, answer, then
  deliverables. Keep pending approvals and task-level errors visible without opening
  the process. Individual tool failures, including failed attempts before a recovery,
  stay in that process with their original status. Only a matching pending user
  decision promotes a tool out of the process. Ordinary running tools also stay inside; use one compact
  current-activity label rather than a column of running tool cards.
- Respect runtime message phases. Commentary and provided reasoning summaries
  are process content, never the final answer. Preserve chronological order when
  expanded. Older unlabelled messages retain the last-message fallback. Do not
  invent reasoning or generate a summary from private deliberation.
- Start process disclosures collapsed, reset them on chat changes, and only
  construct their detailed content on expansion. Keep stable item identities and
  cached turn projections. Never animate each streamed text delta.
- Keep final prose visually dominant, without a separator for every answer.
  Center the transcript with a maximum reading width of 720 pt; narrower windows
  use the available width. Reuse the existing typography, icons, color and motion
  tokens. The copy action appears once a response item completes.
- Show failures compactly, with full diagnostics and copy behind Details. Tool
  parameters and raw events remain opt-in. Do not auto-expand long failure output.
  A disclosure must never hide an approval's choices or submitted form state.
  Command cards use a short Command heading; full shell text and output live in
  their expandable details. Do not expose raw commands as large transcript titles.

  Failure-folding verification (2026-10-24): 38 targeted tests passed, 6 configured
  visible-window tests skipped, no failures (`build/validation/fold-tool-failures.xcresult`).
  The offscreen history fixture now includes exit codes 1 and 65 before a successful
  retry; both failures remain folded with their full details intact. Pending approval
  correlation and task-level error placement are checked separately. Release passed
  (`build/validation/fold-tool-failures-release.log`); no visible windows were opened.
- Ordinary conversation prompting leads with the answer, matches the user's
  language/detail request, and omits repeated conclusions and routine preambles.
  Explain relevant evidence and uncertainty; do not claim unperformed actions.
  Existing Codex workspace instructions remain authoritative and unchanged.

### Answer typography

Prompts and answers share 14 pt system sans text, including the system's CJK
fallback. Normal body weight is regular; Markdown emphasis uses semibold rather
than a second default bold treatment. Heading levels use 18 / 16 / 14 pt semibold.
Process prose stays at 13 pt, with compact headings at 14 pt. UI controls retain
their existing scale; this is not a view transform or a replacement translation
font.

Use 4 pt extra body leading, 10 pt block spacing (6 pt compact), and 4 pt list-item
spacing. Quotes and tables share prose rhythm. Code blocks use 13 pt monospaced
text and 4 pt leading; compact tool code retains 12 pt. Inline code is one point
smaller than its surrounding prose/heading, with a 12 pt floor. Inline parsing
and styled values are cached per source and size; links and code semantics remain
intact. Do not add custom fonts or per-message font guesses.

Typography verification (2026-10-24): 30 targeted Markdown, presentation-cache,
offscreen typography and scroll checks passed with no failures
(`build/validation/answer-typography-verified.xcresult`). Bilingual fixtures cover
headings, emphasis, links, inline/block code, quotes, tables and wrapped lists at
420 / 760 pt in both themes. The long-history fixture retained zero whole-timeline
evaluations over 80 scroll steps. These are offscreen results, not display FPS.
Release passed (`build/validation/answer-typography-release.log`); no app was opened.


## Surfaces

| Layer | Light | Dark |
| --- | --- | --- |
| Navigation / canvas | `#FFFFFF` | `#20201F` |
| Content | `#FFFFFF` | `#252524` |
| Raised / input | `#FFFFFF` | `#2C2C2A` |

Use `MarrUI.Surface` and `MarrPanelColors`; do not invent screen-specific gray values. Explicit resolved foregrounds are needed where AppKit vibrancy can resolve `.primary` against a different appearance. Keep status colors semantic and accompany them with text/symbols.

## History navigation

- Start workspace groups and local conversations collapsed. Discover newly synced workspaces in the collapsed state; preserve explicit expansion/collapse choices when switching conversations or rebuilding the panel.
- Project headers show the name without a visible conversation count. Background syncing has no routine refresh button or progress row; sync failures offer Retry. Keep the full directory in hover/accessibility help, including for duplicate names.
- Opening a history conversation is independent of send availability: pending reads, catalog refreshes and uncertain remote status may be superseded. Locally running turns and in-flight mutations remain protected.
- A selected cached conversation still reads its full thread. Repeated clicks during the same read reuse it; a different selection invalidates old requests, so late responses cannot overwrite the new conversation. Read failures can be retried by clicking again.

## Scrolling and updates

- One lazy row stack per history scroll view; project and local-history components expose rows instead of nesting their own lazy stacks.
- Hover belongs to each row. Never store the hovered row ID in the list's parent.
- Scroll anchor changes are observed by `MarrHistoryScrollView`, not the entire answer panel's navigation model.
- Transcript scrolling updates a title-only observer; after the 72 pt fade range it publishes no further changes.
- Local history search/date sections rebuild when records, query or day change, not on hover/scroll. Scrolling a group into view does not reload the database.
- Workbench ordering caches are invalidated by task, pin, archive and manual-order mutations. Task rows compare their presentation inputs before recomputing their contents.

## Verification

`MarrHistorySidebarRenderingTests` captures real compact/wide panels and settings in both themes without ordering or activating windows. A 300-chat / 40-scroll-step fixture reports layout time, panel evaluations and task evaluations. These are offscreen diagnostic costs, including event-loop/layout work, not display FPS. `MarrSurfaceTests` checks title update bounds and image resources; `CodexWorkbenchTests` checks cache invalidation across rename, pin, reorder, archive, restore and removal.

Use `scripts/test-marr.sh` without `--ui` for quiet validation. See `build/validation/scroll-before.log`, `scroll-verified.log`, `design-system-final.log` and `design-settings-contrast.log`. Original staged checkpoint remains untouched; this change is unstaged.

### Recorded results

- Baseline, 300 chats / 40 scroll steps: median 72.32 ms, p95 73.85 ms (`scroll-before.log`).
- Final history fixture: median 55.10 ms, p95 57.25 ms (`design-history-final.log`), about 24% lower median cost. Twelve task rows were evaluated initially; 111 row evaluations occurred while scrolling, with zero whole-panel evaluations. An intermediate flattened implementation still evaluated 1,066 task rows during the same scroll sequence; removing the extra grouping container brought that to about 100–111.
- Full quiet regression: 590 cases, 560 passed, 30 configured skips, zero failures (`design-system-final.log`). Later visual checks: 19 cases passed; history/projection checks: 4 passed. Final date/data checks and Release build logs are `design-history-data-final.log` and `design-system-release-final.log`.
- These measurements include an offscreen event-loop/layout probe and should not be reported as on-screen FPS or guaranteed frame time. No visible windows or focus changes were used.

Historical captures are not retained in the repository.

### History navigation follow-up

- Fixed history rows being disabled by send/read/refresh/remote-status gates, and selected cached rows bypassing full thread reads. Selection returns success/failure; failed selection no longer triggers a success callback. Read errors clear when retrying.
- Workspace and local-history groups start collapsed. Known workspace IDs preserve manual choices across panel replacement; newly discovered projects start collapsed. “Show all” does not override an explicitly collapsed project.
- Removed directory subtitles; paths remain available as tooltips and accessibility descriptions.
- `CodexWorkspaceTests` covers changing selection during a read, late response isolation, restored/unknown states, refresh cancellation, retry, repeated same-row selection, and protecting a locally active turn. Offscreen rendering checks collapsed defaults and transferred state.
- Final quiet regression: 594 cases, 564 passed, 30 configured skips, zero failures (`build/validation/history-navigation-all.log`). Release build passed (`build/validation/history-navigation-release.log`). No visible-window mouse acceptance test was performed; offscreen SwiftUI does not expose the complete interactive accessibility tree.

### Neutral white and glass refinement

All light semantic surfaces use the input white (#FFFFFF). Separate layers with
spacing and restrained borders rather than warm gray fills. Dark surface hierarchy
remains intact. Settings navigation uses 18 pt, resolved high-contrast outline icons.
Glass stays behind content, never refracting labels or icons. Native regular glass
provides backdrop adaptation with a neutral tint, plus a dark outer edge and white
inset highlight that remain distinguishable on plain white and colorful backgrounds.
No display sampling, screen recording, or recurring background image processing is
introduced. Reduced transparency uses fully opaque semantic surfaces.

The status menu uses NSStatusItem native menu tracking instead of a manually offset
view popup. Secondary click, Control-click and double-click cancel pending capture.

Neutral/glass validation: targeted gesture, surface-color and offscreen rendering
checks passed (10 tests; `build/validation/neutral-glass-focused.xcresult`).
The inspected light/dark previews showed the supported material
fallback; native Liquid Glass and physical status-menu placement require visible
window-server compositing and were not manually exercised during quiet validation.
Complete quiet regression: 604 cases, 574 passed, 30 configured visible-window
skips, zero failures (`build/validation/neutral-glass-all.xcresult`). Release build
passed (`build/validation/neutral-glass-release.log`), producing
`build/quiet-release/Build/Products/Release/Marr.app`. No application was launched;
the staged checkpoint is unchanged.

### Mode control restoration (2026-10-24)

At the user's request, restored the original Conversation / Work mode buttons
from before the segmented Picker experiment. The compact capsule group uses
content-sized buttons, selected semibold text, the original glass selection
highlight and matched-geometry transition. Both the standard segmented Picker
and the later equal-width custom glass variant are removed. Existing mode
switching, accessibility labels, arrow keys and focus behavior remain as before.
Restored Release build passed (`build/validation/original-mode-restored-release.log`).
No product windows were launched; the staged baseline is unchanged.


### Settings consolidation and concise controls (2026-10-24)

The sidebar now presents seven destinations: General, Conversation, Translation,
Work, Account, Archived chats and Advanced. General combines capture shortcuts,
capture availability and appearance. Account combines authentication and usage;
Advanced combines runtime connection and configuration. Legacy search terms and
navigation destinations resolve to their new parent pages. General uses the gear
icon; Advanced uses sliders.

Model rows show names and selection only; descriptions are available on hover.
Reasoning retains its selected value without a second explanatory paragraph or
default-value caption. Context appears only when usage data exists.
Permanent page summaries, sidebar sync narration and repeated sign-in explanations
are removed; actionable errors and sign-out confirmation remain.

The conversation width observer measures the sidebar's assigned canvas after its
fixed frame. Measuring the child's intrinsic width caused a feedback loop with
the composer's previous width during collapse/reopen. Offscreen assertions check
that reopening commits the destination width without intermediate width feedback.

Validation: complete quiet regression passed, 606 cases / 576 passed / 30 opt-in
window tests skipped / 0 failures (`build/validation/project-membership-settings-verified.xcresult`).
Release passed (`build/validation/project-membership-settings-release-final.log`).
Offscreen settings previews were checked in both appearances. No visible windows were
opened; native glass compositing was not exercised.


### Calendar reference: anchored expansion (2026-10-24)

The supplied 18:16 recording shows Calendar revealing space at its left edge
while the existing calendar body largely keeps its screen position. Marr's older
build visibly displaced the composer and body before settling. That recording
predates the assigned-canvas width observer fix above; it is not evidence of the
final build's frame rate.

During native window growth, use its actual viewport width as the single source
of sidebar reveal progress. The sidebar, conversation translation and toolbar
button share that progress. Do not start a separate SwiftUI reveal animation
against the native window animation, even with matching duration and easing.
At a retained window width, keep system-driven SwiftUI translations. Keep body
layout fixed to the destination width, preserve the user's expanded window size
on collapse, and settle immediately offscreen or with Reduced Motion enabled.
No frame timer or per-frame published state was added.

Tests sample irregular viewport widths, constrained expansion and a reversal.
The actual SwiftUI panel is also rendered offscreen across five simulated native
viewport sizes; its assigned body width must remain unchanged. These checks
verify geometry and layout isolation, not visible WindowServer compositing or FPS.

Final quiet validation: **608 cases, 578 passed, 30 configured window tests
skipped, 0 failures** (`build/validation/calendar-motion-final.xcresult`).
Release build passed (`build/validation/calendar-motion-release.log`), producing
`build/quiet-release/Build/Products/Release/Marr.app`; it was not launched.

### User message and attachment presentation (2026-10-24)

- Work renders a display-only projection of structured user content, shared by
  message bubbles and transcript export. Original protocol JSON and submitted
  model inputs remain unchanged. Cached messages prefer their original structured
  content over flattened display text.
- A complete, recognized attachment envelope becomes one set of attachment cards;
  repeated structured image references are deduplicated by normalized local path.
  Local/data images load thumbnail previews within the user bubble; remote images
  remain click-to-load. Image viewer and Finder actions live on the attachment,
  with secondary actions in its context menu. Missing images retain their filename
  and an unavailable state.
- Explicit skill/app references appear as compact labels. Known standalone runtime
  context envelopes are omitted from the transcript; unknown structured blocks
  remain available in a collapsed Message details section. Ordinary prose, code,
  literal paths and User request: markers are not globally stripped.
- Attachment-only turns remain visible and keep their responses. Presentation
  caching avoids reparsing unchanged user payloads during response streaming.
- Verification: 301 focused cases, 297 passed and 4 configured skips, zero failures
  (`build/validation/message-presentation-verified.log`). Offscreen snapshots cover
  light/dark and narrow/wide attachment layouts, including an unavailable image,
  and real history sidebar layouts. These do not replace live pointer/keyboard QA.

### Model menu selection and reasoning levels (2026-10-25)

- Conversation and Work share the refined composer model menu. On opening,
  receiving a model catalog or changing selection, reveal the selected model
  without animating through the list. A neutral row fill and checkmark identify
  selection; descriptions remain in hover help. Reselecting the current row
  preserves its chosen reasoning effort.
- Two to four supported reasoning levels use labeled native segments. Larger
  sets use a native slider with one tick per level and the current value above.
  Deduplicate and order advertised levels; preserve unknown or omitted values
  until an explicit user choice. An omitted effort reads Automatic, never the
  lowest advertised level. A stale value reads Unavailable.
- The composer shows model and effort together when the full summary fits.
  Narrow layouts fall back to the model name; hover help and accessibility retain
  the full summary. The send/stop controls keep their existing reserved space.
- Running tasks still allow opening the menu to inspect context, while model
  and effort changes remain disabled. Native controls retain focus indicators
  and keyboard interaction; the existing Escape dismissal path is unchanged.

Validation: the focused suite passed 175 cases, including 13 configured
visible-window skips and zero failures
(`build/validation/omerico-model-verified.xcresult`). Offscreen checks cover full
selected-row visibility after async catalog changes, native control value mapping,
arrow-key stepping, disabled states, Automatic/Unavailable and light/dark layouts.
Light/dark menus and compact labels were checked offscreen. No product window was
opened; live popover placement, Escape through the native focus chain and
WindowServer compositing were not exercised.
The final Release build passed in its own output directory after the shared
Release build database was busy (`build/validation/omerico-model-release-isolated.log`),
producing `build/omerico-release/Build/Products/Release/Marr.app` without launching it.

### Marr model controls and original glass slider (2026-10-26)

- The composer keeps model, reasoning and a small lightning indicator inside
  one quiet button. Omit internal vertical rules and separate speed badges.
  Model text leads; reasoning is secondary. Attachment and send keep their space.
- The compact model panel uses a leading model row with the existing layers
  icon. A 28 pt glass lightning button and quiet reset action sit at the trailing
  edge. Remove the large Standard/Fast rectangle and internal horizontal rule.
  Reasoning aligns left with its current value right, followed by the slider
  and subtle minimum/maximum labels. Model choices expand from the model row.
- Keep the original unmodified `NSSlider` and `NSSliderCell` with the original
  native control setup. macOS supplies the glass thumb, track, focus, hover and dragging
  behavior. Do not substitute custom outlined dots or painted capsule cells.
  Preserve discrete supported effort ticks, keyboard steps, Automatic and disabled
  state. The speed button uses Marr's existing native glass surface, including
  Reduce Transparency and older-system fallbacks. Its active icon follows the
  chosen accent; the slider retains its native system appearance.
- Settings and the composer share this component. Reset restores Automatic and
  Standard for plan usage; Codex retains its model's declared effort default.
  Display `xhigh` as Extra high. Speed remains Standard/Fast with no promised
  multiplier, and unsupported models disable it. Tooltips and accessibility
  values expose the current speed state.
- Saved account-specific model catalogs display immediately, with a five-minute
  freshness interval and coalesced background requests. Refreshing does not lock
  controls or blank the list. A transient failure retains choices and offers
  Retry. Sending uses saved model metadata while inference continues to validate
  authorization. Account lifecycle changes invalidate their catalogs.

Validation: compilation and 46 focused regression cases passed, with 7
configured visible-window skips. After the final circular glass clipping change,
the rendering and native-slider keyboard tests passed again. Reviewed light,
dark and custom-accent offscreen previews in `previews/model-controls-glass/`.
The slider is verified to use the original NSSlider rather than a custom
subclass/cell; native keyboard steps, thumb bounds and disabled state pass.
Logs: `build/validation/model-controls-glass.log` and
`build/validation/model-controls-glass-render.log`. Native glass refraction and
hover under WindowServer require a visible app; bitmap previews verify layout
and contrast, not live material compositing.

### Composer control expansion (2026-10-26)

Reference: [AI 输入框，不该只有一个发送键](https://xhslink.cn/o/8mf93XgD69z).
Model and mode controls grow upward from their own toolbar bounds. The plus
reveals inline attachment actions first. This supersedes the earlier separate
popover implementation and its static previews in `previews/composer-menu-flow/`.

- A model control becomes the menu surface in the same window. Its lower edge
  stays on the control's baseline. The source label fades into full-size menu
  content through an expanding mask; text and the native glass slider never scale.
  Selecting a model, Escape and outside dismissal reverse the expansion.
- The plus expands horizontally into Close, Attach files and (for Work) More
  context. Neighboring controls give up space; the editor and trailing action stay
  put. More context grows from that expanded entry. Its actions retain the existing
  attachment picker, workspace mentions, skills, goals and connected-tool routes.
- Work / Plan uses a small two-choice surface anchored to its original control.
  During attachment expansion, its icon remains while the label makes room.
- One active menu owns input. Switching to another entry works directly. Closing
  and reopening during motion invalidates stale completion work. Focus returns to
  the existing draft; opening Settings or a goal editor preserves that destination.
- Search remains the bottom row, above the original toolbar baseline. Results
  scroll independently; filtering does not resize the viewport. The native search
  field preserves IME, clear-button and keyboard behavior. Empty results consume
  Return. Selecting the current model preserves its custom effort.
- Size and position come from the real control and composer bounds. On narrow
  windows, reduce menu width before shifting left, keeping the menu inside the
  composer's horizontal edges and on its control's bottom baseline.
  The local native backdrop handles outside clicks without capturing hits inside
  the menu, including AppKit search and slider controls.
- Model menus are at most 240 pt wide; context menus 256 pt and mode menus 160 pt.
  Headers, row icons, separators, reasoning controls and search share a 12 pt
  content inset. Highlight backgrounds extend 6 pt beyond the row's content edge.
  Single-line model rows are 32 pt, detail rows 40 pt, with 2 pt between rows.
  The reasoning label and value share one line; the original slider stays full size.
- Model menus use native clear glass for the rim and reflections, with an
  ultra-thin backdrop material to isolate draft/attachment text beneath the menu.
  Context and mode menus retain the frosted thin material. This follows Apple's
  [clear-glass legibility guidance](https://developer.apple.com/documentation/swiftui/glass/clear).
  Increased Contrast strengthens the material; Reduce
  Transparency or disabling glass restores an opaque raised surface.
  The original NSSlider, speed control, accent preferences,
  Reduce Motion and Reduce Transparency remain supported. No fake voice actions.

Validation and actual interaction recordings are stored in
`build/validation/composer-control-morph.log` and `previews/composer-control-morph/`.
The recordings use an isolated local test session and fixture models, not a real
account or conversation. They exercise the production AnswerPanelView.

Initial expansion validation: build succeeded and all 6 selected checks passed, with no skips.
Visible production-window tests cover the plus expansion, model search/selection,
menu switching, Escape/focus restoration, draft preservation and running-task
send/stop controls at 420/720 pt in both appearances. Four offscreen checks cover
baseline geometry, filtering, IME/keyboard behavior and native slider steps.
`composer-interaction.gif` replays captured production-view frames with short
reading pauses; it is a UI test recording using fixture data.

Glass refinement: the production-window expansion, selection, menu-switching and
draft-preservation check passed after replacing the opaque menu fill. Fixture
captures are in `previews/composer-glass-menu/`; the validation log is
`build/validation/composer-glass-menu.log`. Bitmap captures show layout and text,
while the live material is composited by macOS.

Compact clear-menu validation: build and all 4 selected checks passed, with no
skips. Production-window checks cover expansion, switching, draft preservation,
running-task controls and text visibility at 420/720 pt in light/dark appearances.
Native search/IME and original NSSlider keyboard checks also passed. Single-model
catalogs fit one row; detailed action rows remain fully visible before scrolling.
See `build/validation/composer-compact-clear.log` and
`previews/composer-compact-clear/` for fixture captures. Cropped previews preserve
the rendered menu and composer geometry; they do not simulate glass compositing.


### Personal Agent navigation shell (2026-10-28)

A 64 pt leading icon rail sits outside the existing Conversation / Work canvas.
The default window reserves this additional width; the chat retains its original
420 pt minimum canvas. History still reserves its own 261 pt column. Native
window motion uses full-window coordinates and is translated once for the inner
chat canvas, preserving stable transcript and composer widths.

The rail has exactly two destinations, with 44 pt native button targets, names,
selection traits and tooltips. The Personal Agent entry uses a blue soft-star
vector mascot with restrained glass shading. The destination is currently a
placeholder, pending the user's agent orchestration design. Switching sections
keeps the chat mounted, persists drafts and releases hidden editor focus. Escape
and the back gesture return to chats. Agent pages retain shared window controls
and an empty-header drag region. No agent execution or background schedule is
started by opening the destination.

Validation: app build and 49 focused layout, draft and offscreen-rendering tests
passed with zero failures (`build/validation/personal-agent-final.xcresult`).
Light/dark chat and agent captures are in `output/personal-agent-navigation/`.
No visible product window was opened. The code-quality script still reports the
three pre-existing file-length violations in AgentComposerView,
AnswerPanelView and TranslationRenderer; no size budgets were increased.


### Restore answer-panel glass separation (2026-10-28)

The navigation change accidentally enabled foreground glass effects on the
whole chat subtree. On a real desktop this removed the background-only top frost
and adapted text against the wallpaper, producing an overly clear panel and pale
labels. Restore the original `marrGlassSurface` default:
`appliesForegroundEffects: false`. Glass and the top frost stay in the background;
text, buttons and the composer remain ordinary foreground content. The new rail
and Agent placeholder retain their own surfaces. Offscreen captures cannot
confirm the actual wallpaper-composited appearance.


Verification of the restored parameters: app compilation and all 32 sidebar
geometry tests passed. Offscreen visual/layout assertions passed, but the panel
fixture still reports retained history stores during teardown (three failures in
`restore-answer-glass-verified.xcresult`). Do not describe this run as fully passing
or as verification of wallpaper-composited native glass. Experimental hosting
cleanup and layer restructuring were not retained; the final change restores the
original surface invocation without enabling foreground effects.


### Shared navigation and answer backdrop (2026-10-28)

Navigation, chat and the Agent placeholder share one outer glass surface,
including the original background-only top-frost gradient. Remove opaque fills
from the rail and Agent landing, and remove the inner chat's rounded glass frame
so there is no separate glass boundary at the join. Local button selection
states distinguish navigation without a vertical divider. Keep the glass
foreground-effects option at its original false default.

Retain the original 64 pt rail, 44 pt button targets and 10 pt horizontal gutters.
The shell reserves this width outside the existing 420 pt conversation canvas;
history animation geometry continues to subtract the shared rail-width constant.

Final shared-background validation: app build and all 33 focused layout and
light/dark offscreen panel tests passed, including fixture teardown, with the
original 64 pt rail (`build/validation/shared-navigation-glass-64.xcresult`).
Previews use `output/personal-agent-navigation/shared-glass-*.png`. No visible
product windows were opened; these do not verify wallpaper compositing.


### Lighter shared frost (2026-10-28)

The user requested slightly greater overall transparency while preserving the
frosted gradient. The shared navigation/answer shell now uses `frostOpacity: 0.80`.
This scales only the background material-and-tint veil after the existing gradient
mask. Native clear glass, border treatment, gradient stops, content opacity and
64 pt rail geometry remain intact. Other glass callers retain the default 1.0.
The non-Liquid-Glass material fallback uses the same veil strength for top-frosted
surfaces. Increased Contrast keeps full-strength frost, and Reduce Transparency
continues to use its opaque semantic background.

Lighter-frost validation: app build and seven existing surface/offscreen panel
tests passed (`build/validation/lighter-shared-frost.xcresult`). Light/dark
captures are `output/personal-agent-navigation/lighter-frost-*.png`; actual
wallpaper-composited transparency remains a visible-desktop check.

### Unified window toolbar (2026-10-28)

Place window controls in the upper-left of the entire shell, above the navigation
rail, with close, minimize and green zoom/restore buttons. Anchor the toolbar to
the outer shell so expanding history does not move its controls. Conversation /
Work and settings remain at the trailing edge. The toolbar and 64 pt navigation
rail share the existing glass background with no vertical dividing rule. Preserve
the answer/composer layout and the 0.80 top-frost veil.

Green zoom fills the current display's usable frame and restores the previous
frame on the next click. Clamp restoration to the available display area and
respect Reduce Motion. This is window zoom rather than a full-screen Space.

Validation: app compilation and 42 focused geometry, zoom, surface, history and
Agent rendering tests passed (`build/validation/unified-window-toolbar-v1.xcresult`).
Light conversation and dark Agent offscreen captures confirm the shared chrome;
native wallpaper compositing remains a visible-desktop check.

### Native traffic-light controls (2026-10-28)

Use AppKit's `NSWindow.standardWindowButton(_:for:)` for close, minimize and
zoom, hosted in a 60 × 30 pt NSView in the upper-left toolbar. The user reverted
the soft recessed design: no custom colored circles, symbols, capsule or shadows.
AppKit owns the button appearance, including inactive-window styling. Keep the
existing panel lifecycle actions, 64 pt navigation rail and shared glass intact.

Validation: build and 36 targeted tests passed, including native button action
routing, zoom geometry and full-panel light/dark offscreen rendering
(`build/validation/native-window-controls-v1.xcresult`). Offscreen windows are
inactive, so their native traffic lights render gray as expected.

### History panel alignment (2026-10-28)

Start the white history card at the conversation title row, 50 pt below the
window's top (12 pt inset + 30 pt toolbar + 8 pt gap). The sidebar toggle stays
in the shared toolbar, centered horizontally alongside the traffic lights at
the same vertical position. Remove the old internal toolbar spacer from the
card so its content does not receive duplicate top padding. Keep the 8 pt bottom
inset and all existing sidebar widths and horizontal animation geometry.

Validation: compilation and 35 geometry/control tests passed. Light/dark panel
captures and sidebar layout assertions passed, but the full rendering test
failed its history-store release checks during teardown in both runs
(`build/validation/sidebar-title-alignment-v2.xcresult`). This is not a fully
passing test run; the retained-store cleanup failure remains unresolved.

### Compact sidebar and global search (2026-10-28)

Use a single Workspaces header with search immediately left of the plus menu.
Remove the top New conversation action, inline search field, duplicate workspace
headers, empty local-workspace onboarding copy and sidebar archive disclosure.
Archive management remains in Settings. Preserve pinned ordering and context-menu
actions, but omit pin glyphs from workspace and conversation rows.

Local conversations use 32 pt title-only rows, without timestamps or snippets.
Their title inset aligns with workspace names; the Local conversations heading
aligns with Workspaces and keeps its disclosure chevron on the trailing edge.

Search opens an independent 440 pt sheet (also Command-Shift-F). Its query never
filters or expands the sidebar. It searches non-archived local titles, questions,
answers and workspace names, plus saved Work titles, latest cached replies and
workspace names when Codex sync is enabled. Opening results preserves the existing
conversation-switching guards. Escape/Done closes the sheet; Return opens the first
available result. Search is local and does not launch inference requests.

Validation: compilation and 19 search, workspace and offscreen rendering tests
passed (`build/validation/sidebar-global-search-v2.xcresult`), including the full
panel replacement/cleanup fixture that failed during the earlier alignment run.
Inspected compact title rows and light/dark search captures; previews are saved
under `output/sidebar-search/`.

### Images above user messages (2026-10-28)

Show image attachments before the message body in both Conversation and Work.
Hide image filename captions and the nested attachment-card background; retain
names for accessibility and keep document attachment labels. Use one shared
aspect-fit preview bounded by 280 pt width and 420 pt height, with 10 pt corners.
Align previews and text to the same leading edge inside the message bubble.
Keep the original image viewer, recovery/retry behavior and explicit opt-in for
remote image loading. Raw saved messages and model inputs are unchanged.

Validation: compilation and four targeted attachment/presentation tests passed
(`build/validation/message-images-above-v3.xcresult`). The rendering fixture covers
landscape/portrait images, narrow/wide columns and light/dark appearances.

### Bottom-left account and settings (2026-10-29)

Place a 32 pt circular account avatar in a 44 pt button at the bottom of the
64 pt navigation rail, centered on the same axis as Conversation and Agent.
Remove the top-right settings gear. Clicking the avatar opens an AppKit-hosted
popover beside it, with a real account summary and a Settings row. Both rows
share the same icon and text columns. The summary opens Account settings.
Use the signed-in profile's initial when available and a neutral person glyph
otherwise; no avatar photo or plan metadata is invented.

The entry works from Conversation, Work and Agent. Opening settings from Agent
returns there through Back; selecting a navigation icon also exits settings.
Keep the shared glass and rail width intact. Validated with offscreen chat,
settings, Agent and light/dark menu fixtures: initial three tests passed, and
the final two menu/panel checks passed after alignment and contrast corrections
(`build/validation/avatar-settings-final-v3.xcresult`).

## Personal Agent contacts (2026-10-29)

- Use contacts and independent chat transcripts as the primary navigation. Remove onboarding hero prose and persistent management tabs. Rows show the shared emblem, name, one-line latest message and unread count.
- At content widths of 620 pt or more, use a 200 pt contact column beside the chat; compact windows drill into the selected chat with a back button. Do not widen the outer 64 pt rail or alter Conversation / Work geometry.
- Keep Routines, Skills, Activity and agent details behind menus. Hosting configuration lives in Settings → Work, also reachable from a compact status control.
- Cloud status describes the user's server connection. Local and self-hosted data are separate; explain persistence and switching only in Hosting settings, not throughout chat.

## Shared chat presentation (2026-10-29)

Conversation and Personal Agent use `MarrChatComponents` for composer surfaces, text input metrics, circular submission controls, stop controls and user bubble styling. Keep the 32 pt side inset, 720 pt maximum reading width, 12 pt input padding, 14 pt editor text and 1–4 visible lines in sync. Both respect the same accent/bubble preferences, focus ring, contrast, transparency and reduced-motion settings. Agent answers use the normal Markdown reading scale and shared copy actions. Keep agent-specific permissions in its toolbar; do not expose nonfunctional attachment/model controls.

Validation: shared-chat-ui-v1 passed 18 non-visible tests (8 visible-window tests intentionally skipped); the final Agent rendering/coordinator pass in shared-chat-ui-v2 passed all 4 tests. Compact and wide light/dark captures were inspected. Preview files are in `output/shared-chat-ui/`.

### Standard macOS window lifecycle and Stage Manager (2026-10-30)

The main window uses a native titled, closable, miniaturizable, resizable
NSWindow at normal level. Keep the system title-bar traffic lights in AppKit's
view hierarchy with their original actions: close the conversation window,
minimize to the Dock, and use native full-screen/zoom behavior. This supersedes
the custom toolbar controls and manual green-button frame toggle above.

Use managed, primary, full-screen-primary collection behavior so Stage Manager
and Spaces manage the main window normally. Do not join all Spaces or other
applications' stages. File pickers use sheets attached to the main window.
Full-screen sidebar toggles must not resize the system-owned window frame.

### Preserve the original traffic-light placement (2026-10-30)

Keep the traffic lights at the leading edge of the existing shared toolbar.
Use full-size content with a transparent, hidden-title native title bar and an
empty unified NSToolbar, without an extra visible header or separator. Reserve
70 × 30 pt in the content toolbar for the native button group. Let AppKit own
button spacing, views, targets, hover regions and full-screen transitions.
Do not reparent or manually reposition individual standard buttons: doing so
leaves the native group hover region at its former coordinates even when the
buttons themselves still receive clicks. Normal window level and Stage Manager
behavior remain unchanged.
