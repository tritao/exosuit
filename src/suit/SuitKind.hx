package suit;

/** How suit stops a process of one kind; afterwards it kills the process if it still runs, and its tree (SuitTerminator). */
enum SuitStop {
	/** Ask it to close its windows, so it can save or prompt. Never forced: it may hold unsaved work. */
	CloseWindows;

	/** Write `stop-request.json` for its generation: it stops its daemon and releases its lock, and does not restart. */
	StopRequest;

	/** Stop it through the workspace manager that started it, so the manager neither restarts nor outlives it. */
	ThroughManager;

	/** Kill it at once. The stop's sweep then ends its whole tree (SuitKinds.endsTree), else only its exosuit-kind descendants (SuitLineage). */
	Kill;

	/** Write `end-request.json` in its folder (a terminal host): it ends its program and itself; killed if it does not. */
	EndRequest;
}

/** When a process of one kind counts as orphaned. */
enum SuitOrphanRule {
	/** Never: editors are the roots of ownership. */
	Never;

	/** When no registered editor uses its workspace root. Workspace services are shared by every such editor. */
	NoEditorUsesRoot;

	/**
		When no editor and no live session runs, and no build exosuit did not start uses it (SuitProcess.shared): Haxeon
		compiler workers are resident by design, and shared per compiler and project.
	**/
	NoHaxeonUser;

	/** When the process it belongs to (its recorded owner, or else its parent) is gone. */
	OwnerGone;
}

/**
	What a process suit tracks is. The string is the `kind` in registry records and in `suit list --json`;
	unknown kinds read as `Other`. Everything that depends on the kind is decided in SuitKinds.
**/
enum abstract SuitKind(String) to String {
	var Editor = "editor";
	var WorkspaceManager = "workspace-manager";
	var WorkspaceHost = "workspace-host";
	var CompilerWorker = "compiler-worker";
	var LiveSession = "live-session";
	var LiveHost = "live-host";
	/**
		A terminal host: the process that keeps one terminal alive while its workspace service is stopped
		(docs/design/terminal-host-status.md). It is exosuit's and is listed. Stopping its service or closing its editor
		never ends it, and the automatic orphan sweep never does either; suit's full Quit, `kill --all`, "Terminate all
		background processes", the "end terminals" actions and a stop of that one process do. The polite quit
		(`suit quit --keep-terminals`) leaves it running.
	**/
	var TerminalHost = "terminal-host";
	var Suit = "suit";
	/** An agent provider a workspace daemon runs: claude, codex (app-server, its proxy bridge), pi, the Claude name bridge. */
	var AgentProvider = "agent-provider";
	/** The Haxeon language server an editor runs (`haxeon-lsp.hl`). */
	var LanguageServer = "language-server";
	/** An editor's helper process: the DevTools panel (`scripts/devtools.py`). */
	var HelperProcess = "helper";
	/**
		The source-tree launcher, `python scripts/run.py` (`--live`), found because the run session it started belongs to an
		Exosuit checkout (SuitInventory's checkout pass). It is started by the user, so no sweep reaches it.
	**/
	var DevLauncher = "launcher";
	var Other = "other";
}

/** Per-kind behaviour, in one place: how each kind is parsed, stopped, and judged orphaned. */
class SuitKinds {
	public static function parse(value:Null<String>):SuitKind {
		return switch value {
			case "editor": SuitKind.Editor;
			case "workspace-manager": SuitKind.WorkspaceManager;
			case "workspace-host": SuitKind.WorkspaceHost;
			case "compiler-worker": SuitKind.CompilerWorker;
			case "live-session": SuitKind.LiveSession;
			case "live-host": SuitKind.LiveHost;
			case "terminal-host": SuitKind.TerminalHost;
			case "suit": SuitKind.Suit;
			case "agent-provider": SuitKind.AgentProvider;
			case "language-server": SuitKind.LanguageServer;
			case "helper": SuitKind.HelperProcess;
			case "launcher": SuitKind.DevLauncher;
			default: SuitKind.Other;
		};
	}

	public static function stop(kind:SuitKind):SuitStop {
		return switch kind {
			case SuitKind.Editor: CloseWindows;
			case SuitKind.WorkspaceManager: StopRequest;
			case SuitKind.WorkspaceHost: ThroughManager;
			case SuitKind.TerminalHost: EndRequest;
			default: Kill;
		};
	}

	public static function orphanRule(kind:SuitKind):SuitOrphanRule {
		return switch kind {
			// A terminal host is meant to run with no editor and no service: that is never an orphan.
			case SuitKind.Editor | SuitKind.Suit | SuitKind.TerminalHost: Never;
			case SuitKind.WorkspaceManager | SuitKind.WorkspaceHost: NoEditorUsesRoot;
			case SuitKind.CompilerWorker: NoHaxeonUser;
			default: OwnerGone;
		};
	}

	/**
		A kind exosuit starts itself: a workspace manager starts its daemon, a live session its host and
		compiler workers. Only these are adopted by descent, and only these are swept under a target that does not end its
		whole tree (SuitKinds.endsTree).
		Editors are started by the user, and are never stopped by force. A terminal host is started by a service but is
		not one of these: it must outlive the service, so stopping the service's tree never reaches it.
	**/
	/**
		The argument a helper that runs under a general program (node, hl) carries so suit can tell it is exosuit's:
		`--exosuit-helper=claude-name-bridge` (ClaudeNameBridge), `--exosuit-helper=profiler-bridge` (ProfilerProcess).
		The helpers ignore it.
	**/
	public static inline final HELPER_MARKER = "--exosuit-helper=";

	public static function spawnedByExosuit(kind:SuitKind):Bool {
		return switch kind {
			case SuitKind.WorkspaceManager | SuitKind.WorkspaceHost | SuitKind.CompilerWorker | SuitKind.LiveSession | SuitKind.LiveHost
				| SuitKind.AgentProvider | SuitKind.LanguageServer | SuitKind.HelperProcess: true;
			default: false;
		};
	}

	/**
		True for a kind whose whole OS process tree ends when suit ends it (SuitProcessTree): what an agent provider started
		(MCP servers, tool commands, a dev server), what runs under a workspace service, a live session or a launcher.
		Editors and terminal hosts below are never part of such a tree. A terminal host is not one of these kinds: its
		program ends through its own end path, and its tree is followed only when suit has to kill the host.
	**/
	public static function endsTree(kind:SuitKind):Bool {
		return switch kind {
			case SuitKind.Editor | SuitKind.TerminalHost | SuitKind.Suit | SuitKind.Other: false;
			default: true;
		};
	}

	/** True for a kind that heads its own group in the menu: an editor, with its workspaces' services. */
	public static function headsOwnGroup(kind:SuitKind):Bool
		return kind == SuitKind.Editor;

	/** A Haxeon process, grouped under "Haxeon" while it is in use. */
	public static function isHaxeon(kind:SuitKind):Bool
		return kind == SuitKind.CompilerWorker || kind == SuitKind.LiveSession || kind == SuitKind.LiveHost || kind == SuitKind.DevLauncher;

	/**
		True for a kind that hosts an editor: `scripts/run.py` and the live session it starts run the editor as their child,
		and the session ends once the editor exits. suit stops one only after every editor that ran when the stop began has
		exited (closed when asked, or by itself); while one stays open (unsaved work) it is left running, so the editor is
		never cut off from its session.

		A terminal host is one too: `python scripts/run.py` started in an Exosuit terminal runs the editor below the host,
		and ending the host first would end the editor's chain under it before the editor was asked to close.
	**/
	public static function hostsEditors(kind:SuitKind):Bool
		return kind == SuitKind.LiveSession || kind == SuitKind.DevLauncher || kind == SuitKind.TerminalHost;

	/** A workspace service: it has a root and a state directory, where it may publish relay status. */
	public static function isWorkspaceService(kind:SuitKind):Bool
		return kind == SuitKind.WorkspaceManager || kind == SuitKind.WorkspaceHost;

	/** True for a kind the polite quit (`suit quit --keep-terminals`) leaves running: terminal hosts. */
	public static function keptByPoliteQuit(kind:SuitKind):Bool
		return kind == SuitKind.TerminalHost;

	/** The menu verb for stopping one: editors are closed, not terminated. */
	public static function stopVerb(kind:SuitKind):String
		return switch stop(kind) {
			case CloseWindows: "Close";
			case EndRequest: "End terminal";
			default: "Terminate";
		};
}
