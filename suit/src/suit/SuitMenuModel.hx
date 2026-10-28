package suit;

import suit.SuitGroup;
import suit.SuitInventory.SuitProcess;

/** Where a menu is built: the native tray popup, or text for `suit menu` and tests. Parents are submenu ids; 0 is the root. */
interface SuitMenuSink {
	/** A command item; disabled (a label) when `action` is null. */
	function item(label:String, action:Null<Void->Void>, parent:Int):Void;
	function submenu(label:String, parent:Int):Int;
	function separator(parent:Int):Void;
	/** A checkbox item. */
	function check(label:String, checked:Bool, action:Void->Void, parent:Int):Void;
}

/** What the menu's commands do; the daemon supplies the real ones. */
typedef SuitMenuHandlers = {
	var terminate:Array<SuitProcess>->Void;
	var openViewer:Array<String>->Void;
	var quit:Void->Void;
	/** Relay hosting and Start at login; where the menu is only printed, suit's published state is shown. */
	@:optional var hosting:suit.relay.SuitRelayMenu.SuitHostingActions;
}

/**
	The tray menu: a title with counts, processes grouped by editor (orphans, then processes exosuit did not
	start, last), remote access, then bulk actions. Bulk actions cover only exosuit's processes; one not
	started by exosuit can still be terminated from its own submenu.
**/
class SuitMenuModel {
	static inline var GROUP_LIMIT:Int = 30;

	/** For `suit menu`: hosting as the running daemon published it; the commands do nothing. */
	static function printedHosting():suit.relay.SuitRelayMenu.SuitHostingActions
		return {
			hosts: suit.relay.SuitRelayHosting.readViews,
			stopHosting: function(_) {},
			resumeHosting: function(_) {},
			disconnect: function(_) {},
			loginEnabled: SuitLogin.enabled,
			toggleLogin: function() {}
		};

	public static function build(menu:SuitMenuSink, inventory:SuitInventory, handlers:SuitMenuHandlers):Void {
		menu.item(inventory.summary(), null, 0);
		var group:Null<SuitGroup> = null, shown = 0;
		for (process in inventory.processes) {
			if (group == null || !SuitGroups.same(process.group, group)) {
				group = process.group;
				shown = 0;
				menu.separator(0);
				menu.item(inventory.groupLabel(process.group), null, 0);
			}
			if (shown++ >= GROUP_LIMIT) {
				if (shown == GROUP_LIMIT + 1)
					menu.item("    … more in the process viewer", null, 0);
				continue;
			}
			var target = process;
			var entry = menu.submenu("    " + SuitReport.label(process), 0);
			var relay = SuitReport.relayState(process);
			if (relay.length > 0)
				menu.item("Remote access: " + relay, null, entry);
			var source = SuitReport.sourceNote(process);
			if (source.length > 0)
				menu.item(source, null, entry);
			menu.item(SuitKind.SuitKinds.stopVerb(process.kind), function() handlers.terminate([target]), entry);
		}
		var hosting = handlers.hosting != null ? handlers.hosting : printedHosting();
		suit.relay.SuitRelayMenu.build(menu, inventory, hosting, handlers.openViewer);
		menu.separator(0);
		var orphans = inventory.orphans();
		menu.item("Terminate orphaned processes (" + orphans.length + ")",
			orphans.length == 0 ? null : function() handlers.terminate(SuitActions.orphans(inventory)), 0);
		var background = inventory.background();
		menu.item("Terminate all background processes (" + background.length + ")",
			background.length == 0 ? null : function() handlers.terminate(SuitActions.background(inventory)), 0);
		menu.item("Open process viewer…", function() handlers.openViewer(["watch"]), 0);
		suit.relay.SuitRelayMenu.login(menu, hosting);
		menu.separator(0);
		menu.item("Quit Exosuit", handlers.quit, 0);
	}
}

/** Renders a menu as indented text; disabled items in brackets. */
class SuitTextMenu implements SuitMenuSink {
	final lines:Array<String> = [];
	final depth:Map<Int, Int> = [0 => 0];
	var nextId:Int = 1;

	public function new() {}

	public function item(label:String, action:Null<Void->Void>, parent:Int):Void
		lines.push(indent(parent) + (action == null ? "[" + StringTools.trim(label) + "]" : StringTools.trim(label)));

	public function submenu(label:String, parent:Int):Int {
		var id = nextId++;
		depth.set(id, level(parent) + 1);
		lines.push(indent(parent) + StringTools.trim(label) + " >");
		return id;
	}

	public function separator(parent:Int):Void
		lines.push(indent(parent) + "----");

	public function check(label:String, checked:Bool, action:Void->Void, parent:Int):Void
		lines.push(indent(parent) + (checked ? "[x] " : "[ ] ") + StringTools.trim(label));

	function indent(parent:Int):String {
		var result = "";
		for (_ in 0...level(parent))
			result += "    ";
		return result;
	}

	function level(parent:Int):Int {
		var value = depth.get(parent);
		return value == null ? 0 : value;
	}

	public function toString():String
		return lines.join("\n");
}
