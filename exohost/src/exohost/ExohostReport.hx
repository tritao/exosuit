package exohost;

import exohost.ExohostGroup;
import exohost.ExohostKind;
import exohost.ExohostInventory.ExohostProcess;
import exohost.ExohostTerminator.TerminationResult;

/** Text and JSON views of an inventory, shared by the CLI, the viewer and the daemon. */
class ExohostReport {
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

	public static function workspace(process:ExohostProcess):String {
		if (process.root != null)
			return ExohostInventory.workspaceName(process.root);
		if (process.roots.length > 0)
			return [for (root in process.roots) ExohostInventory.workspaceName(root)].join(", ");
		// A terminal host started by an older build names no folder: show the workspace's id, else its state folder.
		if (process.kind == ExohostKind.TerminalHost)
			return process.workspace != null ? process.workspace : ExohostInventory.workspaceName(process.stateDir);
		return "";
	}

	/** Which terminal a host keeps: its name (else its id, else its folder's name) and the program in it; empty for other kinds. */
	public static function terminal(process:ExohostProcess):String {
		var info = process.terminal;
		if (info == null)
			return "";
		var name = info.name != null ? info.name : info.terminal != null ? info.terminal : ExohostInventory.workspaceName(info.directory);
		var program = info.program == null ? "" : ExohostInventory.workspaceName(info.program);
		return "terminal \"" + name + "\"" + (program.length > 0 ? " (" + program + ")" : "");
	}

	/** Short label for a menu item: kind, workspace, uptime. */
	public static function label(process:ExohostProcess):String {
		var parts:Array<String> = [process.kind];
		var name = workspace(process);
		if (name.length > 0)
			parts.push(name);
		var kept = terminal(process);
		if (kept.length > 0)
			parts.push(kept);
		if (process.shared)
			parts.push(SHARED_NOTE);
		parts.push(uptime(process.started));
		return parts.join(" · ") + "  (pid " + process.pid + ")";
	}

	/** How exohost knows a process, when it did not register itself; empty when it did. */
	public static function sourceNote(process:ExohostProcess):String {
		return switch process.source {
			case Registered: "";
			case Adopted: process.owner == null ? "Started by exosuit; found by scanning" : "Started by exosuit process " + process.owner + "; found by scanning";
			case Scanned: "Not started by exosuit; found by scanning";
		};
	}

	public static function sourceName(source:ExohostSource):String {
		return switch source {
			case Registered: "registered";
			case Adopted: "adopted";
			case Scanned: "scanned";
		};
	}

	public static function text(inventory:ExohostInventory, daemon:Null<Bool>):String {
		var output = new StringBuf();
		output.add(inventory.summary() + "\n");
		if (daemon != null)
			output.add("exohost daemon: " + (daemon ? "running" : "not running") + "\n");
		if (!inventory.scanning)
			output.add("(scanning disabled; registered processes only)\n");
		var group:Null<ExohostGroup> = null;
		for (process in inventory.processes) {
			if (group == null || !ExohostGroups.same(process.group, group)) {
				group = process.group;
				output.add("\n" + inventory.groupLabel(process.group) + "\n");
			}
			var notes:Array<String> = [];
			if (process.source == Adopted)
				notes.push("found by scanning, not registered");
			if (process.orphaned)
				notes.push("orphaned");
			if (process.shared)
				notes.push(SHARED_NOTE);
			var kept = terminal(process);
			if (kept.length > 0)
				notes.push(kept);
			var below = children(inventory, process);
			if (below != null && below > 0)
				notes.push(below + (below == 1 ? " child process" : " child processes"));
			output.add("  " + column(Std.string(process.pid), 7) + column((process.kind : String), 19) + column(workspace(process), 22)
				+ column(uptime(process.started), 8) + notes.join(", ") + "\n");
		}
		if (inventory.processes.length == 0)
			output.add("\nNo exosuit processes are running.\n");
		if (inventory.terminals().length > 0)
			output.add("\n" + TERMINALS_HINT + "\n");
		return output.toString();
	}

	/** How a shared compiler worker (ExohostProcess.shared) is labelled: a build exosuit did not start uses it, so no bulk stop ends it. */
	public static inline var SHARED_NOTE:String = "shared with your builds";

	public static inline var TERMINALS_HINT:String = "Terminals outlive their editor and service. `exohost quit` ends them with everything else; `exohost quit --keep-terminals` leaves them running; `exohost terminals end --all` (or `<workspace>`) ends only them.";

	/** What the polite quit says about the terminals it leaves, or an empty string when there are none. */
	public static function keptTerminals(count:Int):String
		return count == 0 ? "" : '$count ${count == 1 ? "terminal keeps" : "terminals keep"} running, and exohost stays up to list ${count == 1 ? "it" : "them"}; end ${count == 1 ? "it" : "them"} with `exohost terminals end --all` or `exohost quit`.';

	/** `exohost terminals`: every terminal host, one per line, with its workspace. */
	public static function terminalsText(inventory:ExohostInventory):String {
		var output = new StringBuf();
		var hosts = inventory.terminals();
		for (process in hosts)
			output.add(column(Std.string(process.pid), 7) + column(workspace(process), 22) + column(uptime(process.started), 8) + terminal(process) + "\n");
		for (process in inventory.foreign())
			if (process.kind == ExohostKind.TerminalHost)
				output.add(column(Std.string(process.pid), 7) + column(workspace(process), 22) + column(uptime(process.started), 8) + terminal(process)
					+ "  (not started by this exosuit; end it with `exohost kill " + process.pid + "`)\n");
		if (hosts.length == 0)
			output.add("No terminal is kept running.\n");
		else
			output.add(TERMINALS_HINT + "\n");
		return output.toString();
	}

	public static function processJson(inventory:ExohostInventory, process:ExohostProcess):Dynamic {
		return {
			pid: process.pid,
			started: process.started,
			parent: process.parent,
			kind: (process.kind : String),
			registered: process.source == Registered,
			source: sourceName(process.source),
			startedByExosuit: process.source != Scanned,
			orphaned: process.orphaned,
			shared: process.shared,
			group: inventory.groupLabel(process.group),
			workspace: workspace(process),
			root: process.root,
			roots: process.roots,
			stateDir: process.stateDir,
			owner: process.owner,
			uptimeSeconds: process.started > 0 ? Std.int((Date.now().getTime() - process.started) / 1000) : null,
			terminal: process.terminal,
			children: children(inventory, process),
			commandLine: process.commandLine
		};
	}

	/**
		How many processes run under an agent provider (MCP servers, tool commands, a dev server it started): its whole tree,
		which ends with it (ExohostProcessTree). Null for other kinds.
	**/
	public static function children(inventory:ExohostInventory, process:ExohostProcess):Null<Int> {
		if (process.kind != ExohostKind.AgentProvider || process.started <= 0)
			return null;
		var editors = inventory.editors();
		var tree = new ExohostProcessTree(inventory.snapshot, function(info) {
			for (editor in editors)
				if (editor.pid == info.pid && editor.started == info.started)
					return true;
			return false;
		});
		return tree.descendants(process.pid, process.started, Sys.getPid()).length;
	}

	public static function json(inventory:ExohostInventory, daemon:Null<Bool>):Dynamic {
		return {
			version: 1,
			summary: inventory.summary(),
			daemon: daemon,
			scanning: inventory.scanning,
			editors: inventory.editors().length,
			background: inventory.background().length,
			orphaned: inventory.orphans().length,
			terminals: inventory.terminals().length,
			notStartedByExosuit: inventory.foreign().length,
			processes: [for (process in inventory.processes) processJson(inventory, process)]
		};
	}

	/** Every kind exohost knows, in the order `exohost list --all` counts them. */
	public static final ALL_KINDS:Array<ExohostKind> = [ExohostKind.Editor, ExohostKind.WorkspaceHost, ExohostKind.WorkspaceSpare, ExohostKind.CompilerWorker,
		ExohostKind.LiveSession, ExohostKind.LiveHost, ExohostKind.TerminalHost, ExohostKind.AgentProvider, ExohostKind.LanguageServer, ExohostKind.HelperProcess,
		ExohostKind.DevLauncher, ExohostKind.Other];

	/**
		`exohost list --all`'s counts, per kind: exosuit's (registered, and found by scanning: adopted), and found but not
		started by this exosuit. Then the daemon itself and what is connected from outside (`daemon`: a `status` reply,
		`remote`: a `remote-status` reply, `devices`: a `remote-devices` reply; null when the daemon is not running).
	**/
	public static function kindsJson(inventory:ExohostInventory, daemon:Dynamic, remote:Dynamic, devices:Dynamic):Dynamic {
		var kinds:Dynamic = {};
		for (kind in ALL_KINDS) {
			var registered = 0, found = 0, foreign = 0;
			for (process in inventory.processes)
				if (process.kind == kind)
					switch process.source {
						case Registered: registered++;
						case Adopted: found++;
						case Scanned: foreign++;
					}
			Reflect.setField(kinds, (kind : String), {exosuit: registered + found, registered: registered, found: found, notStartedByExosuit: foreign});
		}
		var listed:Array<Dynamic> = devices != null && Std.isOfType(Reflect.field(devices, "devices"), Array) ? Reflect.field(devices, "devices") : [];
		var connected = 0;
		for (device in listed)
			if (device.connected == true)
				connected++;
		return {
			kinds: kinds,
			daemon: daemon == null ? null : {pid: Reflect.field(daemon, "pid"), terminating: Reflect.field(daemon, "terminating")},
			remote: remote == null ? null : {enabled: Reflect.field(remote, "enabled"), relayConnected: Reflect.field(remote, "connected"),
				sessions: Reflect.field(remote, "sessions"), origin: Reflect.field(remote, "origin")},
			pairedDevices: listed.length,
			connectedDevices: connected
		};
	}

	/** `exohost list --all` as text: one line per kind (zero counts included), then the daemon and remote lines. */
	public static function kindsText(counts:Dynamic):String {
		var output = new StringBuf();
		output.add("Everything exohost tracks (exosuit's = registered + found by scanning; others are listed, never stopped in bulk):
");
		for (kind in ALL_KINDS) {
			var entry:Dynamic = Reflect.field(counts.kinds, (kind : String));
			output.add("  " + column((kind : String), 19) + column(Std.string(entry.exosuit), 4) + "(" + entry.registered + " registered, " + entry.found
				+ " found)" + (entry.notStartedByExosuit > 0 ? ", " + entry.notStartedByExosuit + " not started by exosuit" : "") + "
");
		}
		output.add("  " + column("exohost daemon", 19) + (counts.daemon == null ? "not running" : "running (pid " + counts.daemon.pid + ")") + "
");
		var remote:Dynamic = counts.remote;
		output.add("  " + column("remote access", 19) + (remote == null ? "unknown (exohost is not running; nothing is connected through it)"
			: remote.enabled == true ? "on, relay " + (remote.relayConnected == true ? "connected" : "not connected") + ", " + remote.sessions + " live session(s)" : "off")
			+ "
");
		output.add("  " + column("paired devices", 19) + counts.pairedDevices + " (" + counts.connectedDevices + " connected now)
");
		return output.toString();
	}

	/** `exohost remote`: the machine's relay connection, then each paired device with its workspaces and sessions. */
	public static function remoteText(status:Dynamic, listing:Dynamic):String {
		var output = new StringBuf();
		if (status != null && Reflect.field(status, "enabled") == true)
			output.add("Remote access: on, relay " + Reflect.field(status, "origin") + (Reflect.field(status, "connected") == true ? " (connected)" : " (not connected)")
				+ ", " + Reflect.field(status, "sessions") + " live session(s)\n");
		else
			output.add("Remote access: off" + (status != null && Reflect.field(status, "error") != null ? " (" + Reflect.field(status, "error") + ")" : "") + "\n");
		var devices:Array<Dynamic> = Std.isOfType(Reflect.field(listing, "devices"), Array) ? Reflect.field(listing, "devices") : [];
		var names = new Map<String, String>();
		var workspaces:Dynamic = Reflect.field(listing, "workspaces");
		if (Std.isOfType(workspaces, Array))
			for (entry in (workspaces : Array<Dynamic>))
				names.set(Std.string(entry.id), Std.string(entry.name));
		for (device in devices)
			output.add(deviceLine(device, names) + "\n");
		if (devices.length == 0)
			output.add("No device is paired.\n");
		var pending:Dynamic = Reflect.field(listing, "pending");
		if (Std.isOfType(pending, Array) && (pending : Array<Dynamic>).length > 0)
			output.add((pending : Array<Dynamic>).length + " pairing request(s) waiting for approval\n");
		return output.toString();
	}

	/** One paired device: name or id, state, when paired, and the workspaces it may use. */
	public static function deviceLine(device:Dynamic, workspaceNames:Map<String, String>):String {
		var id = Std.string(device.deviceId);
		var name:Null<String> = device.name;
		var state = device.revoked == true ? "revoked" : device.connected == true ? "connected now" : "not connected";
		var paired:Null<Float> = device.pairedAt;
		var when = paired == null ? "paired (date not recorded)" : "paired " + uptime(paired) + " ago";
		var granted:Array<String> = [];
		if (Std.isOfType(device.workspaces, Array))
			for (entry in (device.workspaces : Array<Dynamic>)) {
				var key = Std.string(entry.workspace);
				granted.push(workspaceNames.exists(key) ? workspaceNames.get(key) : key);
			}
		return "  " + (name != null ? '$name ($id)' : id) + ": " + state + ", " + when + ", workspaces: " + (granted.length == 0 ? "none" : granted.join(", "));
	}

	/** The id of the one paired device a query names: its id, a prefix of 4+ characters, or its name. Null when none or several. */
	public static function findDevice(listing:Dynamic, query:String):Null<String> {
		var devices:Array<Dynamic> = Std.isOfType(Reflect.field(listing, "devices"), Array) ? Reflect.field(listing, "devices") : [];
		var found:Array<String> = [];
		for (device in devices) {
			var id = Std.string(device.deviceId);
			if (id == query || (query.length >= 4 && StringTools.startsWith(id, query)) || (device.name != null && Std.string(device.name) == query))
				found.push(id);
		}
		return found.length == 1 ? found[0] : null;
	}

	public static function results(results:Array<TerminationResult>):String {
		if (results.length == 0)
			return "Nothing to terminate.\n";
		return [for (result in results) '${result.pid} ${(result.kind : String)}: ${result.outcome}'].join("\n") + "\n";
	}

	/** What `kill --dry-run` prints: the processes a kill would stop, one per line. */
	public static function plan(processes:Array<ExohostProcess>):String {
		if (processes.length == 0)
			return "Nothing to terminate.\n";
		return [for (process in processes) '${process.pid} ${(process.kind : String)}: would stop'].join("\n") + "\n";
	}
}
