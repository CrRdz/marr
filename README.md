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

## Architecture

The app target is intentionally thin around reusable local Swift packages:

- `MarrCore` contains provider-neutral conversation, history, and inference contracts. It has no UI, networking, database, or Keychain dependency.
- `MarrNetworking` depends only on `MarrCore` and owns HTTP payloads, endpoint construction, provider response validation, truncation detection, and transport injection.
- `MarrPersistence` depends only on `MarrCore` and owns SQLite records, attachment files, legacy migration, and database/filesystem rollback.
- `MarrSettings` depends only on `MarrCore` and owns inference configuration persistence. Secrets are stored in Keychain; non-secret preferences use UserDefaults.
- The app target owns macOS presentation and orchestration. Screenshot translation is separated into overlay, recognition, layout, and rendering files; its history adapter only publishes repository results to the UI.

This keeps dependency direction one-way: `Marr app → MarrNetworking / MarrPersistence / MarrSettings → MarrCore`. Feature packages never import the app target or one another, so the graph has no reverse dependency or cycle.

## Local history

Every conversation is saved inside the app sandbox under `Application Support/Marr`.

- `marr.sqlite` stores turn text, status, timestamps, pending attachments, and image references.
- Original PNG/JPEG bytes are stored once in `Attachments`; failed saves roll back newly created files, and deletes restore database rows if attachment staging fails.
- Legacy `History/<conversation>/conversation.json` records are migrated into SQLite on load.
- The menu-bar History entry opens a resizable window with conversation and screenshot details.
- Database and filesystem work runs through a serialized background repository so it does not block the main actor.
- API keys, gateway credentials, and custom headers are stored in Keychain and are never written to history or UserDefaults.
- Provider, endpoint, model, API format, authentication scheme, and maximum output tokens persist across launches.

Run the harness tests with:

```sh
xcodebuild test -project Marr.xcodeproj -scheme Marr -destination 'platform=macOS' -derivedDataPath /tmp/MarrDerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Run package-level tests with:

```sh
swift test --package-path Packages/MarrModules
```
