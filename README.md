# Marr

**Capture, ask, and work with AI — right from your Mac’s menu bar.**

Marr brings screenshots, conversations, and local workspaces into a compact macOS app. Ask about what’s on your screen, translate a selected area, or organize related work. Optional Codex compatibility connects its existing projects and runtime tools.

## Download

[**Download Marr for macOS**](https://github.com/CrRdz/marr/releases/latest)

1. Open the latest release and download **Marr.dmg** under **Assets**.
2. Open the DMG and drag **Marr** into **Applications**.
3. Launch Marr from Applications. Its icon appears in the menu bar.
4. Allow **Screen Recording** when prompted to enable screenshots.

Requires **macOS 14 or later**. Liquid Glass is available on macOS 26 or later.

The current download is not notarized by Apple. If macOS blocks it, and you trust this repository’s download, use **System Settings → Privacy & Security → Open Anyway** after attempting to launch it.

## What you can do

- **Capture and ask:** select an area or a window and ask a question about it.
- **Annotate screenshots:** use the collapsible side toolbar to draw boxes, arrows, numbered markers, and freehand strokes before asking. Click a box, arrow, or number to select and drag it, or press Delete to remove it; undo drawing, movement, or deletion as needed. The toolbar automatically avoids screen edges and the question composer.
- **Collect screenshots:** pin a capture, take another, and send them together.
- **Personal Agent:** the left icon rail opens a persistent agent workspace with profiles, editable memory, separate conversations, reusable skills, local scheduled routines, approvals and run history. Execution uses the signed-in Codex runtime with an explicit file sandbox. Routines need Marr running and the Mac awake; cloud computers, third-party event triggers and connected-app tools are not implemented. The 64-point rail, existing chat layout and shared glass background are preserved. See [Personal Agent](docs/personal-agent.md) for setup, behavior and limits.
- **Conversation:** ask follow-up questions, add images or files, and revisit local history. Toggle the shared Chats sidebar with the sidebar button or **Control–Command–S**. Its first expansion widens the window when screen space permits; hiding the sidebar keeps that width, and later expansions reuse it. Browse **workspace → conversations**, collapse projects, show more chats, or search names, paths, and titles. Screenshot conversations remain in **Local conversations**.
- **Work:** create a local workspace, optionally associate a folder, and keep related conversations together. Work uses the AI connection configured in Marr. The native workspace currently works with attached content; general file and terminal tool execution is not yet implemented.
- **Optional Codex sync:** enable **Settings → Work → Sync Codex work** to browse, continue or fork Codex history and use its runtime tools. It is off by default. See the [compatibility reference](docs/codex-compatibility.md) for synchronization and supported commands.
- **Choose your model:** connect an eligible ChatGPT plan directly without an API key, or configure an OpenAI API or custom gateway connection. Codex chats use their runtime's model settings when the integration is enabled.
- **Manage local storage:** inspect actual usage in **Settings → Storage**, review or archive chats, restore archived chats, and manage local workspace names.
- **Translate and compare:** translate screenshot text into Simplified Chinese and compare it with the original.
- **Make it yours:** resize the window, change shortcuts, and choose your appearance and Liquid Glass preference.

The Chats sidebar follows the supplied Apple Notes recording: an inset rounded surface, compact folder rows without count badges, and secondary tools revealed on hover or keyboard focus. Shared window controls stay at the upper left throughout the transition. Workspace catalogs refresh in the background; a retry action appears only when syncing fails. Sidebar movement and the first window expansion use matching 240 ms transitions; conversation text keeps a stable layout while they run. Reduce Motion applies the final layout immediately. See the [compatibility reference](docs/codex-compatibility.md) for behavior and validation details.

## Get started

For **Conversation**, open **Settings → Account → ChatGPT plan connection → Continue with ChatGPT** to authorize an eligible ChatGPT plan without an API key. Marr discovers the models available to that account. See the [ChatGPT plan setup and implementation notes](docs/chatgpt-plan-usage.md).

For native **Work**, configure your AI connection in **Settings → Conversation**, then choose **New workspace**. Codex is optional: sign in through your Codex runtime and enable **Settings → Work → Sync Codex work** to connect its projects and discover its available models.

- Press **⌘⇧0** or click the menu-bar icon to capture an area and open the same bot question bar.
- Enter a question and press **Return**.
- Pin screenshots to collect more than one, use **＋** to attach files, or drag files from Finder into the conversation or workspace. Dropped files are added to the current draft as attachments.
- Switch to **Work** to create or choose a local workspace, then use its new-chat button to start a conversation.
- In a Codex chat, type `/`, `@`, or `$` to open suggestions. Use arrow keys to choose, Tab to complete, Return to run a command or insert a reference, and Escape to dismiss. Shift-Return adds a line.
- In a Codex chat, use `/plan` to enter Plan mode, `/default` to leave it, or `/goal` to edit a persistent task goal. `/default` is a Marr extension.
- With Codex sync enabled, open **Settings → Work** (or `/skills`, `/plugins`, `/apps`, `/mcp`) to browse and enable skills, manage supported plugins, inspect apps, or reconnect an MCP server. Available features follow the selected Codex runtime and account.
- Open **Settings** to change shortcuts, appearance, your default model, or translation settings.

Work messages show user text and attachments together. Local images display thumbnails; click to open the viewer, or use the context menu for the file location. Attachment paths and recognized runtime envelopes stay out of the message body. Remote image previews load on request.

Conversation supports images, text files, and text-based PDFs. Other document formats may need exporting first. Screenshot translation uses the default AI connection configured in Conversation. In **Settings → Translation**, select **Separate API** to use an independent ChatGPT plan, custom API, OpenAI API, or DeepLX connection. These choices are saved across restarts.

Codex chats share the selected runtime's skills, configuration, login, and available integrations. Desktop-only tools, cloud Work services, and interactive plugin applications require their supporting host; they are not automatically provided by the CLI. See the [compatibility reference](docs/codex-compatibility.md) and [complete CLI command audit](docs/codex-cli-command-audit.md) for supported behavior and current boundaries. Unsupported commands are marked in the menu and preserve the draft.

Settings opens directly on Capture, with a narrow Liquid Glass icon sidebar that stays visible at the normal window size. Hover an icon to see its category; the current category appears in the window title. Search by feature name to find a setting. Theme previews and color swatches show appearance choices directly. Escape or the back gesture first clears search, then closes settings. The top-right return button closes settings directly. Reopening settings in the same panel retains the selected tab and clears the search.

## Your data

Local conversations and workspace associations are stored in SQLite; attachments are saved beside the database. **Settings → Storage** shows the actual folder and usage breakdown, with controls to archive, restore, or delete chats. Removing a local workspace keeps its chats and its linked folder. Content you submit is sent to the AI service used for that request.

Codex sync uses the runtime's APIs to read and update Codex chats. Marr does not edit Codex's database directly. Codex tools can access and modify the selected project subject to their approval settings; a native Marr workspace currently organizes conversations and attached content. See [local workspaces and storage](docs/local-workspaces-and-storage.md) for locations, storage categories, and current boundaries.

## Feedback

Found a bug or have an idea? [Open an issue](https://github.com/CrRdz/marr/issues).

## Development checks

Source files and Xcode groups are organized by feature. See the [source structure](docs/source-structure.md) and [independent Swift modules](Packages/MarrModules/README.md) before adding a feature. Text parsing, highlighting and diff processing live in `MarrText` and can be tested without launching the app.

Run `python3 scripts/check-code-quality.py` to check source naming, file-size budgets and architectural boundaries. See the [code quality review and extension guide](docs/code-quality-review.md) for component ownership, compatibility constraints and remaining refactoring work.

UI changes follow the [Marr desktop design system](design-system/marr/MASTER.md): shared text/icon roles, warm-neutral surfaces, control metrics and row-local interaction state. Use `MarrIcon` and the `MarrUI` / `MarrTypography` tokens rather than inventing per-screen sizes. Generated icon sources and packaging instructions live in [DesignAssets/MarrIcons](DesignAssets/MarrIcons/README.md).

Run `scripts/test-marr.sh` for the default local suite. It builds the app and runs logic, protocol, persistence, and offscreen rendering tests without opting into visible windows or global hotkeys. Tests that require an active desktop are reported as skipped. Additional XCTest filters can be passed after the script name.

Run `swift test --package-path Packages/MarrModules` for the package tests. Live API and external-corpus tests keep their separate opt-in requirements.

On an available desktop, `scripts/test-marr.sh --ui` also runs the window, focus, input, and visual fixtures. This mode intentionally activates windows; CI uses it on the dedicated macOS runner. Do not use it while working in other apps.

Debug builds provide **Component Gallery (Debug)** in the menu-bar context menu. Open it explicitly to inspect production components in light/dark appearance, narrow layouts, and accessibility modes; it never opens automatically.
