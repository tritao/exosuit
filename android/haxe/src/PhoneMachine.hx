import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import workspace.client.DeviceMachine;
import workspace.client.WorkspaceCatalogMirror;
import workspace.client.WorkspaceConnections;
import workspace.client.WorkspaceConnections.WatchedService;
import workspace.service.MachineDirectoryProtocol;
import workspace.transport.DeviceRpcConnector;
import haxeon.rpc.MessageTransport;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.StreamMultiplexer;

/**
	One paired machine on the phone: the relay route (DeviceRpcConnector, pinned Noise identity), the machine client on
	stream 0 and a pool of catalog watches, one per running granted workspace except the open one (which has its own
	connection). The pool follows the directory; its watches are streams of the machine's channel, so a phone with many
	granted workspaces still holds one relay connection (and at most STREAMS - 2 catalog streams).
**/
class PhoneMachine {
	public final device:SavedDevice;
	public final machine:DeviceMachine;
	public final pool:WorkspaceConnections;
	final connector:DeviceRpcConnector;
	var syncKey = "";

	/** `first` is the channel pairing just used, or null when reconnecting a saved pairing. Throws when the saved keys are damaged. */
	public function new(events:EventPump, hub:NativeRpcHub, clock:Void->Float, device:SavedDevice, first:Null<MessageTransport>) {
		this.device = device;
		var key = PhoneRemote.bytesFromHex(device.staticPrivateKey);
		var pinned = PhoneRemote.bytesFromHex(device.machineStaticPublicKey);
		connector = new DeviceRpcConnector(events, hub, clock, new RelayMachineEndpoint(device.relayOrigin, device.machineId), device.machineId,
			device.deviceId, device.deviceToken, key, pinned, first);
		machine = new DeviceMachine(connector, device.machineId, clock, function() return Math.random(), connector.poll);
		pool = new WorkspaceConnections(function(workspace) return machine.workspaceConnector(workspace), clock, null, function(workspace) return workspace.length > 0,
			StreamMultiplexer.STREAMS - 2);
	}

	/** Moves the machine client and the pool along. `open` is the workspace the phone has open on this machine, if any. */
	public function poll(open:Null<String>):Void {
		machine.poll();
		var machineId = machine.machineId;
		var directory = machine.directory;
		if (machineId != null && directory != null) {
			var key = machine.revision + ":" + open;
			if (key != syncKey) {
				syncKey = key;
				var services:Array<WatchedService> = [];
				for (entry in directory.workspaces)
					if (entry.status == MachineDirectoryProtocol.RUNNING && entry.grants.indexOf(workspace.service.WorkspaceCatalogProtocol.CAPABILITY) >= 0)
						services.push({workspace: entry.workspace, endpoint: entry.workspace, pid: 0, running: true});
				pool.sync(machineId, services, open, [for (entry in directory.workspaces) entry.workspace]);
			}
		}
		pool.poll();
	}

	/** The network came back or changed: dial the machine now. The workspace streams ride its channel and reconnect through OPEN. */
	public function retryNow(redial:Bool):Void machine.retryNow(redial);

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

	/** The catalog copy of a workspace of this machine other than the open one, or null while it has none. */
	public function mirrorOf(workspace:String):Null<WorkspaceCatalogMirror> return pool.mirrorOf(workspace);

	public function dispose():Void {
		pool.dispose();
		machine.dispose();
		connector.dispose();
	}
}
