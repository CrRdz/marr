# OpenLens

Ask AI anywhere on your screen.

OpenLens is an early-stage macOS app concept for selecting any area of the screen and asking AI questions about it directly.

## Conversation harness

OpenLens uses a structured multimodal conversation harness rather than flattening chat history into a prompt string.

- `ConversationSession` owns turns, immutable screenshot assets, pending attachments, retries, and UI-observable state.
- `ConversationContextBuilder` compiles successful turns into role-preserving messages with text, turn, and image budgets.
- Screenshots belong to the user turn that introduced them. Adding a screenshot never replaces an earlier asset.
- Long conversations automatically reattach the most recent screenshot when trimming would otherwise remove all visual context.
- `VisionAIClient` receives a provider-neutral `VisionRequest`; `OpenAIClient` encodes it as OpenAI Responses or Anthropic Messages payloads.
- Failed turns remain visible and can be retried with the same structured context.

Run the harness tests with:

```sh
xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -derivedDataPath /tmp/OpenLensDerivedData CODE_SIGNING_ALLOWED=NO test
```
