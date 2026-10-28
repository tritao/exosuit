package suit.relay;

import suit.SuitInventory;
import suit.SuitLogin;
import suit.SuitInventory.SuitProcess;
import suit.SuitMenuModel.SuitMenuSink;
import suit.SuitReport;
import suit.relay.SuitRelayBridge.SuitRelayHostView;

/** What the tray's Remote access and Start at login items do; the suit daemon supplies them. */
typedef SuitHostingActions = {
	var hosts:Void->Array<SuitRelayHostView>;
	/** Pause hosting for a workspace root (all when null) and stop its workspace service. */
	var stopHosting:Null<String>->Void;
	var resumeHosting:Null<String>->Void;
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
			var root = host.root;
			menu.item(SuitInventory.workspaceName(host.root) + ": " + describe(host), null, remote);
			for (line in deviceLines(host))
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
		try enabled = actions.loginEnabled() catch (_:Dynamic) {}
		menu.check("Start at login", enabled, actions.toggleLogin, 0);
	}

	/** State, whether the workspace service runs, connected devices. */
	public static function describe(host:SuitRelayHostView):String {
		var parts = [host.state == "error" && host.error != null ? "error: " + host.error : host.state];
		if (host.state != "paused" && host.state != "not hosted") {
			parts.push(host.serviceRunning ? "service running" : "service starts on demand");
			var connected = connectedDevices(host).length;
			if (connected > 0)
				parts.push(connected + (connected == 1 ? " device connected" : " devices connected"));
		}
		return parts.join(" · ");
	}

	public static function text(inventory:SuitInventory, hosts:Array<SuitRelayHostView>):String {
		var direct = directProcesses(inventory, hosts);
		if (hosts.length + direct.length == 0)
			return "No workspace is hosting remote access.\n";
		var output = new StringBuf();
		for (host in hosts) {
			output.add(column(SuitInventory.workspaceName(host.root), 22) + column(host.state, 16) + host.origin + "  (via suit)\n");
			output.add("    root: " + host.root + "\n");
			if (host.state == "error" && host.error != null)
				output.add("    error: " + host.error + "\n");
			if (host.state != "paused" && host.state != "not hosted")
				output.add("    " + (host.serviceRunning ? "workspace service running (pid " + host.servicePid + ")" : "workspace service starts when a device connects")
					+ (host.starts > 0 ? "; started for a device " + host.starts + " time(s)" : "") + "\n");
			for (line in deviceLines(host))
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
				devices: devicesOf(host)
			}],
			processes: [for (process in directProcesses(inventory, hosts)) SuitReport.processJson(process)]
		};
	}

	/** Device lines from the daemon's `relay-status.json`; with no daemon running no device is connected. */
	static function deviceLines(host:SuitRelayHostView):Array<String> {
		var lines:Array<String> = [];
		if (!host.serviceRunning)
			return lines;
		var status = SuitInventory.readRelay(host.stateDir);
		if (status == null)
			return lines;
		for (device in status.devices)
			if (device.connected && !device.revoked)
				lines.push("device " + device.deviceId.substr(0, 12) + " connected");
		if (status.pending > 0)
			lines.push(status.pending + " pairing request(s) waiting for approval");
		return lines;
	}

	static function devicesOf(host:SuitRelayHostView):Array<Dynamic> {
		var status = host.serviceRunning ? SuitInventory.readRelay(host.stateDir) : null;
		return status == null ? [] : [for (device in status.devices) {deviceId: device.deviceId, connected: device.connected, revoked: device.revoked}];
	}

	static function connectedDevices(host:SuitRelayHostView):Array<String> {
		var status = host.serviceRunning ? SuitInventory.readRelay(host.stateDir) : null;
		return status == null ? [] : [for (device in status.devices) if (device.connected && !device.revoked) device.deviceId];
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
