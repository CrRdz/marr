# Marr — glass object studies

A standalone Rive design exploration with substantial foreground objects, now matched to the mascot’s smoky-gray / pearl-white glass material language. This project is separate from the current application's `MarrCompanion.riv`.

## Direction

- **Translation / reading:** the glass companion reads behind an open dictionary made of layered frosted glass. The book masks its lower body; eye movements follow the page and a small native page curl provides motion.
- **Recognition / inspection:** a dimensional magnifying glass moves over a physical book page. It is placed over the text, away from the companion's face.
- **Writing / organizing:** the companion looks down behind a miniature frosted-glass laptop. The lid occupies the foreground and conceals the lower body.

All three keep the glass material and two native animated eyes, with no mouth. Props have their own transform hierarchy and do not move rigidly with the face.

## Shared material language

- Smoky gray shading, pearl-white frosting, broad soft white highlights and restrained icy-blue edge refraction.
- The book retains curved leaves and a spine, with softly etched text grooves instead of printed ink or fabric.
- The laptop retains its physical lid/base and enough frosted opacity to occlude the companion behind it.
- Native Rive page-turn geometry now uses translucent cool glass shading with a fine refractive edge.
- The magnifier uses a beveled glass rim, translucent handle and subtle moving specular highlight; there is no gold or green metal.
- Charcoal stages and neutral cool-gray text provide a consistent backdrop.

## Assets and source

- `assets/open-book-glass.png`: imagegen glass-material edit of the original book, 1808 × 870 RGBA.
- `assets/laptop-glass.png`: imagegen glass-material edit of the original rear-view laptop, 1585 × 992 RGBA.
- [Glass-book prompt and provenance](assets/book-glass-provenance.md).
- [Glass-laptop prompt and provenance](assets/laptop-glass-provenance.md).
- Both glass variants were edited with the built-in imagegen tool, using the approved logo as the material reference. Generated pixels and alpha are preserved unchanged; original warm-paper and metal assets remain alongside the new variants.
- The approved eyeless glass-body asset is reused. Eyes, magnifier, page motion and scene layout are native Rive objects.
- `../../scripts/package-marr-object-studies.py`: deterministic authoring.
- `../../scripts/render-marr-object-preview.py`: native Rive recording to GIF/MP4; no raster compositing.

## Preview

The project contains **Marr object studies** (three scenes) and **Translation detail** (large reading scene), each with a six-second looping timeline.

```sh
python3 scripts/package-marr-object-studies.py
RIVE_HOME=/tmp/marr-rive-tools /tmp/marr-rive-tools/bin/rive DesignAssets/MarrObjectStudies --verify
RIVE_HOME=/tmp/marr-rive-tools /tmp/marr-rive-tools/bin/rive DesignAssets/MarrObjectStudies
python3 scripts/render-marr-object-preview.py --output output/marr-glass-object-preview
```

Rendering requires the locally installed Rive CLI and Metal access; video export requires ffmpeg. Current glass-material outputs live under `output/marr-glass-object-preview`: `marr-objects.gif/.mp4/.png` and `marr-reading.gif/.mp4/.png`. These are preview recordings; the authored motion is in the native `.riv` file built from this project.

## Validation

Rive CLI verification: zero errors and warnings. Both artboards have a native state machine and a six-second animation. All authored object IDs are unique. The compiled `build/MarrObjectStudies.riv` has a valid RIVE header. Foreground occlusion and the page-turn midpoint were visually checked in actual native renders; both GIF/MP4 exports contain 72 frames at 12 fps. The original book/laptop images and current production app are unchanged. Earlier physical-material previews and a saved `MarrObjectStudies-v1.riv` remain under `output/marr-object-preview`.
