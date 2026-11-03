# Local workspaces and storage

Marr's native Conversation and Work use the AI connection configured in **Settings → Conversation**. They work independently of Codex. Create a workspace from **Work** or the sidebar, give it a name, and optionally choose a folder. Chats in that workspace keep their history and attachments locally.

The current native workspace organizes conversations and supplied attachments. Associating a folder does not upload or index its contents, and does not provide a general file-editing or terminal executor. Attach the content you want the model to use. General agent tool execution remains a separate implementation step.

## Storage location

Open **Settings → Storage** for the exact storage folder on your device. **Show in Finder** reveals it; **Refresh** measures its current contents. Marr runs without App Sandbox. Existing installations continue to use their original sandbox storage directory in place:

```text
~/Library/Containers/com.marr.Marr/Data/Library/Application Support/Marr/
├── marr.sqlite                 Conversations, turns and workspace associations
├── marr.sqlite-wal             SQLite write-ahead log, when present
├── marr.sqlite-shm             SQLite shared-memory file, when present
├── Attachments/                Saved conversation attachments
├── WorkAttachments/            Runtime attachments and composer drafts
│   └── ComposerDrafts/
├── Workspaces/                 Marr-owned workspace data, when present
└── History/                    Legacy history, when present
```

Fresh installations use `~/Library/Application Support/Marr/`. If the old sandbox storage directory exists, Marr consistently uses it, preserving SQLite WAL/SHM files and absolute attachment paths without copying or merging databases. The first production launch imports missing settings from the old sandbox preferences plist once; existing new settings win and the old plist is retained. API and plan credentials keep their existing Keychain service identities. The displayed path is authoritative. Choosing a workspace folder associates that folder with a workspace; it does not relocate Marr's database. The app does not currently offer a storage-root relocation setting.

SQLite stores chat text, turn order, attachment references, workspace names and associations, and archive state. Attachment bytes remain in separate files. Writes use transactions, foreign keys, write-ahead logging, and full synchronization. Existing local history is migrated on load; legacy history files can remain and contribute to storage usage.

## What the storage view counts

The bar and legend use measured logical file sizes under Marr's storage folder. The total is not the size of the application bundle or the total usage of the computer. Shared physical files are counted once; symbolic links are not followed.

| Category | Contents |
| --- | --- |
| Chat database | `marr.sqlite` and its WAL/SHM files; includes active and archived chat text and workspace metadata. |
| Attachments | Saved attachment files that are not exclusively associated with archived chats. |
| Archived attachments | Saved attachments referenced exclusively by archived chats. |
| Workspace data | Files under Marr's own `Workspaces/` directory. A linked external project folder is excluded. |
| Other | Other files under Marr's storage root, including composer drafts, runtime attachment copies, caches, and retained legacy data. |

The chat count includes archived chats; the archived count is shown separately. Archive operations do not move chat text into a different database, so the archive count and archived-attachment bytes measure different things. Native workspace creation currently adds metadata and an optional folder association, so **Workspace data** can correctly remain at zero bytes.

External project folders, Codex's separate runtime history, and user worktrees are excluded. Storage refresh reports files it cannot measure instead of silently claiming a complete result. It performs no automatic cleanup.

## Managing chats and workspaces

- **Archive** hides a chat from the regular local history list and preserves its content. Open **Settings → Archives** or **Storage → Archived chats** to view, restore, or explicitly delete it.
- **Delete** requires a confirmation and removes the local chat and its saved attachments. It does not delete an external project folder or a Codex chat. Storage changes wait until active inference requests finish.
- **Rename workspace** changes its local display name. The folder stays in place.
- **Remove workspace** requires a confirmation, moves its chat associations back to Conversation, and preserves the chats and linked folder.

Storage usage can change while SQLite checkpoints or drafts are saved. Deleting rows does not guarantee that the database file immediately shrinks, so refresh the measured total rather than estimating freed space from chat counts.

## Optional Codex compatibility

**Settings → Work → Sync Codex work** is off by default. Enabling it connects Codex's project catalog, history, account and runtime capabilities. Turning it off leaves Marr's local workspaces and conversations available and stops Codex synchronization. Native chats continue using Marr's configured AI connection.

Codex reads and updates go through its app-server protocol, such as `thread/read`, `thread/name/set`, `thread/archive`, and `thread/unarchive`. Marr also keeps its own navigation and display state. It does not directly modify Codex's database to rearrange or update chats.

Codex runtime tools retain their own permissions and approvals. Their available skills, integrations and capabilities depend on the selected runtime and account. Local Marr archives and Codex archives are presented separately. For polling behavior, supported operations and host-specific limits, see [Codex compatibility](codex-compatibility.md).

ChatGPT plan authorization and remote response retention do not replace this local history store. Marr's workspace organization, drafts, attachments and ability to revisit saved chats remain app-owned responsibilities.

## Validation for this change

- The macOS debug app and test bundle build successfully.
- All 120 Swift package tests pass, including SQLite migration, storage accounting, stale-save protection and mocked OAuth flows.
- Workspace, storage, Codex compatibility, history, draft, navigation and translation-routing app suites passed 199 tests; seven visible-window cases were intentionally skipped. The updated general-conversation title test passed separately. New storage and workspace views were checked in offscreen light/dark and narrow-width renders.
- The expanded app run also reported two translation-rendering failures: `testTranslationRendererMovesTrailingBadgeNextToShorterTranslation` and `testTranslationRendererUsesSourcePixelsInsteadOfApproximateDarkMetadata`. The translation renderer was not changed as part of this workspace/storage implementation; this is not a claim that the complete app regression suite is green.
