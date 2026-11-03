# Marr — quiet companion and living tools

The original `Marr Companion` artboard has five visual states. The approved glass silhouette and two eyes remain; decorative props, badges, mouths and celebratory symbols have been removed from the production animation.

## Living tool forms

Applied on 2026-11-01: the functional study's pencil and translation window
are now the production forms. The approved selection form is unchanged.
The pencil becomes a barrel and writing tip, then draws a short stroke;
the translation window demonstrates `Hello` → `你好`. These words and the ink
trail are decorative tool illustrations, not actual user content or completion
signals. Task progress is still driven independently by `phase` and `scan`.
The pen timeline lasts 1.3 s and translation 1.5 s; Reduce Motion advances the
tool layer to its final pose before pausing. Other forms retain their timing.

`scripts/package-marr-companion.py` applies the functional authoring pass from
`scripts/preview-marr-functional-tools.py` after generating the shared geometry.
Authoring requires Python fontTools and macOS STHeiti Light; the demo words
are exported as paths, so the application needs no font dependency.
The accepted demonstration is `output/marr-functional-tools-study/functional-tools.gif`.
Validation: `build/validation/rive-functional-applied.xcresult` and
`build/validation/rive-functional-applied-signed-release.log`.

`Marr Tool` adds six editable vector-glass silhouettes: orb, pen, translation,
rectangle, arrow and number. Its `tool` number property is 0…5 in that order.
A separate state-machine layer keeps the rounded body and two eyes through
every tool form. The pen and translation forms now use the functional design
described above; selection,
pointing and numbering retain the same character anatomy.

Each native 700 ms timeline gathers the body, extends the functional shape,
then settles with a restrained overshoot. The face anticipates the direction;
reflections follow two frames behind. Interruptible transitions blend into
the next gesture in 120 ms; returning to the orb blends over 420 ms. Details
fade in and remain clipped inside the changing silhouette. There are no image
swaps in this artboard. This is a stylized vector glass material.

Screenshot controls preview forms after 110 ms of hover/focus and retain the selected form
when collapsed. Translation processing uses the translation form. The original
quiet artboard, other companion surfaces and the app icon remain available.
Pass `form:` to `MarrCompanion` to opt into the tool artboard. Shape and task
activity are independent, and Reduce Motion resolves the final shape directly.

Authoring: `scripts/package-marr-tool-morphs.py`, invoked by the base generator.
Historical v2 preview: `output/marr-tool-morphs-v2/marr-tool-morphs.gif`; native `.riv`, MP4,
key poses and actual toolbar recording are beside it. The debug gallery exposes
both Shape and State. Validation results for this revision are recorded in
`output/marr-tool-morphs-v2/README.md`.

## Visual language

- **Waiting:** an almost still presence, a small breath and one blink per six-second cycle.
- **Observing:** slight attentiveness; the eyes look toward the actual screenshot selection or viewed content.
- **Processing:** stable outline, two soft interior light shapes moving slowly, a restrained thoughtful gaze. OCR adds a subtle moving recognition light inside the upper hemisphere.
- **Settled:** the light fades into alignment and the body quietly returns to rest. Plays once.
- **Attention:** a small tilt and asymmetric eyelids. Plays once; native text still explains the problem.

No new bitmap was generated for this revision. The internal light, eye transforms and all motion are native Rive geometry/keyframes. They suggest glass light movement rather than simulating physically exact refraction.

## Native contract

Artboard: `Marr Companion`. State machine: `Companion`. View model: `MarrCompanion`.

| Number property | Values | Meaning |
| --- | --- | --- |
| `phase` | 0 waiting, 1 observing, 2 processing, 3 settled, 4 attention | Five native visual states |
| `gazeX` | −10…10 | Additive horizontal eye offset, in native artboard units |
| `gazeY` | −8…8 | Additive vertical eye offset; positive points downward |
| `scan` | 0…1 | OCR recognition-light strength within processing |

The previous 29 business/study enum values remain compatible in Swift; `MarrCompanionPhase.mood` maps them to this five-state native contract. **Do not pass an old business raw value directly to the Rive `phase` property.**

Typical workflow: selecting → observing; recognizing/translating/rendering → processing; success → settled; errors → attention. Comparing, annotation and pinned-result interaction use observing. OCR enables `scan`; other processing activities leave it off.

The application drives changes from real operations. The animation never decides whether an operation has succeeded.

## Actual content direction

`MarrCompanion(phase:size:gaze:)` accepts a normalized `CGPoint` direction (−1…1). The player validates finite values, clamps the range and converts it to native offsets.

- Screenshot prompt eyes follow the active drag point, selection center or hovered window.
- Selection-only hints and standalone window capture also point toward the relevant content.
- Translation result eyes point toward the real result or original comparison window. Moving over either image or selecting linked text updates their target; window movement recalculates the screen-space direction.
- AppKit's upward Y axis is converted to Rive's downward axis.
- Reduce Motion disables gaze following and resolves a static expression. Hidden/occluded windows pause. The original static logo remains the loading/error fallback for this decorative component.

## Chat / Work composer companion

The 88 pt companion above the empty Chat composer and Work landing composer
uses `followsPointer: true`. The navigation rail keeps its static app icon.
Window-wide pointer gaze is smoothed at 30 Hz with radial limiting and correct
screen-to-artboard Y conversion. The authored face is centered; horizontal gaze
ranges from −10 to +10 units, vertical gaze from −8 to +8.

`MarrCompanionPersonality` adds a live reaction layer: eyes lead a damped body,
stationary pointers trigger small exploratory glances and a curious head tilt,
and approaching within 80 screen points produces a small lift and wider eyes.
The character keeps breathing and looking around while idle. Host-driven blinks
have 3.2–6.8 second gaps with occasional double blinks, layered over the native
idle timeline. View-model properties `bodyX`, `bodyY`, `bodyTilt`, and `eyeOpen`
control actual Rive nodes around a centered pivot; no bitmap frame swapping.
Only the hero artboard uses these reaction nodes, keeping tool contours stable.
Hidden views stop their timer; Reduce Motion restores the neutral pose and pauses.

Preview: `output/marr-personality-preview/marr-personality.gif` renders a
six-second scripted pointer journey using samples from the same Swift driver
and the native Rive renderer. It is a character demonstration, not a recording
of the application window.

## Source and preview

- `scene.rml` / `rive.yaml`: original quiet artboard plus the six-form vector tool artboard.
- `assets/glass-body.png`: approved eyeless glass layer, embedded for offline use.
- `../../scripts/package-marr-companion.py`: deterministic native authoring.
- `../../Marr/Resources/MarrCompanion.riv`: production file with both artboards.
- `../../Marr/DesignSystem/MarrCompanion.swift`: business-to-visual mapping and runtime adapter.
- `../../scripts/preview-marr-quiet.py`: native demonstration project and recordings.

Debug Component Gallery → Capture companion shows six shapes, five moods, a Reading text toggle for processing, and Replay animation.

```sh
python3 scripts/package-marr-companion.py
RIVE_HOME=/tmp/marr-rive-tools /tmp/marr-rive-tools/bin/rive DesignAssets/MarrCompanion --verify
RIVE_HOME=/tmp/marr-rive-tools /tmp/marr-rive-tools/bin/rive DesignAssets/MarrCompanion --once
cp DesignAssets/MarrCompanion/build/MarrCompanion.riv Marr/Resources/MarrCompanion.riv
python3 scripts/preview-marr-quiet.py --render
```

Rive CLI 1.8.0 authors the asset; the app uses pinned RiveRuntime 6.29.0. Rendering previews requires Metal and ffmpeg. Runtime use requires neither the CLI nor a Rive account.

`output/marr-quiet-preview/marr-quiet-flow.gif` is a sixteen-second example using the actual production state machine and inputs, with presentation-only labels. Its timing is illustrative; real operations determine app timing. `marr-quiet-states.gif` compares five native timelines. `preview.command` opens a live native processing preview.

Earlier source and binary backups are in `output/marr-quiet-preview/.archive`. The older personality, translation-prop and physical-object studies remain separate design explorations; they are not the current production visual language.

## Original quiet-artboard validation

- Native CLI build/verify: zero errors/warnings; exactly five animation states and five timelines, unique object/property tracks and in-range keyframes.
- Eight companion tests passed: business mapping, all native property writes, instance isolation, cancellation, gaze bounds/Reduce Motion, and actual Metal rendering of five distinct moods plus recognition light and directional gaze (`build/validation/rive-quiet-tests.log`).
- One visible synthetic translation integration test passed: pin/compare controls remain clickable and comparison gaze points toward the actual original window with correct Y direction (`build/validation/rive-quiet-ui-tests.log`).
- Native flow and state-sheet previews were rendered and visually checked.
- Release build and strict recursive code-signature verification passed; the bundled `.riv` matches the verified production asset (`build/validation/rive-quiet-release.log`).

## Image generation provenance

Tool: built-in `image_gen` (not API/CLI fallback).

Input: approved `DesignAssets/MarrAppIcon/glass-companion.png`.

Generated original: `/Users/crzhu/.codex/generated_images/01a18e47-58a2-75e3-b1b4-c00e5182d0cb/exec-6c4a2907-8119-4c27-8e6b-bfc4a6c77c7a.png`; copied into `assets/glass-body.png` for reproducible local builds.

Final prompt:

> Use case: precise-object-edit. Asset type: separate background body layer for a Rive animated mascot. Edit target: the supplied approved Marr app icon, a smoky gray to white translucent glass sphere. Make exactly ONE change: remove the two dark oval eyes completely, seamlessly reconstructing the glass shading behind them. Preserve the same sphere silhouette, scale, center, camera, smoky gray upper hemisphere, pearl-white lower hemisphere, specular reflections, delicate blue rim, internal translucent material, and all transparent exterior padding. Do not add any facial features, limbs, objects, symbols, shadows outside the sphere, text, or background. The result must be a single eyeless glass sphere on genuine transparency, aligned like the input, suitable for overlaying independently animated eyes. This is an animation layer, not a redesigned logo.
