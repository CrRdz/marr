# Marr

Ask AI anywhere on your screen.

Marr is an early-stage macOS app concept for selecting any area of the screen and asking AI questions about it directly.

## Conversation harness

Marr uses a structured multimodal conversation harness rather than flattening chat history into a prompt string.

- `ConversationSession` owns turns, immutable screenshot assets, pending attachments, retries, and UI-observable state.
- `ConversationContextBuilder` compiles successful turns into role-preserving messages with text, turn, and image budgets.
- Screenshots belong to the user turn that introduced them. Adding a screenshot never replaces an earlier asset.
- Long conversations automatically reattach the most recent screenshot when trimming would otherwise remove all visual context.
- `VisionAIClient` receives a provider-neutral `VisionRequest`; `OpenAIClient` encodes it as OpenAI Responses or Anthropic Messages payloads.
- Failed turns remain visible and can be retried with the same structured context.

## Local history

Every conversation is saved inside the app sandbox under `Application Support/Marr/History`.

- `conversation.json` stores turn text, status, timestamps, and image references.
- Original PNG/JPEG bytes are stored once in the conversation's `images` directory.
- The menu-bar History entry opens a resizable window with conversation and screenshot details.
- Deleting a conversation removes both its manifest and stored screenshots.
- API keys, gateway credentials, custom headers, and connection settings are never written to history.

Run the harness tests with:

```sh
xcodebuild test -project Marr.xcodeproj -scheme Marr -destination 'platform=macOS' -derivedDataPath /tmp/MarrDerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```
