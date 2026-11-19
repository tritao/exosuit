package ui.shell.phone;

import workspace.sessions.SessionIndex.SessionKind;
import workspace.sessions.SessionIndex.SessionQuery;
import workspace.sessions.SessionIndex.SessionSectioning;

/**
	The list filters. They live in PhoneShell, not in a screen, so leaving a terminal returns to the list as it was
	(ADR 0007: scope is a filter, Back belongs to screens).
**/
class PhoneState {
	/** The workspace the list is scoped to; null is the whole machine (All sessions). */
	public var workspace:Null<String>;
	public var groups:Array<String> = [];
	public var kinds:Array<SessionKind> = [];
	public var workspaces:Array<String> = [];
	public var text:String = "";
	/** The Sessions screen's sectioning (Group or None) and the All sessions screen's (State, Workspace, Group, Day). */
	public var sessionsSectioning:SessionSectioning = Group;
	public var allSectioning:SessionSectioning = State;
	/** Section ids the person folded. */
	public final collapsed:Map<String, Bool> = [];

	public function new() {}

	public function sessionsQuery():SessionQuery {
		return {
			workspaces: workspace == null ? [] : [workspace],
			groups: groups,
			kinds: kinds,
			sectioning: sessionsSectioning
		};
	}

	public function allQuery():SessionQuery {
		return {
			workspaces: workspaces,
			groups: groups,
			kinds: kinds,
			text: text,
			sectioning: allSectioning
		};
	}

	public static function sectioningLabel(value:SessionSectioning):String
		return switch value {
			case None: "none";
			case Workspace: "workspace";
			case Group: "group";
			case State: "state";
			case Day: "day";
		};
}
