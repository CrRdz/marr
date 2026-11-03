# ChatGPT plan usage in Marr

Marr can use a user's eligible ChatGPT plan directly for **Conversation**, native **Work** chats, and screenshot translation. Optional Codex chats use their own runtime and account.

## Use it

1. Open **Settings → Account → ChatGPT plan connection** and choose **Continue with ChatGPT**.
2. Complete the authorization in your system browser and return to Marr. Eligibility and the granted permissions are determined by OpenAI.
3. When plan permission is granted, use the model button in the Conversation or native Work composer to choose an account-specific model and a supported reasoning level. The compact panel leads with a left-aligned model row; click it to reveal the model list. A compact glass lightning button sits beside the model, with reasoning and the original native tick slider below. Its native tick slider includes **Automatic**, which leaves the effort to the model. The same panel appears in **Settings → Conversation**. For supported models, the lightning button beside the model switches between Standard and Fast; the combined composer button reflects that state. Controls use Marr’s neutral surfaces, shared icons and type scale. The speed indicator follows the chosen accent; the slider retains its system glass appearance, tick marks and keyboard behavior. Fast uses more plan allowance. Reset restores Automatic and Standard. The first successful connection enables ChatGPT plan use for Conversation.
4. For an independent translation configuration, select **ChatGPT plan** in **Settings → Translation** and choose its model. Translation using the default AI connection follows Conversation's provider.
5. Manage sign-in and registrations in **Settings → Account**. **Manage usage** opens <https://chatgpt.com/settings/usage>. **Add account** creates a separate registration; the account actions menu contains reconnect, refresh and sign-out. Saved registrations can be selected or reauthorized independently.

An identity-only sign-in remains saved but cannot perform inference. Choose **Enable ChatGPT plan usage** to request consent again. Signed-out registrations retain their client IDs so reconnecting does not create new clients. Account changes wait for active Conversation/translation requests to finish.

## Implementation

- `ChatGPTAuthorization` creates fresh cryptographic state, nonce, and S256 PKCE values. Initial registration uses `dynamic_agent_client`, the fixed app name `Marr`, and a persisted installation host ID. Reauthorization reuses the issued client ID.
- `ChatGPTLoopback` binds exclusively to `127.0.0.1` on an available port at `/auth/callback`, before opening the browser. The exact redirect URI is reused for code exchange. Requests are bounded in size and duration, invalid state is rejected, and cancellation closes the listener.
- `ChatGPTIdentityVerifier` verifies RS256/ES256 signatures against OpenAI's JWKS and validates issuer, audience, authorized party, expiry, issued-at time, and the login nonce. Returning registrations must match the previously verified subject and issuer.
- `ChatGPTSession` owns registrations, granted scopes, identity, expiry, and rotating tokens. One atomic Keychain record prevents mismatched token/expiry updates. The Keychain item is accessible only when the device is unlocked and is device-local. No OAuth token is stored in UserDefaults or sent to the Codex runtime.
- An owner-only Application Support lock file contains no credentials. An OS advisory lock permits only one Marr runtime to own rotating tokens at a time; another process fails explicitly instead of racing a refresh. A crashed process releases its lock automatically.
- Concurrent refreshes in the runtime share one task. Refresh omits `scope` and uses the issued client ID. Terminal refresh errors clear tokens while retaining registration and identity. Temporary errors preserve the session.
- Logout discovers OpenAI's revocation endpoint, attempts revocation, and clears access, refresh, and ID tokens. If revocation cannot be confirmed, the UI says so and directs the user to ChatGPT settings.
- Models come from the authenticated `/v1/models` catalog, preserving ordering and filtering `visibility == "list"`. Model slugs, not display names, are sent to inference. Each registration persists its own catalog with a timestamp. Calls within five minutes reuse it; concurrent fetches share one request. Settings and the composer immediately display saved choices while stale catalogs refresh in the background, without locking controls. A temporary refresh failure retains the saved list and exposes Retry. Manual account refresh bypasses the freshness interval. Sign-out, reauthorization and loss of plan permission invalidate the corresponding catalog.
- Sending a message uses an available saved catalog rather than waiting for an extra catalog request. The actual Responses request still validates and refreshes OAuth credentials; a catalog never grants access. With no saved catalog, the initial lookup is required.
- The composer retains its model and reasoning button for ChatGPT plan use. An explicitly selected level is saved locally and sent as `reasoning.effort` in the Responses request; Automatic omits that field. A model change clears a level the new model does not support. Available levels use catalog metadata when present, with a conservative list for known reasoning models.
- The composer model entry opens a searchable model list directly. Search stays fixed at the bottom beneath the reasoning slider and speed control, while results scroll above it. Choosing a model closes the menu and returns to the draft; choosing the current model preserves its effort. Arrow keys select available results, Escape returns to the editor, and IME confirmation does not select a model. The model control expands into the menu in the same window and returns to its source bounds on dismissal. The plus reveals inline attachment actions before More context. These controls share one active menu and preserve the editor and draft throughout transitions.
- Speed is a persistent, off-by-default choice integrated into the model control and its configuration panel. Eligible Fast requests send `service_tier: "fast"`; Standard mode omits the field. Switching to an unsupported model turns the choice off. The UI describes Standard and Fast without promising a fixed speed multiplier.
- The OAuth provider pins requests to `https://api.openai.com/v1/responses`, discards custom destinations/headers, disables HTTP redirects, sends `store: false` and `stream: true`, and requires a `response.completed` event. It never silently falls back to an API key, gateway, or nonstreaming request. The plan path does not send the custom provider's output-token limit.

The macOS app includes the network-server sandbox entitlement for its short-lived loopback callback. The listener itself binds only to IPv4 loopback.

## Verification

```sh
swift test --package-path Packages/MarrModules
xcodebuild -project Marr.xcodeproj -scheme Marr -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

OAuth tests use generated signing keys, fake token responses, isolated in-memory storage, and a real local callback listener. They do not contact OpenAI or read a user's credentials. Tests need permission to listen and connect on loopback.

For a real-account smoke test, complete the browser flow with an eligible account, select a discovered model, ask Conversation to respond with a short fixed phrase, and verify the completed answer and the ChatGPT usage settings. Real-account eligibility, live consent, and serving-region policy cannot be established by mock tests.

## Official references

- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Reasoning effort](https://developers.openai.com/api/docs/guides/reasoning)
- [Fast mode in Codex](https://developers.openai.com/codex/speed)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [UI/UX guidelines](https://developers.openai.com/siwc/ui-ux-guidelines)
