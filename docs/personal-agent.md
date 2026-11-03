# Personal Agent in Marr

Marr has a contacts-style Personal Agent workspace with local or self-hosted execution. Open the blue star
in the left rail. The existing Conversation / Work surface remains mounted and
keeps its draft and layout; the rail stays 64 points wide. Both surfaces share
the existing glass and 0.80 frost overlay.

## Product baseline

The reference is Grok Bot's persistent named agents, reusable skills, routines,
run history and explicit approvals. Primary references checked on 2026-10-28:

- [Grok Bot overview](https://docs.x.ai/grok-bot/overview)
- [Skills and routines](https://docs.x.ai/grok-bot/skills-routines-and-automations)
- [Approvals, security and privacy](https://docs.x.ai/grok-bot/approvals-security-and-privacy)

Each agent appears as a contact with its own chat. The main view no longer contains dashboard explanations or a four-tab switcher. Wide windows show contacts beside the conversation; compact windows drill into a chat. Routines, Skills and Activity live in the management menu.

Users can configure their own always-on server in Settings → Work → Personal Agent · Hosting. The Docker deployment package and instructions are in [services/personal-agent](../services/personal-agent/README.md). Marr supplies the service and client integration, not managed hosting. Local and remote archives remain separate. Mobile continuity and a connector ecosystem are not implemented.

| Area | Implemented behavior |
| --- | --- |
| Agents | Create, edit, pause and delete agents; name, role, instructions, color and user-maintained memory |
| Conversation | Real runtime turns, persistent thread per agent, streamed result, recorded tool activity, stop, explicit approval and input cards |
| Skills | Create/edit/delete a shared instruction library; selectively include skills in agents and routines |
| Routines | Hourly, daily or weekdays; explicit time zone; pause/resume, edit, delete and manual test |
| Activity | Results, failures, pending input and uncertain runs; unread rail dot; mark read; recorded no-op checks stay quiet |
| Files | Persistent per-agent folder, opened from agent details; optional workspace write access |
| Memory | Editable stable preferences plus runtime conversation context; no automatic unreviewed memory rewriting |

## Local first use

1. Open Personal Agent and enable the local runtime, or use the existing
   Settings → Work → Sync Codex work setting. A working signed-in Codex
   runtime must be installed. Agent execution uses the currently selected
   runtime model; it does not use the separate Conversation gateway or OAuth
   provider automatically.
2. Open Marr, or create an agent with a clear role and instructions. Its default
   file sandbox is read-only. Agent details can permit writes to its own folder.
3. Send a task with the arrow button or Command-Return. Required access and
   questions appear in the conversation and Activity. Approval is for one
   request, never an automatic session-wide grant.
4. Save a stable method in Skills and select it in the agent's details. Add a
   Routine with its agent, instruction, schedule and time zone. A new routine
   defaults to paused; test it with Run now before enabling its schedule.

In local mode, routines run while the app is running and the Mac is awake, including when the
answer panel is closed. This version installs no launch daemon or OS cron job.
Sleep or downtime coalesces missed occurrences into one run after returning.
New schedules wait until their next occurrence; creating a routine never runs
it immediately. Manual tests leave the next scheduled time unchanged.

## Runtime and harness

`PersonalAgentCloud` connects to the user-configured HTTPS endpoint, stores its bearer token in Keychain, validates the protocol/service identity, and polls durable state every three seconds. The client never silently falls back to local execution when the server is unavailable. Sending, editing, stopping and approvals route to the selected backend. Closing Marr suspends polling only; the remote scheduler remains active.


`PersonalAgentCoordinator` is owned by `MarrController` and its timer starts at
application bootstrap, independently of view visibility. It uses the existing
runtime endpoint/model discovery, then opens an independent WebSocket with its
own thread IDs, request IDs and interaction queue. Work's selection and live
approval queue are never reused.

`PersonalAgentStore` commits a versioned JSON snapshot atomically before any
execution starts. Each run is durable before the next wake is advanced. A separate pre-submit marker is committed before sending a turn, so a crash before dispatch is distinguishable from an unacknowledged submission. A write
failure prevents dispatch. Corrupt or newer-version archives remain untouched
and mutations are blocked rather than overwriting them with an empty archive.

The local scheduler scans every 20 seconds. One local Personal Agent run executes at a time. The self-hosted service scans every 10 seconds and runs up to four different agents concurrently, while serializing each individual agent.
It respects paused agents, enabled routines, a rolling 24-hour routine budget
(default 12 per agent), and a wall-time limit (default 10 minutes, including
approval waits). Runtime disablement leaves pending schedules intact. Failed
runs are not automatically retried before the next scheduled occurrence.

Agent chat and each routine have separate persistent runtime threads. At each
start/resume, Marr supplies current instructions, selected skill content and
user-maintained memory. These fields do not themselves grant tools. The runtime
receives `approvalPolicy: on-request`, `approvalsReviewer: user` and the explicit
read-only or workspace-write sandbox. Each turn also overrides the concrete sandbox policy: workspace writes are limited to the agent folder, temporary-directory exemptions are off, and direct tool network access requires approval. It offers web search and sandboxed local
tools. Apps, plugins, configured MCP servers, hooks and proactive subagents are
disabled for these threads; connected-app writes need a future authorization
boundary beyond a filesystem sandbox. A workspace sandbox is not a complete
host VM or a guarantee that the model can read only the agent folder.

Only matching thread/turn requests become approvals. Unsupported host tools are
rejected. Approval decisions are validated through the existing protocol models.
Extra access can be granted by the user through an approval; external sending,
purchasing and publishing are also constrained by the agent instructions.
Instructions are not represented as an independent hard security boundary.

Stop sends `turn/interrupt` and waits for runtime evidence. If a connection drops,
the app closes, or stop cannot be confirmed, the run becomes **Check connection**.
That agent cannot start another run until reconciliation confirms completion.
Reconciliation only reads the original thread and never resubmits a message.
`clientUserMessageId` links a durable run to the runtime user item's `clientId`
when the turn-start acknowledgement was lost. An earlier completed turn is never
substituted. If the runtime cannot provide either identifier, uncertainty stays
visible instead of inventing a successful outcome. A known active turn can be
stopped after reconnecting.

The agent may return exactly `NO_UPDATE` for an uneventful routine check. The run
is retained, shown as “Checked · no changes to report”, and marked read without
an unread badge. This is a model-reported no-op, not a claim that Marr independently
verified the check. No system push notifications are sent in this version.

## Storage

Under `MarrStorage.rootURL/PersonalAgent`:

- `agents-v1.json`: profiles, memory, skills, schedules, run results, identifiers
  and bounded tool traces (latest 100 entries per run).
- `Workspaces/<agent UUID>/`: persistent agent files. Deleting an agent removes
  its schedules but preserves prior run history and files.

Runtime-owned conversation data is retained by the configured runtime. Marr's
archive is separate from the existing Work archive. Rendering tests use isolated
stores and never load or mutate the user's Personal Agent archive.

## Deliberately unimplemented capabilities

- Marr-managed hosting and browser desktop streaming. User-hosted execution while the Mac is off is implemented; see the deployment guide.
- Third-party event subscriptions, authenticated webhooks and mobile access.
- Connected apps/MCP tools for agent execution, cross-agent messages and group chats.
- Learning a workflow from screen recordings, attachment uploads in agent chat.
- Model-driven creation of routines/skills and automatic long-term memory edits;
  these currently use the explicit editors.

## Verification

Unit tests cover calendar/DST behavior, missed-wake coalescing, pause/budget
checks, persistence and failed saves, duplicate prevention, RPC isolation,
explicit approvals, lost acknowledgements, rejection handling and confirmed
interrupts. Offscreen fixtures cover every workspace tab and the conversation
in light/dark appearances at the original 484-point shell width. Existing glass,
sidebar geometry and panel replacement tests are included in the targeted suite.
Runtime fields were also checked against the locally generated app-server JSON
schema. No paid inference, real external write or visible app launch is part of
these tests.

The existing history-fixture teardown now waits up to two seconds for SwiftUI's
asynchronous graph release after clearing the hosted root. It still requires
all weak history-store references to become nil before deleting fixture data.
The original immediate assertion intermittently ran before native view teardown.

The repository-wide size-budget check still reports existing oversized files:
`MarrController.swift`, `AgentComposerView.swift`, `AnswerPanelView.swift` and
`TranslationRenderer.swift`. No size budgets were raised; the new feature files
remain below the default 800-line limit.

Final validation (2026-10-28): the 58-test targeted suite passed, followed by an
11-test runtime/coordinator/rendering pass including one additional permission
boundary test. Thus 59 distinct relevant tests passed across the final passes.
Result bundles: `build/validation/personal-agent-20261028-v6.xcresult` and
`build/validation/personal-agent-permissions-v7.xcresult`.

Validation for contacts and self-hosting (2026-10-29): 23 macOS agent tests and 9 Python service tests passed, including wide/compact light/dark offscreen captures. Client tests cover TLS validation, local/remote isolation, durable request IDs on retry, out-of-order snapshots and server identity changes. Service tests use fake runtime sessions, not paid inference. Docker is unavailable in this development environment; deployment-host verification remains required. The service CI workflow builds the pinned Linux image.

Latest result bundle: `build/validation/agent-cloud-final.xcresult` (23 tests passed). Python final pass: 9 tests passed. Review captures: `output/personal-agent-contacts/`. The current repository-wide size audit also reports existing over-budget `AnswerPanel.swift` and `MarrWorkspaceSidebar.swift`; none of the flagged files were expanded for this feature.
