# Tool activity cards

The collapsed card uses a 36 pt summary row and an 8 pt corner radius. A 12 pt
medium title sits on the left; the 11 pt regular status, monospaced duration and
disclosure arrow sit on the right. The timeline already identifies the tool, so
the card does not repeat its icon. The entire header is a native button, with
hover feedback and reduced-motion-aware expansion.

Command text, source, working directory, output, parameters and event data remain
in the expanded content. Nested disclosures retain their native presentation.
The protocol state derivation is unchanged.

| State | Meaning |
| --- | --- |
| Needs your input | A matching interaction is pending. |
| Running | Execution is incomplete and its status is known. |
| Status unknown | Execution is incomplete and its status is uncertain. |
| Succeeded | The event explicitly reports success or exit code zero. |
| Finished | The item is complete without an explicit success or failure result. |
| Failed | The event reports an error, failure or nonzero exit code. |
| Cancelled | The event reports cancellation, interruption or decline. |

Expanded and collapsed are interaction states, separate from these seven execution
states. Preview fixtures use actual `MarrToolActivityCard` instances in offscreen
native windows, at 360 and 720 pt widths in both appearances.

Validation on 2026-10-25: all 11 `MarrToolActivityTests` passed, including the four
offscreen captures. The app and test target compiled successfully; no visible
application windows were opened. Results: `build/validation/tool-states.xcresult`.

Historical preview images were removed during repository cleanup. The offscreen
tests can generate fresh captures when needed.
