package suit;

/** How suit knows a process. Only registered and adopted processes are exosuit's. */
enum SuitSource {
	/** It wrote its own registry record. */
	Registered;

	/** Found by scanning as a descendant of a registered process; suit wrote a record for it. */
	Adopted;

	/** Found by scanning with nothing tying it to exosuit, such as a compiler worker of a terminal build. */
	Scanned;
}

/** The menu and list sections, in display order. */
enum SuitGroup {
	/** Processes of one editor: the editor, and workspace services for roots it uses. */
	EditorGroup(editor:Int);

	/** Haxeon compiler workers and live sessions while an exosuit editor or live session uses them. */
	HaxeonGroup;

	/** Exosuit's processes that belong to no editor but are still in use. */
	OtherGroup;

	/** Terminal hosts: terminals kept running without their workspace service. No bulk stop but "End all terminals" ends them. */
	TerminalsGroup;

	OrphanedGroup;

	/** Found by scanning but not started by exosuit: listed, never included in a bulk stop. */
	NotStartedByExosuit;
}

class SuitGroups {
	public static function rank(group:SuitGroup):Int {
		return switch group {
			case EditorGroup(_): 0;
			case HaxeonGroup: 1;
			case OtherGroup: 2;
			case TerminalsGroup: 3;
			case OrphanedGroup: 4;
			case NotStartedByExosuit: 5;
		};
	}

	public static function same(left:SuitGroup, right:SuitGroup):Bool {
		if (rank(left) != rank(right))
			return false;
		return editorOf(left) == editorOf(right);
	}

	/** The editor pid of an editor's group, or -1. */
	public static function editorOf(group:SuitGroup):Int {
		return switch group {
			case EditorGroup(editor): editor;
			default: -1;
		};
	}
}
