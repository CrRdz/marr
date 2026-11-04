# Welcome

Use the conversation window's native chrome, transparent backing and 24 pt glass
surface with the same 0.80 top frost. Interior cards and the practice input use
`MarrChatComposerSurface`; the send button uses the conversation's button style.
Respect the app theme, accent, bubble color, reduced transparency and motion.

Five steps: greeting, capture, practice asking, configure AI, start using Marr.
Show concise instructions in the relevant step, with one-line supporting text.
Explain the configured shortcut and scope, selection, annotation, screenshot
translation, attachments, follow-up questions, history and local workspaces.
The practice composer is explicitly a local sample and sends no request.

AI configuration stays in the welcome window. Reuse the shared connection panel
and embed its editor for ChatGPT login, API server/protocol, model IDs, credentials
and connection checks. Credentials continue to use the existing Keychain path.
Select the default connection/model explicitly; translation options are disclosed
on demand. Do not expose response limits in onboarding. Keep the setup subtree
mounted across guide steps so unsaved input survives Back/Continue; disable its
interaction and accessibility while hidden. Enter in the editor must not advance
the guide. Browser-based OAuth is still handled by the existing login flow.

Skip and final Continue explicitly finish onboarding. Window close leaves it
incomplete. Completion key v1 remains stable across this visual revision, so an
existing user is not forced through onboarding again. Menu-bar Welcome to Marr
always allows replay. Dock reopen restores a visible/minimized welcome window.

Validation covers step boundaries and completion, native window chrome, ten
light/dark offscreen layout fixtures, the embedded API editor and shared settings.
Offscreen layout captures use reduced-transparency fallback; they do not show
live wallpaper refraction. Real OAuth and paid model requests are not run by
these fixtures. Preview artifacts are in `output/welcome-preview-v2/`.
