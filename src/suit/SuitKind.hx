package suit;

/** How suit stops a process of one kind before it kills what is left of the process tree. */
enum SuitStop {
	/** Ask it to close its windows, so it can save or prompt. Never forced: it may hold unsaved work. */
	CloseWindows;

	/** Write `stop-request.json` for its generation: it stops its daemon and releases its lock, and does not restart. */
	StopRequest;

	/** Stop it through the workspace manager that started it, so the manager neither restarts nor outlives it. */
	ThroughManager;

	/** Kill it with its descendants at once. */
	Kill;
}

/** When a process of one kind counts as orphaned. */
enum SuitOrphanRule {
	/** Never: editors are the roots of ownership. */
	Never;

	/** When no registered editor uses its workspace root. Workspace services are shared by every such editor. */
	NoEditorUsesRoot;

	/** When no editor and no live session runs: Haxeon compiler workers are resident by design. */
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
	var Suit = "suit";
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
			case "suit": SuitKind.Suit;
			default: SuitKind.Other;
		};
	}

	public static function stop(kind:SuitKind):SuitStop {
		return switch kind {
			case SuitKind.Editor: CloseWindows;
			case SuitKind.WorkspaceManager: StopRequest;
			case SuitKind.WorkspaceHost: ThroughManager;
			default: Kill;
		};
	}

	public static function orphanRule(kind:SuitKind):SuitOrphanRule {
		return switch kind {
			case SuitKind.Editor | SuitKind.Suit: Never;
			case SuitKind.WorkspaceManager | SuitKind.WorkspaceHost: NoEditorUsesRoot;
			case SuitKind.CompilerWorker: NoHaxeonUser;
			default: OwnerGone;
		};
	}

	/** A Haxeon process, grouped under "Haxeon" while it is in use. */
	public static function isHaxeon(kind:SuitKind):Bool
		return kind == SuitKind.CompilerWorker || kind == SuitKind.LiveSession || kind == SuitKind.LiveHost;

	/** A workspace service: it has a root and a state directory, where it may publish relay status. */
	public static function isWorkspaceService(kind:SuitKind):Bool
		return kind == SuitKind.WorkspaceManager || kind == SuitKind.WorkspaceHost;

	/** The menu verb for stopping one: editors are closed, not terminated. */
	public static function stopVerb(kind:SuitKind):String
		return stop(kind) == CloseWindows ? "Close" : "Terminate";
}
