package suit;

import suit.SuitInventory.SuitProcess;
import suit.SuitTerminator.TerminationResult;

/** Text and JSON views of an inventory, shared by the CLI, the viewer and the daemon. */
class SuitReport {
	public static function uptime(started:Float):String {
		if (started <= 0)
			return "?";
		var seconds = Std.int(Math.max(0, (Date.now().getTime() - started) / 1000));
		if (seconds < 60)
			return seconds + "s";
		var minutes = Std.int(seconds / 60);
		if (minutes < 60)
			return minutes + "m";
		var hours = Std.int(minutes / 60);
		if (hours < 48)
			return hours + "h" + pad(minutes % 60) + "m";
		return Std.int(hours / 24) + "d" + (hours % 24) + "h";
	}

	static function pad(value:Int):String
		return value < 10 ? "0" + value : Std.string(value);

	static function column(text:String, width:Int):String {
		var result = text.length > width ? text.substr(0, width - 1) + "…" : text;
		while (result.length < width)
			result += " ";
		return result;
	}

	public static function workspace(process:SuitProcess):String {
		if (process.root != null)
			return SuitInventory.workspaceName(process.root);
		if (process.roots.length > 0)
			return [for (root in process.roots) SuitInventory.workspaceName(root)].join(", ");
		return "";
	}

	/** Short label for a menu item: kind, workspace, uptime. */
	public static function label(process:SuitProcess):String {
		var parts = [process.kind];
		var name = workspace(process);
		if (name.length > 0)
			parts.push(name);
		parts.push(uptime(process.started));
		var text = parts.join(" · ") + "  (pid " + process.pid + ")";
		if (!process.registered)
			text += " unregistered";
		return text;
	}

	public static function relayState(process:SuitProcess):String {
		var relay = process.relay;
		if (relay == null)
			return "";
		if (relay.error != null)
			return "error: " + relay.error;
		if (relay.connected)
			return "connected";
		return relay.updatedAt > 0 ? "reconnecting" : "configured";
	}

	public static function text(inventory:SuitInventory, daemon:Null<Bool>):String {
		var output = new StringBuf();
		output.add(inventory.summary() + "\n");
		if (daemon != null)
			output.add("suit daemon: " + (daemon ? "running" : "not running") + "\n");
		if (!inventory.scanning)
			output.add("(scanning disabled; registered processes only)\n");
		var group:Null<String> = null;
		for (process in inventory.processes) {
			if (process.group != group) {
				group = process.group;
				output.add("\n" + group + "\n");
			}
			var notes:Array<String> = [];
			if (!process.registered)
				notes.push("unregistered");
			if (process.orphaned)
				notes.push("orphaned");
			var relay = relayState(process);
			if (relay.length > 0)
				notes.push("relay " + relay);
			output.add("  " + column(Std.string(process.pid), 7) + column(process.kind, 19) + column(workspace(process), 22)
				+ column(uptime(process.started), 8) + notes.join(", ") + "\n");
		}
		if (inventory.processes.length == 0)
			output.add("\nNo exosuit processes are running.\n");
		return output.toString();
	}

	public static function processJson(process:SuitProcess):Dynamic {
		return {
			pid: process.pid,
			started: process.started,
			parent: process.parent,
			kind: process.kind,
			registered: process.registered,
			orphaned: process.orphaned,
			group: process.group,
			workspace: workspace(process),
			root: process.root,
			roots: process.roots,
			stateDir: process.stateDir,
			owner: process.owner,
			uptimeSeconds: process.started > 0 ? Std.int((Date.now().getTime() - process.started) / 1000) : null,
			relay: process.relay,
			commandLine: process.commandLine
		};
	}

	public static function json(inventory:SuitInventory, daemon:Null<Bool>):Dynamic {
		return {
			version: 1,
			summary: inventory.summary(),
			daemon: daemon,
			scanning: inventory.scanning,
			editors: inventory.editors().length,
			background: inventory.background().length,
			orphaned: inventory.orphans().length,
			processes: [for (process in inventory.processes) processJson(process)]
		};
	}

	public static function relayText(inventory:SuitInventory):String {
		var hosted = inventory.hosted();
		if (hosted.length == 0)
			return "No workspace is hosting remote access.\n";
		var output = new StringBuf();
		for (process in hosted) {
			var relay = process.relay;
			if (relay == null)
				continue;
			output.add(column(workspace(process), 22) + column(relayState(process), 16)
				+ (relay.origin == null ? "" : relay.origin) + "  (pid " + process.pid + ")\n");
			output.add("    root: " + process.root + "\n");
			for (device in relay.devices)
				output.add("    device " + device.deviceId + (device.revoked ? " revoked" : device.connected ? " connected" : " paired") + "\n");
			if (relay.pending > 0)
				output.add("    " + relay.pending + " pairing request(s) waiting for approval\n");
		}
		return output.toString();
	}

	public static function results(results:Array<TerminationResult>):String {
		if (results.length == 0)
			return "Nothing to terminate.\n";
		return [for (result in results) '${result.pid} ${result.kind}: ${result.outcome}'].join("\n") + "\n";
	}
}
