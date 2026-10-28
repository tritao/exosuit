# Sessions UI refinement

## Product contract

Sessions are first-class IDE documents backed by the existing workspace agent service. Codex, Claude, Pi and the built-in agent use the same visual language, with controls driven by provider capabilities. Terminals, editor documents, workspace groups, remote workspaces and source control retain their existing ownership and behavior. Work is isolated on branch `ui-exploration`.

The desired experience combines the readable conversation and compact composer of T3 Code with the quiet hierarchy of Hermes Desktop. The code references and commits are recorded in [the reference research](chat-ui-reference-research.md). Exosuit remains an IDE: opening a file or reviewing changes uses its established editor and Source Control surfaces.

The visual direction includes crisp, defined borders, restrained corner rounding and subtle contact/ambient shadows. A palette change alone does not meet the quality bar. Use a recessed application frame, a defined workspace surface, quiet navigation controls and a composed, elevated input area; inspect real native pixels in both themes.

## Conversation

- Give assistant prose a comfortable reading measure. Distinguish user messages with a subtle surface, role labels and consistent spacing. Keep provider identity and readable connection/turn status in the header.
- Render streaming Markdown without losing incomplete content. Support headings, lists, inline code, explicit links, fenced code, quotes and tables using native views. Preserve literal content where typography cannot faithfully represent unsupported Markdown.
- Put language and copy above code. Preserve exact source on copy, syntax highlighting, native selection and horizontal scrolling for wide code and tables. Offer separate whole-message copy with confirmation.
- Keep command and reasoning disclosures collapsed initially; show supplied details on request. Display actual file-change patches with numbered hunk rows, addition/removal tint, per-file disclosure and copy/open actions. Preserve source fidelity and label truncated data.
- Associate edits with files from optional provider-reported metadata. Codex reports bounded slices into its existing patch payload, keeping legacy fields available without duplicating patch data on the wire. Legacy unattributed output stays unattributed. Counts describe observed patch lines, not a net Git checkpoint.
- Recognize standalone and inline Markdown images without consuming surrounding prose or interpreting code spans. Offer explicit native previews for authorized local/remote workspace PNG/JPEG/GIF and bounded raster data URLs. Remote reads pin revision and validate each 32 KiB chunk; never resolve remote host paths locally. Chat previews fit within 512 pixels, while remote editor tabs retain original dimensions up to 4096 pixels and a shared 128 MiB texture budget. Preserve alt text and explanatory fallbacks. External images do not fetch implicitly.
- Completed HTML/SVG and substantial code fences have compact source artifact cards. Preserve original line endings and final newlines for copy. Incomplete fences remain visible inline while streaming. On Windows with a suitable WebView2 runtime, HTML and SVG can open in an isolated static preview, bounded to 512 KiB of source; setup or policy failures leave source available. Scripts, navigation and external resources are disabled. SVG also has a bounded native preview for supported shapes and paths, with an explanatory fallback for unsupported SVG.
- For Codex, Claude and Pi, negotiate full assistant-message retrieval separately from bounded activity previews. Automatically load the latest completed truncated response, offer explicit loading for older responses, and reject changed or unavailable snapshots. Transfer at most 24 KiB per chunk and retain at most 256 KiB per message; label a larger response as partial. Copy the displayed full response when available and identify preview copies. Restored truncated Claude/Pi snippets have no full-content token until authoritative source is recovered.
- Pi successful edit events can expose an actual provider-reported unified patch while retaining the original tool input and output; do not treat display-oriented numbered diffs as patches. Claude tool completions retain their reported arguments and truncation state.
- Group pending requests after the conversation with their existing approve/decline/answer actions. Preserve reviewability restrictions, queue/steer controls, uncertain delivery and recovery behavior.
- Keep the composer visible when space permits; scroll the whole document when the dock becomes too short. New output follows the transcript only while the reader is at its bottom. Retain the draft and model/effort choices through ordinary renders.

## Composer and IDE navigation

- A rounded, lightly raised multiline composer groups model/effort controls, draft, command completion and send/queue/steer actions. Preserve Enter, keypad Enter, Shift+Enter and command-completion handling.
- Show the actual session working directory and known branch. Offer Files and Review changes as navigation actions; review means current workspace changes, not turn-attributed checkpoints.
- Explicit Markdown file links open in Exosuit at optional `:line:column` or `#Lline` locations. Resolve relative paths against the session working directory. Validate workspace identity on activation and asynchronous completion. Remote host paths use workspace file RPC, never the local OS shell.
- External HTTP(S)/mailto links open only on activation. Unsupported schemes remain literal. Local paths never go to the OS shell. Out-of-workspace file links report an actionable error.
- Commit changes selects the session's nearest writable Git repository and focuses the existing Source Control draft editor. Commit, branch, push and other Git mutations retain existing review and permission flows; opening the editor never submits a commit.
- Include up to two bounded workspace text snapshots through the owning host's file service. Label them as text context, show removal and read errors, and preserve edits made while a submission is awaiting acknowledgement.
- Codex can negotiate native image input separately from text context. Choose a local image or paste an image-only Windows clipboard payload; ordinary text paste retains its normal behavior. Upload bounded chunks to private host staging and send opaque session-scoped handles; the provider resolves these to host-local image input. Show bounded in-memory draft thumbnails and upload/failure/removal states, dispose preview resources on removal, acknowledgement or unmount, and retain unsent draft content. Claude/Pi must not advertise this capability until their adapters and queue persistence support it.
- A negotiated Git worktree operation creates a new branch and a new child checkout inside the workspace. Start the integrated session only after its group is bound to the resulting directory. Preserve the original checkout and report the recoverable destination if later group/session creation fails.
- GitHub actions use an authoritative host-side origin query, allowlisted canonical URLs and explicit activation. Revalidate before opening the repository or a comparison/PR creation page for the current named branch. Opening that page does not push a branch or submit a PR.

## Theme workstream

Both light and dark modes share semantic colors, geometry and interaction hierarchy. Dark is the first visual evaluation target. Use neutral, layered surfaces; readable secondary text; crisp borders; a consistent blue focus/action accent; and compact tab labels. Selected tabs connect visually to the editor canvas. Workspace and selection surfaces use native geometry shadows; the composer uses a defined one-pixel edge and raised native box. Respect explicit appearance settings and preserve syntax/diagnostic meaning. Details are in [theme polish](theme-polish.md).

## Follow-on capabilities requiring transport/native changes

These are part of the intended complete experience, but must be implemented end to end before exposing their controls:

1. **Broader input and history:** Claude/Pi image adapters and durable queued attachment references remain unsupported. Draft thumbnails are temporary; sent-image thumbnails and an attachment archive require durable, scoped asset identity. Non-Windows image clipboard support remains to be implemented. Passing client-local filenames as though they were remote attachments is incorrect.
2. **Durable response recovery:** Codex, Claude and Pi support bounded full-message retrieval from retained authoritative source. Snapshots can be evicted or exceed the display cap. Persisted truncated Claude/Pi snippets deliberately have no full-content token until an authoritative response is recovered. A durable full-response archive remains separate work.
3. **Broader artifacts:** Windows static HTML/SVG preview is intentionally inert and availability-dependent; it does not implement arbitrary interactive web applications. The native SVG subset rejects unsupported features. [Renderer contracts](renderer-contracts.md) records the actual boundary and platform requirements.
4. **PR submission:** opening an authoritative GitHub comparison page is supported separately from submitting a PR. Actual submission needs a supported authenticated review/network workflow.

These are explicit remaining capabilities, not implied by the visual implementation. The local-source audit identifies the exact current boundaries.

## Acceptance and regression checks

- Build the graphical app and agent from this isolated worktree with independent dependency/build outputs.
- Native layout checks cover code header order, inline spacing, wrapping, quote/table rendering and keyboard-accessible links.
- Presentation checks cover both themes and multiple providers, empty/streaming/request states, draft submission, model/effort controls, and narrow/wide layouts.
- Pure link tests cover Windows/POSIX paths, relative navigation, location suffixes, nested URL parentheses, unsupported schemes and incomplete streaming syntax.
- Existing theme tests verify control state colors, selected-tab canvas, readable contrast and editor/default consistency.
- Run provider/state tests where the platform supports them. Linux Xvfb scenarios are not evidence of Windows validation unless actually run on a Linux host.
- Visual QA must inspect the real native UI; a successful build or token contrast calculation alone does not establish production polish.
