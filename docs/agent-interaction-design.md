# Agent input and response interaction

Marr adapts interaction patterns to its compact native macOS panel. The first
input/reading pass preceded identification of the reference repository.
The 2026-10-21 implementation follows `Caho1/open-claude-ui` at `07caa0d`;
the [source comparison and remaining work](open-claude-ui-gap-audit.md) records
what was implemented and what remains separate. Animation timings below are
Marr design choices, not claims about official Claude parameters.

## Reference and application

[Claude's model and thinking controls](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings)
place model selection beside sending and expose processing detail through an
expandable section. Marr applies that hierarchy with a full-width editor above
a compact attachment/model/send row. Forking remains in the existing chat menu.
An accent border shows editor focus without changing the editor's identity.
Shared, resolved neutral colors keep controls and secondary text legible over
glass in both light and dark appearances.

[Claude's streaming documentation](https://platform.claude.com/docs/en/build-with-claude/streaming)
distinguishes incremental text, tool and thinking events. Marr uses its own
Codex events to show Working, Responding, Running command or Updating files.
Ambiguous events use Working; requests for user input show a static status.
Completing one message does not imply that the whole task has finished.

Task activity can be expanded during execution as well as after completion.
The global running indicator is separate from historical turns, so a newly
submitted task does not make an old answer appear active. An error before the
first user message remains visible instead of being replaced by the empty state.

## Motion and reading

- Conversation acknowledges submission immediately; the previous 300 ms
  presentation delay is removed.
- Focus and new response transitions use 180 ms ease-out. Controls use modest
  springs: press 0.22 s / 0.86 damping, mode selection 0.32 / 0.86, panel
  navigation 0.38 / 0.94, attachment changes 0.30 / 0.84, disclosures 0.28 / 0.96.
- The composer has a low-amplitude ambient glow only while work is executing.
  Awaiting approval and retry countdowns do not imply execution. A separate
  20 fps timeline drives a slow six-second phase without invalidating the editor
  on every text delta. Native window visibility stops dynamic scheduling when
  the panel is hidden or occluded. Entry/exit fades take 160 ms; the timeline
  stops immediately at exit while a static glow fades out.
- Reduce Motion makes these effects static. Reduce Transparency or increased
  contrast replaces the glow with a solid outline. Decorations do not capture
  pointer events or appear in the accessibility tree.
- A fixed 14 pt activity ring communicates indeterminate work. It does not
  estimate progress or replay received text as simulated typing.
- Work message transitions are keyed to message identity, never to text deltas.
  The native editor remains mounted across streaming and running-state updates.
- Conversation and Work share a centered reading column capped at 720 pt.
- Both transcripts follow growing content while the reader stays near the
  bottom. Scrolling up pauses following and exposes Jump to latest. Native
  document-size observation handles reply layout and window resizing without
  an animation for each text update.
- The composer preserves the existing Return, completion and IME handling.
  Send and Stop remain separate so a running task can still accept instructions.
- Conversation clears its draft only after accepting a new turn. Draft identity
  is scoped to the conversation or workspace/local task UUID. Text, selection,
  edit target, attachments and mention bindings persist together across task
  switches and restarts. File pickers retain their original destination even
  if the selected task changes before completion.
- Work persists unconfirmed submissions until a response or lifecycle event
  acknowledges them. Recovery returns to the source task and reads its state;
  it never silently resends an ambiguous action.
- Conversation renders actual provider stream events, preserves partial output
  on cancellation/error, and ignores superseded generations. Only a pre-content
  429/503 gets a bounded retry and visible countdown; Work delegates retry
  decisions to its runtime.
- Response and code copy actions report clipboard success/failure. Code fences
  retain language and tolerate incomplete streams. Diff previews group files,
  number old/new lines, expose explicit additions/deletions and cap rendered
  length while retaining complete copy. Long user prompts can be collapsed.
- Message actions use quiet 28 pt icon controls with a shared 12 pt symbol scale,
  rounded hover/pressed surfaces and keyboard focus outlines. User actions align
  right below the bubble; response actions align with the left reading inset.
  Copy confirmation replaces the icon for two seconds without changing bounds.
  Tooltips and accessibility names retain the complete action description.
  The latest editable Conversation message offers Copy and Edit together;
  other user messages keep Copy. Code and diff headers share the same control.
- Shared attachment chips expose previews and removal. Runtime model/effort
  descriptions and Work's last-request token usage are inspectable; missing
  context capacity is shown as unavailable, never replaced with a sample value.
- [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
  replaces the ring with a static symbol and disables answer-content animations. Adjacent
  status text provides its accessible name; icon controls have explicit labels.

Validation uses the composer, support-view, workspace, recovery and networking
suites. Native fixtures exercise task/project switching, editor identity,
selection, focus, window visibility, light/dark layouts and accessibility
variants. No service requests are needed for these fixtures. Exact run results
and remaining live validation are recorded in the source comparison.
