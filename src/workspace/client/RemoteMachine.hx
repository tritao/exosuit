package workspace.client;

import haxeon.platform.event.EventPump;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.transport.DeviceRpcConnector;
import haxeon.rpc.MessageTransport;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.StreamMultiplexer;

/**
	One paired machine on a device (the phone, the browser): the relay route (DeviceRpcConnector, pinned Noise identity), the machine client on
	stream 0, and the device's links to its workspaces (WorkspaceLinks over `DeviceMachine.openService`, the same links the
	desktop editor holds over suit's pipe). The open workspace's link is kept, and starts its service when idle; each
	running granted workspace whose row is expanded has a link for its rows, which never starts a service, so a stopped
	or idle service stays stopped. Each link is a stream of the machine's channel, so a device with many granted
	workspaces still holds one relay connection (and at most STREAMS - 2 row links).
**/
class RemoteMachine {
	public final device:DevicePairing.PairedMachine;
	public final machine:DeviceMachine;
	public final links:WorkspaceLinks;
	final connector:DeviceRpcConnector;

	/** `first` is the channel pairing just used, or null when reconnecting a saved pairing. Throws when the saved keys are damaged. */
	public function new(events:EventPump, hub:NativeRpcHub, clock:Void->Float, device:DevicePairing.PairedMachine, first:Null<MessageTransport>) {
		this.device = device;
		var key = DevicePairing.bytesFromHex(device.staticPrivateKey);
		var pinned = DevicePairing.bytesFromHex(device.machineStaticPublicKey);
		connector = new DeviceRpcConnector(events, hub, clock, new RelayMachineEndpoint(device.relayOrigin, device.machineId), device.machineId,
			device.deviceId, device.deviceToken, key, pinned, first);
		machine = new DeviceMachine(connector, device.machineId, clock, function() return Math.random(), connector.poll);
		// Only a link the device needs itself (the open workspace, a terminal it starts) may start a service.
		links = new WorkspaceLinks(events, clock, function(id, done) machine.openService(id, links.kept(id), done));
	}

	/**
		Moves the machine client and the links along. `open` is the workspace the phone has open on this machine, if any:
		its link is kept (and asks again when its stream ends). Of the workspaces in `expanded` (the tree's expanded rows),
		those running get links for their rows, as the desktop's do (SuitWorkbenchMachine.poll).
	**/
	public function poll(open:Null<String>, expanded:Array<String>):Null<WorkspaceLink> {
		machine.poll();
		var opened:Null<WorkspaceLink> = null;
		if (open != null && machine.workspaceById(open) != null)
			opened = links.use(WorkspaceServiceTarget.remote(open), true);
		var rows = 0;
		if (machine.connected())
			for (id in expanded) {
				if (id == open || rows >= StreamMultiplexer.STREAMS - 2) continue;
				var entry = machine.workspaceById(id);
				if (entry == null) continue;
				rows++;
				if (links.touch(id)) continue;
				if (entry.status != MachineDirectoryProtocol.RUNNING || entry.grants.indexOf(WorkspaceCatalogProtocol.CAPABILITY) < 0) continue;
				links.use(WorkspaceServiceTarget.remote(id), false);
			}
		links.poll();
		return opened;
	}

	/** The network came back or changed: dial the machine now, and each link waiting out a backoff. The links ride its channel and reconnect through OPEN. */
	public function retryNow(redial:Bool):Void {
		machine.retryNow(redial);
		for (id in links.ids()) {
			var link = links.get(id);
			if (link != null) link.retryNow(redial);
		}
	}

	public function online():Bool return machine.connected();

	/** Why this pairing is dead for good (revoked, identity changed), as a sentence; null while it works or is only offline. */
	public function refusal():Null<String> {
		return switch machine.refusal {
			case null: null;
			case "unauthorized", "relay_unauthorized", "authentication_refused", "authorization_failed": "No longer authorized. Forget this machine and pair again.";
			case "machine_identity_conflict", "noise_identity_mismatch": "The machine's identity changed. Verify it on the desktop, then forget and pair again.";
			case code: "The connection ended (" + code + ").";
		}
	}

	public function name():String
		return machine.directory != null ? machine.directory.name : device.name != null ? device.name : "Machine " + device.machineId.substr(0, 6);

	/** The catalog of a workspace of this machine, as its link last read it; null while it has none. */
	public function mirrorOf(workspace:String):Null<WorkspaceCatalogMirror> {
		var link = links.get(workspace);
		return link == null ? null : link.catalogMirror();
	}

	/** Changes whenever a link comes or goes, or one's catalog or connection does. */
	public function linksRevision():Int {
		var total = links.revision * 7919;
		for (id in links.ids()) {
			var link = links.get(id);
			if (link != null) total += link.catalogRevision() * 31 + (link.catalogLive() ? 1 : 0) + (link.ready ? 2 : 0);
		}
		return total;
	}

	public function dispose():Void {
		links.dispose();
		machine.dispose();
		connector.dispose();
	}
}
