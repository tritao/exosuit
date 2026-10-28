package suit.relay;

import suit.SuitInventory;
import suit.SuitLogin;
import suit.SuitInventory.SuitProcess;
import suit.SuitMenuModel.SuitMenuSink;
import suit.SuitReport;
import suit.relay.SuitRelayBridge.SuitRelayHostView;
import suit.relay.SuitRelayClients.SuitRelayClientView;
import suit.relay.SuitRelayProtocol.SuitRelayOpen;

/** What the tray's Remote access and Start at login items do; the suit daemon supplies them. */
typedef SuitHostingActions = {
	var hosts:Void->Array<SuitRelayHostView>;
	/** Pause hosting for a workspace root (all when null) and stop its workspace service. */
	var stopHosting:Null<String>->Void;
	var resumeHosting:Null<String>->Void;
	/** Ends one remote client's session, by client id. */
	var disconnect:String->Void;
	/** For a failed workspace, by machine id: try again now, or stop hosting it and forget its record. */
	var retry:String->Void;
	var dismiss:String->Void;
	var loginEnabled:Void->Bool;
	var toggleLogin:Void->Void;
}

/**
	The Remote access submenu and `suit relay list`: workspaces suit hosts (with their state, whether the
	workspace service is running, and its connected devices), then workspaces whose daemon still holds the
	relay socket itself.
**/
class SuitRelayMenu {
	public static function build(menu:SuitMenuSink, inventory:SuitInventory, actions:SuitHostingActions,
			openViewer:Array<String>->Void):Void {
		var hosts = actions.hosts();
		var direct = directProcesses(inventory, hosts);
		if (hosts.length + direct.length == 0)
			return;
		menu.separator(0);
		var remote = menu.submenu("Remote access (" + (hosts.length + direct.length) + ")", 0);
		var active = 0;
		for (host in hosts) {
			var root = host.root, machineId = host.machineId;
			menu.item(SuitInventory.workspaceName(host.root) + ": " + describe(host), null, remote);
			if (host.state == "failed") {
				menu.item("    Retry " + SuitInventory.workspaceName(host.root), function() actions.retry(machineId), remote);
				menu.item("    Dismiss (stop hosting it from suit)", function() actions.dismiss(machineId), remote);
				continue;
			}
			if (host.open != null && host.serviceRunning)
				menu.item("    open: " + openText(host.open), null, remote);
			for (client in host.clients) {
				var id = client.id;
				var entry = menu.submenu("    " + clientLabel(client), remote);
				menu.item("Connected " + ago(client.connectedAt) + ", last activity " + ago(client.lastActivity), null, entry);
				menu.item("Workspace: " + SuitInventory.workspaceName(host.root), null, entry);
				if (client.grants.length > 0)
					menu.item("Allowed: " + client.grants.join(", "), null, entry);
				menu.item(client.framesIn + " frames in, " + client.framesOut + " out", null, entry);
				if (client.kind != "disconnected" && client.route == "suit")
					menu.item("Disconnect", function() actions.disconnect(id), entry);
			}
			for (line in pendingLines(host))
				menu.item("    " + line, null, remote);
			if (host.state == "paused")
				menu.item("    Resume hosting " + SuitInventory.workspaceName(host.root), function() actions.resumeHosting(root), remote);
			else {
				active++;
				menu.item("    Stop hosting " + SuitInventory.workspaceName(host.root), function() actions.stopHosting(root), remote);
			}
		}
		for (process in direct) {
			var target = process;
			active++;
			menu.item(SuitReport.workspace(process) + ": " + SuitReport.relayState(process) + " (hosted by its workspace service)", null, remote);
			menu.item("    Stop hosting " + SuitReport.workspace(process), function() actions.stopHosting(target.root), remote);
		}
		menu.separator(remote);
		menu.item("Stop all hosting", active == 0 ? null : function() actions.stopHosting(null), remote);
		menu.item("Open Remote Access…", function() openViewer(["watch", "--relay"]), remote);
	}

	/** The Start at login item: a checkbox, off by default. */
	public static function login(menu:SuitMenuSink, actions:SuitHostingActions):Void {
		if (!SuitLogin.supported())
			return;
		var enabled = false;
		// The daemon passes its cached state, so opening the menu never waits for reg.exe.
		try enabled = actions.loginEnabled() catch (_:Dynamic) {}
		menu.check("Start at login", enabled, actions.toggleLogin, 0);
	}

	/** State, whether the workspace service runs, connected clients. */
	public static function describe(host:SuitRelayHostView):String {
		var parts = [(host.state == "error" || host.state == "failed") && host.error != null ? host.state + ": " + host.error : host.state];
		if (host.state != "paused" && host.state != "not hosted" && host.state != "failed") {
			parts.push(host.serviceRunning ? "service running" : "service starts on demand");
			var connected = host.clients.length;
			parts.push(connected == 1 ? "1 client" : connected + " clients");
		}
		return parts.join(" · ");
	}

	/** "device 3fa2c1d07b19 · active 4s ago". */
	public static function clientLabel(client:SuitRelayClientView):String {
		var kind = switch client.kind {
			case "device": "device";
			case "pairing": "pairing request";
			case "disconnected": "disconnected";
			default: "client";
		};
		var label = kind + " " + client.id.substr(0, 12);
		return client.route == "direct" ? label + " (direct)" : label + " · active " + ago(client.lastActivity);
	}

	static function openText(open:SuitRelayOpen):String
		return open.terminals + " terminal(s), " + open.agents + " agent session(s)";

	public static function ago(time:Float):String {
		if (time <= 0)
			return "?";
		return SuitReport.uptime(time * 1000) + " ago";
	}

	public static function text(inventory:SuitInventory, hosts:Array<SuitRelayHostView>):String {
		var direct = directProcesses(inventory, hosts);
		if (hosts.length + direct.length == 0)
			return "No workspace is hosting remote access.\n";
		var output = new StringBuf();
		for (host in hosts) {
			output.add(column(SuitInventory.workspaceName(host.root), 22) + column(host.state, 16) + host.origin + "  (via suit)\n");
			output.add("    root: " + host.root + "\n");
			if ((host.state == "error" || host.state == "failed") && host.error != null)
				output.add("    error: " + host.error + "\n");
			if (host.state != "paused" && host.state != "not hosted")
				output.add("    " + (host.serviceRunning ? "workspace service running (pid " + host.servicePid + ")" : "workspace service starts when a device connects")
					+ (host.starts > 0 ? "; started for a device " + host.starts + " time(s)" : "") + "\n");
			if (host.open != null && host.serviceRunning)
				output.add("    open: " + openText(host.open) + "\n");
			output.add("    " + (host.clients.length == 1 ? "1 client connected" : host.clients.length + " clients connected") + "\n");
			for (client in host.clients)
				output.add("      " + client.id + "  " + column(client.kind, 9) + " connected " + ago(client.connectedAt)
					+ ", last activity " + ago(client.lastActivity) + ", " + client.framesIn + " frames in, " + client.framesOut + " out"
					+ (client.grants.length > 0 ? "; allowed: " + client.grants.join(", ") : "") + "\n");
			for (line in pendingLines(host))
				output.add("    " + line + "\n");
		}
		for (process in direct) {
			var relay = process.relay;
			if (relay == null)
				continue;
			output.add(column(SuitReport.workspace(process), 22) + column(SuitReport.relayState(process), 16)
				+ (relay.origin == null ? "" : relay.origin) + "  (pid " + process.pid + ")\n");
			output.add("    root: " + process.root + "\n");
			for (device in relay.devices)
				output.add("    device " + device.deviceId + (device.revoked ? " revoked" : device.connected ? " connected" : " paired") + "\n");
			if (relay.pending > 0)
				output.add("    " + relay.pending + " pairing request(s) waiting for approval\n");
		}
		return output.toString();
	}

	public static function json(inventory:SuitInventory, hosts:Array<SuitRelayHostView>):Dynamic {
		return {
			version: 1,
			hosts: [for (host in hosts) {
				root: host.root, stateDir: host.stateDir, machineId: host.machineId, origin: host.origin, state: host.state,
				error: host.error, serviceRunning: host.serviceRunning, servicePid: host.servicePid, starts: host.starts,
				clients: host.clients, open: host.open, devices: devicesOf(host)
			}],
			processes: [for (process in directProcesses(inventory, hosts)) SuitReport.processJson(inventory, process)]
		};
	}

	/** Pairing requests waiting for approval, from the daemon's `relay-status.json`. */
	static function pendingLines(host:SuitRelayHostView):Array<String> {
		var lines:Array<String> = [];
		if (!host.serviceRunning)
			return lines;
		var status = SuitInventory.readRelay(host.stateDir);
		if (status == null)
			return lines;
		if (status.pending > 0)
			lines.push(status.pending + " pairing request(s) waiting for approval");
		return lines;
	}

	static function devicesOf(host:SuitRelayHostView):Array<Dynamic> {
		var status = host.serviceRunning ? SuitInventory.readRelay(host.stateDir) : null;
		return status == null ? [] : [for (device in status.devices) {deviceId: device.deviceId, connected: device.connected, revoked: device.revoked}];
	}

	/** Hosting workspaces suit does not host: their daemon holds the relay socket itself. */
	static function directProcesses(inventory:SuitInventory, hosts:Array<SuitRelayHostView>):Array<SuitProcess> {
		var covered = new Map<String, Bool>();
		for (host in hosts)
			covered.set(SuitInventory.rootKey(host.root), true);
		return [for (process in inventory.hosted()) if (process.root == null || !covered.exists(SuitInventory.rootKey(process.root))) process];
	}

	static function column(text:String, width:Int):String {
		var result = text.length > width ? text.substr(0, width - 1) + "…" : text;
		while (result.length < width)
			result += " ";
		return result;
	}
}
