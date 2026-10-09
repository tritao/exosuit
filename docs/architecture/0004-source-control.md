# ADR 0004: Source control as a core subsystem with VCS providers

Status: proposed

Implementation plan: [M17 — Source control](../roadmap/17-source-control.md)

## Context

Exosuit has no source control support. The only Git awareness is `.git` in
the excluded names (`src/config/Settings.hx`, `src/workspace/Project.hx`) and
Seti icons. The roadmap lists "SCM/diff UI" as out of scope until it is
separately scheduled. This ADR schedules it.

The feature set is the usual one: a Source Control sidebar listing changes,
explorer status badges, gutter change markers, a diff view, the branch in the
status bar, and stage/unstage/discard/commit. Three facts about the current
codebase shape where it can live:

1. **The plugin API cannot carry it.** Plugin panels are text only, and
   ExosuitApp never renders them; it only compares
   `getPluginPanels().revision` to request a frame. `PluginStatusRegistry`
   items are not rendered either. There is no plugin hook for gutter markers,
   explorer decorations or diff views. Dynamic plugins also need the
   `SourcePlugins`/`Threads` capability, which the browser host lacks.
2. **The repository lives with the workspace, not the client.** Under M14 and
   M16 the workspace service owns files, watchers and processes, and web and
   Android clients own only presentation (16-remote-workspaces.md, "Architecture
   and ownership"). Git has to run on the machine that holds the files.
3. **Workbench is optional.** M14 requires the editor to work when the agent
   daemon is disabled or missing. A desktop user without the daemon still
   expects source control.

## Decision

### 1. A core subsystem, not a plugin

Source control is built in, under `src/scm/`. It is not a dynamic plugin and
not a fork of the plugin API. It keeps a plugin-shaped boundary: one
controller and its owned registrations, no edits scattered through `Document`
or `RootView`. That keeps it removable, and lets it move behind a plugin
boundary later if plugins gain service-side hosting.

### 2. VCS-neutral model, provider interface, Git first

The model follows the groups-and-resources shape used by VS Code's SCM API,
which fits Git, Mercurial, jj and Subversion:

- `ScmRepository`: identity, provider id, root, kind (worktree, linked
  worktree, submodule, nested) and parent repository.
- `ScmSnapshot`: an Int64 revision, `ScmHead` (branch or detached commit,
  upstream, ahead/behind, in-progress operation) and ordered `ScmGroup`s
  (merge conflicts, staged, changes, untracked) of `ScmResource`s (path,
  original path, change kind, conflict kind).
- `ScmFeatures`: what a provider supports (staging, partial staging, amend,
  branches, remotes, stash). The UI and the command set are derived from these
  flags, never from the provider id.
- `ScmProvider` / `ScmRepositoryHandle`: detect, refresh, read original
  content at a reference (HEAD, index, commit, conflict stage) and apply an
  `ScmOperation`. Every call is asynchronous, driven by `JobScheduler` steps
  and `OwnedProcess` polling. Nothing blocks `Application.update()`.

Git is the only shipped provider. A fake in-memory provider used by the tests
keeps the boundary VCS-neutral from the first slice. A second real provider is
deferred until someone asks for one.

### 3. The Git provider calls the `git` CLI

It runs `git` through `ProcessManager`, not libgit2 or a reimplementation.

- Status comes from `git status --porcelain=v2 -z --branch`. The format is
  stable, NUL-delimited and locale-independent.
- Original content comes from one long-lived `git cat-file --batch --filters`
  process per repository, fed `<rev>:<path>` lines over stdin. The base text
  then has the same line endings and smudge filters as the working tree. It
  also avoids starting a process per file, which costs tens of milliseconds
  on Windows. The reader is restarted after errors, when the repository
  config changes, and after an idle timeout. Untrusted repositories use
  `--batch` without filters; see section 6.
- The user's config, credential helpers, hooks, worktrees, sparse checkout,
  fsmonitor and LFS all keep working, and no native dependency is added.
- Pathspecs are passed literally (`GIT_LITERAL_PATHSPECS=1`, after `--`).
  Read operations use `--no-optional-locks` so they do not fight the user's
  own commands for `index.lock`. Prompts are disabled
  (`GIT_TERMINAL_PROMPT=0`, `GIT_EDITOR=:`).
- The minimum supported Git version is 2.25. Older or missing Git reports a
  clear unavailable state, never a crash.
- Detection must not have side effects. On macOS, `/usr/bin/git` is a stub
  that opens the Command Line Tools installer when the tools are missing.
  Check `xcode-select -p` before invoking it, or prefer `scm.gitPath` and
  Homebrew locations. Bundling Git, as GitHub Desktop does, is a later option
  if missing Git proves common.

### 4. One service core, two hosts

`ScmService` (in `src/scm/`, headless) owns repository discovery, refresh
scheduling, the per-repository operation queue and snapshots. It has two
hosts:

- **In-process**, for the desktop when no workspace daemon is attached. It is
  driven from `Application.update()` like `BuildController`.
- **Workspace agent**, in `agent/src/workspace/runtime/WorkspaceScmService.hx`.
  It exposes the same core over the typed `WorkspaceScmProtocol` (shared
  `@:wire` records in `src/workspace/service/`) to desktop sockets and to
  connected web/Android clients.

The UI talks to an `ScmSource` interface with `LocalScmSource` and
`RpcScmSource` implementations. This mirrors the existing split between
`DirectoryTreeModel` and `WorkspaceFileTreeModel`. Whichever source supplies
the explorer for a root also supplies its source control.

### 5. Gutter diffs are computed in the client against the live buffer

The client fetches the original text once per (repository, path, base
revision). It then line-diffs it against the open buffer in a time-sliced job.
Gutter markers follow typing with no service round trip, and unsaved edits
show correct markers. The service only sees saved files. Its status says
whether a file differs on disk; the gutter says how the buffer differs from
its base.

### 6. Permissions and repository trust

- **RPC grants.** There are three device grants, following the
  WORKSPACE-PROTOCOL rule that distinct powers get distinct grants:
  - `workspace.scm.read`: snapshots, original content, diffs.
  - `workspace.scm.write`: stage, unstage, discard, commit, branch switch.
  - `workspace.scm.remote`: fetch, pull, push, which are outward-facing.

  A local desktop connection gets all three. A newly paired device gets read
  only unless the owner selects more in the Remote Access approval panel.
  The owner can change an approved device's grants later without pairing
  again. Narrowing a grant takes effect immediately: in-flight work is
  cancelled and affected watches are closed. Terminal control already allows
  arbitrary commands, so the split mainly protects review-only devices.
- **Repository trust.** Repository-local Git configuration can execute
  programs during read-only operations (`core.fsmonitor`) and filter
  operations (`filter.*.smudge`, textconv). A crafted `.git` directory in a
  downloaded folder is therefore an attack vector, not just a misconfiguration.
  Until the user trusts a repository root, the provider runs in restricted
  mode:
  - it passes `-c core.fsmonitor=` and an empty `core.hooksPath`;
  - it reads blobs without `--filters`;
  - it disables mutations.

  Git's own `safe.directory` ownership check is honoured, not bypassed. Trust
  is recorded per repository root on the host that runs Git.

  Trusting a repository lets its config run programs on that host, which is
  equivalent to running code there. Trust can therefore be granted only
  locally: from the in-process host or a local desktop connection. No device
  grant includes it. Remote clients see the restricted state and a message to
  trust the repository on the machine itself.
- **Discard is destructive.** It goes through `ConfirmationService`. Untracked
  files are moved with `TrashService`, not removed by `git clean`. Tracked
  content is captured as a blob before `git restore`, so discard is
  recoverable.

### 7. Shared presentation hooks, not SCM-specific widgets

The UI work adds four generic, owner-scoped hooks that SCM is the first
client of:

- a **gutter marker lane** in `EditorGutter` (later used by diagnostics,
  breakpoints and plugins);
- a **resource decoration provider** for explorer rows (badge, tint,
  tooltip, folder roll-up), feeding the `ExplorerTreeView` cache key;
- **contributed status bar items**, replacing the fixed `StatusBarData`
  slots. This also closes the gap where plugin status items are never shown;
- a **read-only diff document**: a unified diff in an editor tab, using
  existing `WholeLineBackground` decorations and two line-number columns.
  Side-by-side comes later.

Exposing these hooks to dynamic plugins (plugin API v3) is a follow-on, not
part of the SCM delivery.

### 8. Capability

`HostCapability.SourceControl` is derived from `Processes`, the same way
`LanguageServices` is. In connected mode, the client instead uses the
service's negotiated `workspace.scm.*` capabilities. When neither is present,
`scm:*` commands, the sidebar mode and the hooks' SCM contributions are
absent, as the M15.1 policy requires.

## Alternatives considered

- **A dynamic plugin.** Rejected for now for the reasons in Context points 1
  and 2. Building the missing plugin UI surface first would block SCM on a
  plugin API redesign, and would still not run Git where the repository is.
- **libgit2 (or a pure-Haxe Git).** Rejected as the primary backend.
  - It does not run hooks, so commits would skip `pre-commit` and
    `commit-msg` without telling the user.
  - It does not use git credential helpers; auth needs our own callbacks. Its
    default libssh2 transport ignores `~/.ssh/config`, unless it is built
    with the optional OpenSSH exec transport.
  - LFS filters, commit signing, partial clone and parts of sparse checkout
    are missing or have to be reimplemented.
  - Its status is single-threaded and has no fsmonitor support, so it is
    usually slower than `git status` on large repositories.
  - It adds libgit2, libssh2, OpenSSL and zlib as native builds on three
    platforms.

  The CLI's costs are process startup (mitigated by the batch reader),
  output parsing (mitigated by porcelain v2) and requiring Git to be
  installed. VS Code and JetBrains use the CLI, and GitHub Desktop bundles it.
  GitKraken is built on libgit2. The provider interface leaves room for a
  hybrid: a libgit2-backed read-only reader can be added behind
  `GitProvider` if profiling, likely on Windows, shows startup cost
  dominating. Mutations stay on the CLI.
- **Git in the client (web via isomorphic-git or Wasm).** Rejected. The
  browser client deliberately has no filesystem or process access to the
  workspace, and the service already owns both.
- **Git-specific model and UI, generalize later.** Rejected. Using
  groups-and-resources from the start costs little, and the fake provider
  keeps it honest. Generalizing a Git-shaped model later would touch every
  consumer.
- **A server-side diff for the gutter.** Rejected. It would add a round trip
  per keystroke batch, and it would need unsaved buffer contents on the
  service, which M16 explicitly avoids.

## Consequences

- SCM ships without waiting for plugin API v3. Plugins gain gutter, explorer
  and status bar hooks afterwards almost for free.
- Two hosts mean the core must stay headless and host-agnostic. Every
  behavioral test runs against the in-process host. The RPC tests cover only
  the adapter: grants, deduplication, replay and revocation.
- Correct behavior depends on the installed `git` (≥ 2.25). Opt-in tests that
  need it record "pending" when it is absent, per the roadmap rule.
- Restricted mode adds a trust prompt the first time a repository is opened.
  That is deliberate friction, and it is the price of running Git on
  untrusted directories.
- Refresh latency is bounded by debounce and by Git's own status time. Very
  large repositories rely on Git's fsmonitor and untracked cache, which the
  CLI choice preserves.
