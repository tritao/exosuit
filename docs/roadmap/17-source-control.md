# M17 — Source control

Status: planned. The design is [ADR 0004](../architecture/0004-source-control.md).

Depends on:
- M9 (sidebar modes, panes);
- M15.1 (capability guards);
- M14.1–M14.3 (shared protocol and agent daemon) for M17.3 only.

The in-process path (M17.1, M17.2, M17.4–M17.6) does not need the daemon.
VS Code's Git extension and SCM API, and Zed's git panel, are behavioral
references only. Their code is not ported.

Destination: daily commits on this repository happen inside the editor:
review changes, stage files or hunks, write the message, commit. That
includes the nested `haxeon` submodule. Remote web/Android clients can review
changes, and can commit when granted.

## Decisions taken by default

Record any override in STATUS.

- **Built in, VCS-neutral.** Source control is a core subsystem behind an
  `ScmProvider` interface. Git is the only shipped provider; a fake provider
  exists for tests.
- **The `git` CLI** (≥ 2.25), not libgit2. Status uses porcelain v2 with `-z`.
- **Remote grants.** Paired devices get `workspace.scm.read` by default.
  `workspace.scm.write` and `workspace.scm.remote` need explicit owner
  approval. Local desktop connections get all three.
- **Diff view.** The first diff view is a read-only **unified** diff tab,
  which also works at phone width. Side-by-side is M17.7.
- **Network operations** (fetch, pull, push) are the last task. The first cut
  relies on credential helpers and SSH agents with prompts disabled.
  Interactive credential prompts through `exosuit-ctl` as `GIT_ASKPASS` are a
  follow-on.
- **Restricted mode.** New repository roots stay restricted until the user
  trusts them. Restricted mode means no fsmonitor, no hooks, no filters and no
  mutations.
- **Trust is local-only.** A repository can be trusted only from the machine
  that runs Git: the in-process host or a local desktop connection. No
  device grant includes it.
- **Blob reads are batched.** Original content comes from one long-lived
  `git cat-file --batch` process per repository, not a process per file.

## Layout

| Area | Location |
| --- | --- |
| Model, provider interface, service core, line diff | `src/scm/` |
| Git provider and porcelain parser | `src/scm/git/` |
| Controller and commands | `src/controller/ScmController.hx` |
| Shared wire records and methods | `src/workspace/service/WorkspaceScmProtocol.hx` |
| RPC client source | `src/workspace/client/WorkspaceScmClient.hx` (`RpcScmSource`) |
| Agent host | `agent/src/workspace/runtime/WorkspaceScmService.hx` |
| Graphical UI | `graphical/src/ui/Scm*.hx`, plus hook changes in `EditorGutter`, `ExplorerTreeModel`/`DirectoryTreeModel`, `StatusBarView`, `ExosuitApp` |
| Tests | `tests/scm-model`, `tests/scm-git`, `tests/workspace-scm`, `tests/scm-ui-smoke` (`scripts/test-scm-ui.sh`) |

Adapt class names to the existing abstractions when implementing
(EXECUTION.md work loop, step 2).

## M17.1 — Model, provider interface and Git core

- [ ] VCS-neutral model:
  - `ScmRepository`, `ScmSnapshot` (Int64 revision), `ScmHead` (branch or
    detached commit, upstream, ahead/behind, upstream gone, and an operation:
    none, merge, rebase, cherry-pick, revert or bisect);
  - `ScmGroup` with ids `merge`, `index`, `workingTree`, `untracked`;
  - `ScmResource` (path, original path, `ScmChangeKind`, conflict kind);
  - `ScmFeatures` flags;
  - an `ScmOperation` enum: stage, unstage, discard, commit (message, amend),
    stage patch, checkout, create branch, fetch, pull, push.
- [ ] `ScmProvider` / `ScmRepositoryHandle`: detect, refresh, original
  content at an `ScmRef` (HEAD, index, commit, conflict stage 1–3), apply and
  dispose. Every call returns a cancellable job; results carry the generation
  they were started under.
- [ ] `FakeScmProvider` for tests: scripted snapshots, latency and failures.
- [ ] Porcelain v2 parser (`GitStatusParser`) over `-z` output. It must handle:
  - branch headers, including an unborn branch, a detached HEAD, no upstream
    and a gone upstream;
  - ordinary `1`, renamed or copied `2` with score, unmerged `u` (all seven XY
    codes), untracked `?` and ignored `!` entries;
  - submodule state fields;
  - paths containing spaces, newlines, non-UTF-8 bytes and leading dashes.
- [ ] `GitProcess` runner over `ProcessManager`:
  - standard environment: `GIT_TERMINAL_PROMPT=0`, `GIT_EDITOR=:`,
    `GIT_LITERAL_PATHSPECS=1`, `--no-optional-locks` on reads, no color;
  - bounded stdout and stderr capture;
  - cancellation;
  - a version probe that rejects Git older than 2.25 with a clear state;
  - Git discovery without side effects: `scm.gitPath` first, then `PATH`.
    On macOS, check `xcode-select -p` before invoking `/usr/bin/git`, so a
    missing toolchain never opens the Command Line Tools installer;
  - a stable error mapping: `git_unavailable`, `git_too_old`,
    `not_a_repository`, `lock_contention` (retryable), `operation_failed`
    (with a bounded stderr excerpt) and `untrusted`.
- [ ] `GitBlobReader`: one long-lived `git cat-file --batch --filters`
  process per repository, fed `<rev>:<path>` lines over stdin.
  - Responses are parsed incrementally from the `<oid> <type> <size>` header,
    and `missing` / `ambiguous` replies map to errors.
  - Requests are queued in FIFO order; a cancelled request's bytes are
    drained and dropped, never misattributed to the next request.
  - Restart after a process exit or protocol error, after the repository
    config changes (`config` / `commondir` watch), and after an idle timeout
    (default 60 s).
  - Restricted mode uses `--batch` without `--filters`.
  - Binary detection (NUL in the first 8000 bytes, as Git does) and a
    configurable size cap. Oversized blobs are skipped by their header size
    before reading.
- [ ] `LineDiff`: Myers O(ND) line diff with a cost budget. Past the budget
  it degrades to one whole-range hunk. It is step-sliced for `JobScheduler`
  and outputs added, modified and deleted hunks with old and new ranges.

Acceptance:
- Parser fixtures cover every entry type and edge case above.
- Property tests on `LineDiff` reconstruct the new text from the old text
  plus the hunks, across random edits.
- The fake provider drives a model test of group ordering and of
  feature-derived operation availability.
- No `Application.update()` frame waits on a Git process.
- `GitBlobReader` tests:
  - 1 000 sequential reads reuse a single process;
  - interleaved cancellation never misattributes bytes;
  - killing the process mid-response yields a retryable error and a fresh
    reader;
  - a `missing` path maps to its error;
  - an oversized blob is skipped by its header.

## M17.2 — Service core: discovery, refresh and trust

- [ ] `ScmService` discovers repositories for each project root:
  - the containing repository via `git rev-parse --show-toplevel --git-dir
    --git-common-dir`;
  - linked worktrees, where `.git` is a file;
  - submodules from status submodule entries;
  - nested repositories found by a bounded scan for `.git` markers under the
    root (default depth 3, configurable);
  - a parent/child relation for the UI.
- [ ] Refresh scheduling:
  - **Watches.** Worktree changes arrive through the existing watcher. Separate
    watches cover the gitdir and common dir: `HEAD`, `index`, `refs/` (heads,
    remotes, tags), `packed-refs` and operation markers (`MERGE_HEAD`,
    `rebase-merge/`, `rebase-apply/`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
    `BISECT_LOG`). The `.git` exclusion in `excludedNames` stays in place.
  - **Debounce.** 300 ms after the last event, with at most 2 s latency under
    a continuous stream of events.
  - **Single flight.** One refresh runs per repository; a change during a
    refresh schedules exactly one rerun.
  - **Overflow.** Watcher overflow triggers a full refresh.
  - **Other triggers.** Refresh after the service's own operations, after a
    document save, and when the window regains focus.
- [ ] Snapshot revision advances only when content changes (compare encoded
  snapshots), so idle repositories cause no UI churn.
- [ ] Untracked limit (default 10 000 resources). Beyond it the snapshot is
  marked truncated and the UI says so; it is never silently partial.
- [ ] Per-repository FIFO operation queue. Mutations are serialized, and
  `lock_contention` retries three times with backoff, then reports.
- [ ] Repository trust:
  - A per-root record is persisted by the host that runs Git.
  - Restricted mode passes `-c core.fsmonitor=`, `-c core.hooksPath=<empty
    dir>`, uses unfiltered reads and disables mutations.
  - Git's `safe.directory` refusal is surfaced as its own state.
  - Trusting is a local-only action: the in-process host or a local desktop
    connection. Over RPC, trust state is readable, but the service rejects
    trust requests from paired devices regardless of their grants. Their UI
    says to trust the repository on the machine itself.
- [ ] Settings in `Settings.hx`/`PreferencesRegistry`:
  - `scm.enabled`, `scm.gitPath`, `scm.untrackedLimit`, `scm.diffSizeLimit`;
  - `scm.nestedScanDepth`, `scm.autoRefresh`;
  - `scm.gutter`, `scm.explorerDecorations`.

Acceptance: `tests/scm-git` creates temporary repositories with the real `git`,
and records "pending" when Git is absent. It covers:
- detection of a plain repository, a linked worktree, a submodule, a nested
  repository, an unborn repository and a non-repository;
- an external `git add` in a subprocess advancing the snapshot within 2 s;
- a burst of 500 file writes producing at most 3 refreshes;
- a held `index.lock` producing a retryable error and then success once it is
  released;
- a merge conflict appearing in the `merge` group with the right conflict kind.

The trust test uses a repository whose `core.fsmonitor` and
`filter.x.smudge` write a marker file. In restricted mode, status and
original-content reads never create the marker. After trusting, they may.

## M17.3 — Workspace protocol and agent host

- [ ] `WorkspaceScmProtocol`, shared `@:wire` records with permanent `@:id`s.
  Allocate an unused method-id range after auditing the existing protocols,
  and never reuse ids. Methods:
  - `scm.repositories`;
  - `scm.snapshot`;
  - `scm.watch` / `scm.unwatch`, with sequenced change events and replay or
    reset, following WORKSPACE-PROTOCOL;
  - `scm.original` (bounded single response, with a `too_large` error);
  - `scm.apply` (operation id deduplication, expected snapshot revision,
    structured outcome);
  - `scm.trust`, accepted only on local desktop connections (the
    connection's authenticated origin, not a capability). It is rejected for
    relay devices with `local_only`.
- [ ] Capabilities `workspace.scm.read`, `workspace.scm.write` and
  `workspace.scm.remote`, enforced per method in the service, independently of
  the relay. The Remote Access approval panel lists them; new devices default
  to read only.
- [ ] Grant editing for approved devices, in the Remote Access panel and the
  pairing admin protocol. It applies to every grant (terminals, agents,
  SCM), not only SCM.
  - Widening a grant is an owner action on the desktop only.
  - Narrowing takes effect immediately: in-flight work under the removed
    grant is cancelled and its watches are closed.
  - The updated grant set is persisted in the device record and survives a
    daemon restart.
- [ ] Revoking a grant cancels outstanding SCM work for that device and closes
  its watches.
- [ ] `WorkspaceScmService` in the agent hosts the same `ScmService` core.
  `RpcScmSource` in the client implements `ScmSource` over the protocol, with
  reconnect and resubscribe.
- [ ] Source selection: a root browsed through `WorkspaceFileTreeModel` uses
  `RpcScmSource`, and a local root uses `LocalScmSource`. One root never has
  both.

Acceptance: `tests/workspace-scm`, against the real agent and a fixture
repository, covers:
- a read-only device can snapshot but gets `unauthorized` on `scm.apply`;
- a duplicate operation id returns the prior outcome without running Git
  twice;
- a stale expected revision yields `stale_revision`;
- revocation mid-watch closes the watch;
- `scm.trust` from a relay device fails with `local_only`, even with every
  grant, and succeeds from a local connection;
- narrowing a device from write to read cancels its in-flight `scm.apply`,
  and the narrowed grant persists across a daemon restart;
- reconnect replays missed events or resets;
- protocol fixtures verify schema evolution with an unknown optional field.

## M17.4 — Shared presentation hooks

Each hook is generic and owner-scoped. Source control is its first
contributor.

- [ ] **Gutter marker lane.**
  - A marker registry keyed by document, owner and line range, with kinds
    added, modified, deleted-above and deleted-below.
  - `EditorGutter` draws a narrow strip next to the line numbers, using theme
    tokens. Markers are part of the gutter's retained key.
  - Clicking a marker selects its hunk, which M17.6 uses.
- [ ] **Resource decorations.**
  - A `ResourceDecorationProvider` returns, per path, a badge (1–2 characters),
    a color token, a tooltip and whether the decoration propagates to parent
    folders.
  - `DirectoryTreeModel` and `WorkspaceFileTreeModel` rows render a trailing
    badge and a tinted name.
  - The provider revision joins the `ExplorerTreeView` cache key.
  - Editor tab titles take the same tint.
- [ ] **Status bar items.**
  - `StatusBarData` gains a contributed item list: side, priority, text, icon,
    tooltip and command.
  - `PluginStatusRegistry` items render through the same path, closing the
    existing gap.
  - Item revisions join the status bar's retained key.
- [ ] **Diff document.**
  - A read-only document view showing a unified diff, with the file's syntax
    highlighting, `WholeLineBackground` decorations for added and removed
    lines, and old and new line-number columns.
  - Its identity is `scm-diff:<repo>:<path>:<ref>`. It recomputes when the
    base revision or the buffer changes.
  - Commands: next hunk, previous hunk, open file at line.

Acceptance: `decoration-ui-smoke` / `status-bar` style headless checks cover:
- a test owner's gutter markers and explorer badges render and clear on
  owner removal;
- folder roll-up shows the highest-priority child state;
- contributed status items order by priority and dispatch their command;
- diff documents render a 3-hunk fixture with correct line numbers.

No SCM code is needed for these tests.

## M17.5 — Source Control view and read-only workflows

- [ ] Register the sidebar destination:
  `registerSidebarDestination("scm", …, new SidebarModeOptions("Source
  Control", 15, true))`. Add the `sidebar:scm` command with Ctrl+Shift+G.
  It is absent without the `SourceControl` capability (local) or
  `workspace.scm.read` (connected).
- [ ] Add `HostCapability.SourceControl`, derived from `Processes`, to
  `HostCapabilities.desktop()`.
- [ ] The view:
  - **Repositories.** Each repository is a collapsible section, with nested
    repositories under their parent. The header shows branch, ahead/behind and
    any in-progress operation.
  - **Groups and rows.** Groups are a tree, using the same TreeView as
    Explorer. Rows show a file icon, name, dimmed directory, a status badge and
    a rename arrow.
  - **Interaction.** Keyboard navigation and a context menu.
  - **States.** No repository, Git missing or too old, untrusted (a Trust
    action locally; on remote clients, a message to trust on the machine), `safe.directory` refusal, truncated untracked list, and
    refresh error with retry.
  - **Width.** It works at phone width in the web build.
- [ ] Row activation opens the diff document against the group's base:
  - index group: HEAD → index;
  - working tree: index → working tree;
  - untracked: the whole file as added;
  - conflicts: the file itself with conflict markers.

  Alt+activation opens the file instead.
- [ ] Explorer decorations and the status bar branch item, through the
  M17.4 hooks. Clicking the branch item focuses the view; branch switching
  comes in M17.7.
- [ ] Gutter markers for open documents. The original is fetched once per
  base revision and diffed against the live buffer through `LineDiff` jobs,
  debounced about 100 ms after edits. Files over the size cap or binary files
  get no markers.
- [ ] Commands: `scm:refresh`, `scm:open-changes`, `scm:open-file`,
  `scm:next-change` and `scm:previous-change` (editor hunks), and
  `scm:trust-repository`.

Acceptance: `scripts/test-scm-ui.sh` (Xvfb) on a fixture repository covers:
- the view lists staged, changed, untracked and conflicted files in the right
  groups;
- typing in an unsaved buffer adds a modified gutter marker within 250 ms,
  and undo removes it;
- an external commit made from a subprocess clears the view;
- explorer badges and folder roll-up match;
- the status bar shows the branch with ahead/behind against a local bare
  remote;
- the diff tab opens with the correct hunks.

The capability-restricted browser host shows no `scm:*` command. The
connected web client with a read grant shows the view and no mutating
actions.

## M17.6 — Mutations: stage, unstage, discard, commit

- [ ] Stage and unstage per file, per group and for everything, from row
  hover actions, the context menu and commands (`scm:stage`, `scm:stage-all`,
  `scm:unstage`, `scm:unstage-all`).
  - Unstage uses `git restore --staged`; on an unborn HEAD it uses
    `git rm --cached`.
  - Feedback is optimistic, with rollback when the operation fails.
- [ ] Discard (`scm:discard`):
  - `ConfirmationService` asks first, naming the file count.
  - Tracked files: capture the current blob with `git hash-object -w`, then
    run `git restore --worktree`.
  - Untracked files go through `TrashService`.
  - Notifications offer undo while the capture exists.
  - Open dirty buffers on discarded files go through the existing
    reload-or-keep prompt.
- [ ] Hunk actions from gutter markers and the diff document: stage hunk,
  unstage hunk, revert hunk. A minimal patch with context is built from
  `LineDiff` and applied with `git apply --cached --recount` (or
  `-R` / worktree for revert) through stdin, after a `--check` dry run.
  This needs the `partialStaging` feature flag.
- [ ] Commit box:
  - multiline message input with a subject length hint; Ctrl+Enter commits;
  - the commit button has a menu: Commit, Amend, Commit Staged vs Commit All
    when nothing is staged (opt-in setting);
  - the message goes through stdin (`git commit -F -`) and hooks run;
  - hook output appears in the build output dock on failure;
  - an unsaved-documents check offers Save All first;
  - the draft message persists in session state per repository.
- [ ] Sign-off and GPG/SSH signing follow the user's Git config. A signing
  failure caused by a missing TTY prompt reports a specific, actionable error.

Acceptance: `tests/scm-git` plus the UI smoke cover:
- stage, unstage and discard round-trip, with real `git` state asserted after
  each;
- discard undo restores the exact bytes;
- stage hunk on a 3-hunk file leaves exactly one hunk staged
  (`git diff --cached` matches);
- a commit with a failing `pre-commit` hook reports the hook output and keeps
  the message;
- amend changes HEAD and keeps the message;
- a restricted-mode repository rejects every mutation with `untrusted`;
- a remote device without `workspace.scm.write` cannot trigger any of them.

## M17.7 — Branches, remotes and side-by-side diff

- [ ] Branch quick pick (`scm:checkout`) from the status item: local and
  remote branches, create from HEAD (`scm:create-branch`). Checkout is blocked
  with a clear message when it would overwrite local changes, as Git reports.
- [ ] `scm:fetch`, `scm:pull` (fast-forward only by default, configurable) and
  `scm:push` (sets upstream on first push after confirmation). They require
  `workspace.scm.remote` when remote, and show progress in a notification.
  With prompts disabled, an authentication failure explains how to configure
  a credential helper or SSH agent.
- [ ] Optional periodic fetch (`scm.autoFetch`, off by default).
- [ ] Side-by-side diff: two synchronized read-only/editable panes with
  aligned hunks.
- [ ] Merge-conflict assistance: the conflict group plus accept
  ours/theirs/both actions on conflict blocks, and "mark resolved" (stage).

Acceptance:
- fetch, pull and push against a local bare remote fixture;
- an auth failure with a fake `ssh` command yields the documented message;
- checkout with conflicting local changes is refused without data loss;
- a two-way conflict resolves in the UI and stages.

## M17.8 — Extensibility follow-ons (separately scheduled)

These are not part of M17 exit. Listed so the boundaries stay open.

- Plugin API v3: expose the gutter-marker, resource-decoration and
  status-item hooks to dynamic plugins.
- Plugin-contributed `ScmProvider`s, once plugins can be hosted by the
  workspace agent.
- A second real provider (Mercurial or jj) when there is demand. The fake
  provider and feature flags are its contract.
- A libgit2-backed read-only reader behind `GitProvider`, only if profiling
  (likely on Windows) shows process startup dominating refresh or blob
  reads. Mutations stay on the CLI.
- Bundling a pinned Git, as GitHub Desktop does, if missing Git proves
  common.
- `GIT_ASKPASS` through `exosuit-ctl` (M13) for interactive credentials, with
  the prompt routed to the UI that started the operation.
- History and blame views, stash and tags.

## Performance

- Status refresh never blocks a frame.
- Record status time and snapshot encode/decode time on the materia monorepo
  and on a synthetic repository with 50 000 files.
- A gutter `LineDiff` step stays under 4 ms per slice. A 10 000-line file with
  50 scattered edits converges within 100 ms.
- Explorer decoration lookup is O(1) per row.
- Measure process startup and batch blob-read latency on Linux and Windows.
  This decides whether the libgit2 reader follow-on is needed.

Record results in `docs/release-qualification.md`.

## Exit

A week of commits on this repository (including the `haxeon` submodule) made
only from the editor's Source Control view, with no terminal `git` needed for
review, staging or committing. A paired browser can review the same changes
read-only.
