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
	/** The full Quit: ends everything exosuit started, terminal hosts included. */
	var quit:Void->Void;
	/** The polite quit: ends everything but terminal hosts. */
	@:optional var quitKeepingTerminals:Void->Void;
	/** Relay hosting and Start at login; where the menu is only printed, suit's published state is shown. */
	@:optional var hosting:suit.relay.SuitRelayMenu.SuitHostingActions;
	/** What is connected from outside (paired devices, remote access); only the daemon has it. */
	@:optional var remote:SuitRemoteActions;
}

typedef SuitRemoteActions = {
	/** A `remote-devices` reply: `devices`, `workspaces`, `pending`. */
	var devices:Void->Dynamic;
	var enabled:Void->Bool;
	var disconnect:String->Void;
	var revoke:String->Void;
	var off:Void->Void;
}

/**
	The tray menu: a title with counts, processes grouped by editor (terminal hosts, orphans, then processes
	exosuit did not start, last), remote access, then bulk actions. Bulk actions cover only exosuit's processes; one not
	started by exosuit can still be terminated from its own submenu. Terminal hosts are ended by "Terminate all
	background processes", "End all terminals" (and its per-workspace entries), their own submenus and the full Quit,
	which says how many it ends; "Quit, keep terminals running" leaves them.
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
			retry: function(_) {},
			dismiss: function(_) {},
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
		if (handlers.remote != null)
			remoteSection(menu, handlers.remote);
		menu.separator(0);
		var orphans = inventory.orphans();
		menu.item("Terminate orphaned processes (" + orphans.length + ")",
			orphans.length == 0 ? null : function() handlers.terminate(SuitActions.orphans(inventory)), 0);
		var background = inventory.background();
		menu.item("Terminate all background processes (" + background.length + ")",
			background.length == 0 ? null : function() handlers.terminate(SuitActions.background(inventory)), 0);
		// The orphan sweep never ends terminal hosts; "all background processes" above and the full Quit do. These end only them.
		var terminals = inventory.terminals();
		menu.item("End all terminals (" + terminals.length + ")",
			terminals.length == 0 ? null : function() handlers.terminate(SuitActions.terminals(inventory)), 0);
		var workspaces = SuitActions.terminalWorkspaces(inventory);
		if (workspaces.length > 1)
			for (workspace in workspaces) {
				var key = workspace.key;
				menu.item("    End terminals of " + workspace.label + " (" + workspace.count + ")",
					function() handlers.terminate(SuitActions.terminals(inventory, key)), 0);
			}
		menu.item("Open process viewer…", function() handlers.openViewer(["watch"]), 0);
		suit.relay.SuitRelayMenu.login(menu, hosting);
		menu.separator(0);
		menu.item(terminals.length == 0 ? "Quit Exosuit and end everything" : "Quit Exosuit and end everything (" + terminals.length
			+ (terminals.length == 1 ? " terminal)" : " terminals)"), handlers.quit, 0);
		if (terminals.length > 0)
			menu.item("Quit, keep terminals running (" + terminals.length + ")", handlers.quitKeepingTerminals, 0);
	}

	/** Paired devices, each with its state and Disconnect now / Revoke pairing, then Turn remote access off. */
	static function remoteSection(menu:SuitMenuSink, remote:SuitRemoteActions):Void {
		var listing:Dynamic = null;
		try listing = remote.devices() catch (_:Dynamic) {}
		var devices:Array<Dynamic> = listing != null && Std.isOfType(Reflect.field(listing, "devices"), Array) ? Reflect.field(listing, "devices") : [];
		if (devices.length == 0 && !remote.enabled())
			return;
		menu.separator(0);
		menu.item("Paired devices (" + devices.length + ")", null, 0);
		var names = new Map<String, String>();
		var workspaces:Dynamic = listing == null ? null : Reflect.field(listing, "workspaces");
		if (Std.isOfType(workspaces, Array))
			for (entry in (workspaces : Array<Dynamic>))
				names.set(Std.string(entry.id), Std.string(entry.name));
		var live = 0;
		for (device in devices) {
			var id = Std.string(device.deviceId);
			var entry = menu.submenu("    " + StringTools.trim(SuitReport.deviceLine(device, names)), 0);
			if (device.connected == true) {
				live++;
				menu.item("Disconnect now (it may reconnect)", function() remote.disconnect(id), entry);
			} else
				menu.item("Not connected", null, entry);
			menu.item("Revoke pairing (cut off for good)", device.revoked == true ? null : function() remote.revoke(id), entry);
		}
		menu.item("Turn remote access off (" + live + " connected)", remote.enabled() ? remote.off : null, 0);
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
