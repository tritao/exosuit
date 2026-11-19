package exohost;

import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcClientState;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcPeerOptions;
import exohost.MachineCatalog.MachineState;
import exohost.remote.MachineRemote.DeferredReply;
import workspace.client.WorkspaceCatalogMirror;
import workspace.client.WorkspaceCatalogWatch;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.sessions.SessionIndex;
import workspace.sessions.SessionIndex.SessionEntry;
import workspace.transport.NativeRpcConnector;
import workspace.transport.NativeRpcHub;

/** One workspace's read in flight: a short-lived client of its service that reads the catalog once. */
private typedef Probe = {
	var workspace:String;
	var name:String;
	var client:RpcClient;
	var watch:Null<WorkspaceCatalogWatch>;
	/** Set when the read finished: the catalog's rows, or null when it failed. */
	var done:Bool;
	var mirror:Null<WorkspaceCatalogMirror>;
}

private typedef Ask = {
	var reply:DeferredReply;
	var machine:MachineState;
	var probes:Array<Probe>;
	var deadline:Float;
	var wanted:Null<Array<String>>;
}

/**
	The control op `sessions` (docs/phone-ui/CONTRACTS.md, D): every running workspace service's sessions and terminals as
	SessionEntry JSON. exohost reads each service's catalog (WorkspaceCatalogWatch over a short connection, the way a
	window does) and answers with the merge. A service that has not answered within TIMEOUT_SECONDS is listed in
	`unavailable`; idle workspaces (no running service) hold no live sessions and are left out.

	The catalog holds no timestamps, so `lastActive` is the time exohost last saw the row change state or attention (the
	first sighting counts), and `last` is empty.
**/
class ExohostSessions {
	public static inline final TIMEOUT_SECONDS = 2.0;

	final hub:NativeRpcHub;
	final services:ExohostServices;
	final asks:Array<Ask> = [];
	final source:workspace.client.SessionIndexSource = new workspace.client.SessionIndexSource();

	public function new(hub:NativeRpcHub, services:ExohostServices) {
		this.hub = hub;
		this.services = services;
	}

	/** Whether a read is under way: the daemon's loop turns quickly meanwhile. */
	public function busy():Bool
		return asks.length > 0;

	/**
		Starts reading the running services' catalogs; the reply is a DeferredReply resolved by `poll`. `wanted` limits the
		workspaces (null for all); `machine` is the machine's catalog.
	**/
	public function ask(machine:MachineState, wanted:Null<Array<String>>):DeferredReply {
		var reply = new DeferredReply();
		var probes:Array<Probe> = [];
		for (workspace in machine.workspaces) {
			if (wanted != null && wanted.indexOf(workspace.id) < 0)
				continue;
			var service = services.serviceOf(workspace.id);
			if (service == null || !service.running)
				continue;
			var probe = start(workspace.id, workspace.name, service.endpoint);
			if (probe != null)
				probes.push(probe);
		}
		asks.push({reply: reply, machine: machine, probes: probes, deadline: Sys.time() + TIMEOUT_SECONDS, wanted: wanted});
		return reply;
	}

	function start(workspace:String, name:String, endpoint:String):Null<Probe> {
		var probe:Probe = {workspace: workspace, name: name, client: null, watch: null, done: false, mirror: null};
		var caps = [
			WorkspaceProtocol.READ,
			WorkspaceProtocol.IDENTITY_CAPABILITY,
			WorkspaceCatalogProtocol.CAPABILITY,
			WorkspaceAgentProtocol.READ,
			WorkspaceTerminalProtocol.READ
		];
		try {
			probe.client = new RpcClient(new NativeRpcConnector(hub, NativeRpcHub.local(endpoint)), Sys.time, Math.random,
				new RpcPeerOptions("exosuit-editor/1", caps, [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY], 2000, 262144, 32,
					1048576),
				function(connection:RpcConnection, _:Int, _:Array<String>) {
					var watch = WorkspaceCatalogWatch.shared({machine: "local", workspace: "workspace"}, function() return Sys.time() * 1000, true);
					probe.watch = watch;
					watch.attach(connection);
				}, 100, 500, 1500);
		} catch (_:Dynamic) {
			return null;
		}
		return probe;
	}

	/** Moves the reads along and answers the asks that are complete or out of time; call every loop turn. */
	public function poll():Void {
		var index = asks.length;
		while (index-- > 0) {
			var ask = asks[index];
			var pending = 0;
			for (probe in ask.probes) {
				if (probe.done)
					continue;
				try {
					probe.client.poll();
					var watch = probe.watch;
					if (watch != null) {
						watch.poll();
						// `live` is a complete copy; an error without one means this read failed.
						if (watch.live && !watch.mirror.partial) {
							probe.mirror = watch.mirror;
							probe.done = true;
						} else if (watch.error != null && !watch.live) {
							probe.done = true;
						}
					}
					if (!probe.done && probe.client.state == RpcClientState.Closed)
						probe.done = true;
				} catch (_:Dynamic) {
					probe.done = true;
				}
				if (!probe.done)
					pending++;
			}
			if (pending > 0 && Sys.time() < ask.deadline)
				continue;
			asks.splice(index, 1);
			finish(ask);
		}
	}

	function finish(ask:Ask):Void {
		var entries:Array<SessionEntry> = [];
		var unavailable:Array<String> = [];
		for (probe in ask.probes) {
			var mirror = probe.mirror;
			if (mirror == null)
				unavailable.push(probe.workspace);
			else
				entries = entries.concat(source.entriesOf(ask.machine.id, probe.workspace, probe.name, mirror));
			probe.client.close();
			if (probe.watch != null)
				probe.watch.dispose();
		}
		ask.reply.resolve({
			ok: true,
			machine: {id: ask.machine.id, name: ask.machine.name},
			sessions: SessionIndex.toJson(entries),
			unavailable: unavailable
		});
	}
}
