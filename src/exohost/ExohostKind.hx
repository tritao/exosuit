package exohost;

/** How exohost stops a process of one kind; afterwards it kills the process if it still runs, and its tree (ExohostTerminator). */
enum ExohostStop {
	/**
		Ask it over its exohost link to quit (`exosuit.quit`), so it saves its session and keeps or asks about unsaved work.
		Never forced: it may hold unsaved work.
	**/
	QuitRequest;

	/**
		Ask it over its exohost link to stop (a workspace service): it ends its agent processes and releases its lock; its
		terminals carry on in their hosts.
	**/
	ServiceStop;

	/**
		Kill it at once. The stop's sweep then ends its whole tree (ExohostKinds.endsTree; for a terminal host, its program's),
		else only its exosuit-kind descendants (ExohostLineage).
	**/
	Kill;
}

/** When a process of one kind counts as orphaned. */
enum ExohostOrphanRule {
	/** Never: editors are the roots of ownership. */
	Never;

	/** When no registered editor uses its workspace root. Workspace services are shared by every such editor. */
	NoEditorUsesRoot;

	/**
		When no editor and no live session runs, and no build exosuit did not start uses it (ExohostProcess.shared): Haxeon
		compiler workers are resident by design, and shared per compiler and project.
	**/
	NoHaxeonUser;

	/** When the process it belongs to (its recorded owner, or else its parent) is gone. */
	OwnerGone;
}

/**
	What a process exohost tracks is. The string is the `kind` in registry records and in `exohost list --json`;
	unknown kinds read as `Other`. Everything that depends on the kind is decided in ExohostKinds.
**/
enum abstract ExohostKind(String) to String {
	var Editor = "editor";
	/** A workspace's service: one process per running workspace, which exohost starts. */
	var WorkspaceHost = "workspace-host";
	/**
		The warm spare exohost keeps while an editor is linked (`exosuit-agent.hl --spare`): a service process with no
		workspace yet. The workspace opened next adopts it; it then reports and is listed as that workspace's service.
	**/
	var WorkspaceSpare = "workspace-spare";
	var CompilerWorker = "compiler-worker";
	var LiveSession = "live-session";
	var LiveHost = "live-host";
	/**
		A terminal host: the process that keeps one terminal alive while its workspace service is stopped
		(docs/design/terminal-host-status.md). It is exosuit's and is listed. Stopping its service or closing its editor
		never ends it, and the automatic orphan sweep never does either; exohost's full Quit, `kill --all`, "Terminate all
		background processes", the "end terminals" actions and a stop of that one process do. The polite quit
		(`exohost quit --keep-terminals`) leaves it running.
	**/
	var TerminalHost = "terminal-host";
	var Exohost = "exohost";
	/** An agent provider a workspace daemon runs: claude, codex (app-server, its proxy bridge), pi, the Claude name bridge. */
	var AgentProvider = "agent-provider";
	/** The Haxeon language server an editor runs (`haxeon-lsp.hl`). */
	var LanguageServer = "language-server";
	/** An editor's helper process: the DevTools panel (`scripts/devtools.py`). */
	var HelperProcess = "helper";
	/**
		The source-tree launcher, `python scripts/run.py` (`--live`), found because the run session it started belongs to an
		Exosuit checkout (ExohostInventory's checkout pass). It is started by the user, so no sweep reaches it.
	**/
	var DevLauncher = "launcher";
	var Other = "other";
}

/** Per-kind behaviour, in one place: how each kind is parsed, stopped, and judged orphaned. */
class ExohostKinds {
	public static function parse(value:Null<String>):ExohostKind {
		return switch value {
			case "editor": ExohostKind.Editor;
			case "workspace-host": ExohostKind.WorkspaceHost;
			case "workspace-spare": ExohostKind.WorkspaceSpare;
			case "compiler-worker": ExohostKind.CompilerWorker;
			case "live-session": ExohostKind.LiveSession;
			case "live-host": ExohostKind.LiveHost;
			case "terminal-host": ExohostKind.TerminalHost;
			case "exohost": ExohostKind.Exohost;
			case "agent-provider": ExohostKind.AgentProvider;
			case "language-server": ExohostKind.LanguageServer;
			case "helper": ExohostKind.HelperProcess;
			case "launcher": ExohostKind.DevLauncher;
			default: ExohostKind.Other;
		};
	}

	public static function stop(kind:ExohostKind):ExohostStop {
		return switch kind {
			case ExohostKind.Editor: QuitRequest;
			case ExohostKind.WorkspaceHost | ExohostKind.WorkspaceSpare: ServiceStop;
			default: Kill;
		};
	}

	public static function orphanRule(kind:ExohostKind):ExohostOrphanRule {
		return switch kind {
			// A terminal host is meant to run with no editor and no service: that is never an orphan.
			case ExohostKind.Editor | ExohostKind.Exohost | ExohostKind.TerminalHost: Never;
			// A spare ends by itself when its link to exohost closes.
			case ExohostKind.WorkspaceSpare: Never;
			case ExohostKind.WorkspaceHost: NoEditorUsesRoot;
			case ExohostKind.CompilerWorker: NoHaxeonUser;
			default: OwnerGone;
		};
	}

	/**
		A kind exosuit starts itself: exohost starts workspace services, a live session its host and
		compiler workers. Only these are adopted by descent, and only these are swept under a target that does not end its
		whole tree (ExohostKinds.endsTree).
		Editors are started by the user, and are never stopped by force. A terminal host is started by a service but is
		not one of these: it must outlive the service, so stopping the service's tree never reaches it.
	**/
	/**
		The argument a helper that runs under a general program (node, hl) carries so exohost can tell it is exosuit's:
		`--exosuit-helper=claude-name-bridge` (ClaudeNameBridge), `--exosuit-helper=profiler-bridge` (ProfilerProcess).
		The helpers ignore it.
	**/
	public static inline final HELPER_MARKER = "--exosuit-helper=";

	public static function spawnedByExosuit(kind:ExohostKind):Bool {
		return switch kind {
			case ExohostKind.WorkspaceHost | ExohostKind.WorkspaceSpare | ExohostKind.CompilerWorker | ExohostKind.LiveSession | ExohostKind.LiveHost
				| ExohostKind.AgentProvider | ExohostKind.LanguageServer | ExohostKind.HelperProcess: true;
			default: false;
		};
	}

	/**
		True for a kind whose whole OS process tree ends when exohost ends it (ExohostProcessTree): what an agent provider started
		(MCP servers, tool commands, a dev server), what runs under a workspace service, a live session or a launcher.
		Editors and terminal hosts below are never part of such a tree. A terminal host is not one of these kinds: the tree
		below it is the user's program, followed only when exohost itself ends the host (ExohostTerminator).
	**/
	public static function endsTree(kind:ExohostKind):Bool {
		return switch kind {
			case ExohostKind.Editor | ExohostKind.TerminalHost | ExohostKind.Exohost | ExohostKind.Other: false;
			default: true;
		};
	}

	/** True for a kind that heads its own group in the menu: an editor, with its workspaces' services. */
	public static function headsOwnGroup(kind:ExohostKind):Bool
		return kind == ExohostKind.Editor;

	/** A Haxeon process, grouped under "Haxeon" while it is in use. */
	public static function isHaxeon(kind:ExohostKind):Bool
		return kind == ExohostKind.CompilerWorker || kind == ExohostKind.LiveSession || kind == ExohostKind.LiveHost || kind == ExohostKind.DevLauncher;

	/**
		True for a kind that hosts an editor: `scripts/run.py` and the live session it starts run the editor as their child,
		and the session ends once the editor exits. exohost stops one only after every editor that ran when the stop began has
		exited (closed when asked, or by itself); while one stays open (unsaved work) it is left running, so the editor is
		never cut off from its session.

		A terminal host is one too: `python scripts/run.py` started in an Exosuit terminal runs the editor below the host,
		and ending the host first would end the editor's chain under it before the editor was asked to close.
	**/
	public static function hostsEditors(kind:ExohostKind):Bool
		return kind == ExohostKind.LiveSession || kind == ExohostKind.DevLauncher || kind == ExohostKind.TerminalHost;

	/** A workspace service: it has a root and a state directory, where it may publish relay status. */
	public static function isWorkspaceService(kind:ExohostKind):Bool
		return kind == ExohostKind.WorkspaceHost;

	/** True for a kind the polite quit (`exohost quit --keep-terminals`) leaves running: terminal hosts. */
	public static function keptByPoliteQuit(kind:ExohostKind):Bool
		return kind == ExohostKind.TerminalHost;

	/** The menu verb for stopping one: editors are closed, not terminated. */
	public static function stopVerb(kind:ExohostKind):String
		return kind == ExohostKind.TerminalHost ? "End terminal" : switch stop(kind) {
			case QuitRequest: "Close";
			default: "Terminate";
		};
}
