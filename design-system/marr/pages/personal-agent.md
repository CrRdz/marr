# Personal Agent workspace

Inherits the Marr master design system. The UI/UX skill's initial search returned
a marketing layout, and its narrower desktop-assistant query had no match.
No generated template was adopted: this page uses the established Marr desktop
tokens and general native interaction guidance.

- Keep the 64-point main rail and one shared outer glass surface. Preserve the
  0.80 frost overlay and existing gradient stops.
- Reserve the first 52 points for window controls/dragging. The workspace header
  uses the existing soft blue star; agent tint choices are blue, mint and lilac.
- Four compact tabs: Agents, Routines, Activity, Skills. A selected agent opens
  its conversation within the same pane, with a back button and details editor.
- Use flat, lightly filled cards; do not introduce glass effects on every row.
  Keep scrollable content separate from the fixed composer.
- File access, time zones, limits and pending decisions are visible settings.
  Do not show fabricated activity, connected services or cloud availability.
- All actions are native Buttons/Toggle/Picker controls with keyboard semantics.
  Shared color/spacing/type tokens determine light and dark appearances. The
  feature's stateless button style avoids hover animation lifetime coupling to
  a hidden/closing panel, keeps pressed feedback and draws a focus outline.
- Only the active agent surface is mounted. Drafts and selected tab/agent live
  outside it while Marr is running, so hidden keyboard shortcuts cannot capture
  Conversation input. Background execution belongs to the coordinator.
- Approval/question cards include the runtime's request, an explicit one-time
  response and decline. Disable responses while submitting a decision or stopping.
- Unread results/requests add a small rail dot and an accessible count. A routine
  reporting NO_UPDATE remains in Activity without producing an unread dot.

Offscreen visual checks cover all four tabs and a populated conversation in both
appearances at 484 × 596 points. These captures verify layout and contrast;
wallpaper compositing remains a live-window property of the shared glass.
