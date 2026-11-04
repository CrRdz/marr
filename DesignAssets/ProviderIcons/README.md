# Provider marks

Bundled SVG marks in `Marr/Assets.xcassets/Provider-*.imageset` come from
https://models.dev/logos/{provider}.svg (retrieved 2026-10-28).
Provider IDs: openai, anthropic, google, deepseek, openrouter, moonshotai, xai, ollama.
The marks identify their respective providers; they do not imply endorsement.
They are rendered as monochrome template vectors for native light/dark appearances.

Configuration design reference: https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/providers.mdx
Catalog reference: https://models.dev/api.json

Provider identity, protocol, endpoint and model ID are separate. Named API
providers have separate Keychain entries and saved endpoint/model profiles.
Custom and legacy CC Switch retain their existing credential storage for compatibility.
Model IDs in the menu are editable examples, not a live availability guarantee.
Google uses its OpenAI-compatible endpoint; Ollama requires an installed local model ID.
API providers power Conversation and default translation. Workspace tool execution
continues to use the existing Codex runtime; no additional agent SDK is bundled.
