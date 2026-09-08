# M1 — Safe file lifecycle

Depends on M0. Primary files: `Document.hx`, `DocumentManager.hx`,
`Application.hx`, `RootView.hx`, `GraphicalMain.hx`, `workspace/FileSystemService.hx`.
Use a minimal reusable prompt/notification mechanism now; M3 polishes it.

## M1.1 — Document identity and persistence service

- [x] Separate stable document identity from an optional backing path. New
  documents have no synthetic filename that could accidentally be written.
- [x] Centralize open/save filesystem operations behind an injectable service;
  preserve a clear separation between disk identity and display title.
- [x] Define normalized-path, duplicate-open, symlink and case sensitivity policy
  using platform semantics. Save As must not silently duplicate an open document.
- [x] Define UTF-8 decoding failures, BOM and newline handling. Preserve existing
  line endings on save; defer unsupported encodings with a visible error.

Acceptance: two opens of the same supported path resolve consistently; untitled
documents remain distinct; CRLF/BOM fixtures round-trip under the declared policy.

## M1.2 — New, Open, Save and Save As

- [x] Register commands and path-entry UI, including default new-document startup
  instead of relying on `out/README.md` as the only empty-state behavior.
- [x] Save to a temporary sibling then replace the destination using appropriate
  native/stdlib operations; preserve relevant permissions and document the
  platform's atomicity/durability guarantees. Clean up only owned temporary files.
- [x] Mark the document clean only after success; update path/syntax/title after
  successful Save As. Confirm destination overwrite and report failures visibly.

Acceptance: permission/write/replace failure leaves old file intact and buffer
dirty; cancelled Save As leaves identity unchanged; successful save/undo/redo
tracks the saved revision correctly. Inject failures rather than relying on chmod.

## M1.3 — Unified close/quit state machine

- [x] Route tab close, pane close and native quit through one coordinator.
- [x] Prompt Save/Discard/Cancel for documents losing their final view; deduplicate
  documents shared by panes. Resolve all required saves before releasing resources.
- [x] A cancelled prompt or failed save cancels the destructive transition.
  Prevent duplicate quit requests and input falling through modal prompts.

Acceptance: multi-document quit, shared-document pane close, cancel at the second
prompt and failed save all preserve expected documents and native resources.

## M1.4 — External changes and recovery

- [x] Track disk version; on activation or scheduled checks detect changes and
  deletion. Clean buffers may reload under a documented policy; dirty buffers
  require explicit reconciliation and never silently overwrite external edits.
- [x] Add versioned recovery snapshots for dirty/untitled documents to the user
  state directory, using atomic writes and bounded retention.
- [x] Offer recovery at startup without overwriting source files. Delete snapshots
  only after successful save, explicit discard or confirmed recovery handling.

Acceptance: injected crash followed by restart recovers content; stale/corrupt
snapshot is reported safely; external dirty-file conflict requires a choice.
Exit: all file-safety scenarios pass headlessly, with graphical prompt smoke test.
