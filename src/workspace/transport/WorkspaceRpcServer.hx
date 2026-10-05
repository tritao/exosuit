package workspace.transport;

import haxeon.rpc.*;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminals;
import workspace.service.WorkspaceTerminalProtocol;

private typedef Peer = {var transport:NativeRpcTransport; var preflight:Null<SessionPreflight>; var handshake:Null<RpcHandshake>; var connection:Null<RpcConnection>;}

/** Bounded headless service loop, shared by daemon and transport tests. */
class WorkspaceRpcServer {
	final service:WorkspaceService;
	final clock:Void->Float;
	final identity:Null<WorkspaceIdentity>;
	final terminals:Null<WorkspaceTerminals>;
	final peers:Array<Peer> = [];

	public final options:RpcPeerOptions;

	/** Only authenticated, fully negotiated connections keep the daemon alive. */
	public function clientCount():Int {
		var count = 0;
		for (peer in peers)
			if (peer.connection != null && peer.connection.isOpen())
				count++;
		return count;
	}

	public function new(service:WorkspaceService, clock:Void->Float, ?capabilities:Array<String>, ?identity:WorkspaceIdentity, ?terminals:WorkspaceTerminals) {
		this.service = service;
		this.terminals = terminals;
		this.clock = clock;
		this.identity = identity == null ? null : {workspace: identity.workspace, root: identity.root, instance: identity.instance};
		if (identity != null && (identity.workspace != service.id || identity.root.length == 0 || identity.instance.length == 0))
			throw "Invalid daemon identity";
		var defaults = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE];
		if (identity != null)
			defaults.push(WorkspaceProtocol.IDENTITY_CAPABILITY);
		if (terminals != null) {
			defaults.push(WorkspaceTerminalProtocol.READ);
            defaults.push(WorkspaceTerminalProtocol.CATALOG);
			defaults.push(WorkspaceTerminalProtocol.CONTROL);
		}
		options = new RpcPeerOptions("exosuit-agent/1", capabilities == null ? defaults : capabilities, [], 5000, 262144, 32, 1048576);
	}

	/** NativeKit validates same-user peers and private paths on local sockets. */
	public function acceptLocal(transport:NativeRpcTransport):Void {
		accept(transport, null);
	}

	public function acceptWebSocket(transport:NativeRpcTransport, token:String):Void {
		accept(transport, new SessionPreflight(transport, token, clock, true));
	}

	function accept(transport:NativeRpcTransport, preflight:Null<SessionPreflight>):Void {
		prune();
		if (peers.length >= 16) {
			transport.close();
			return;
		}
		peers.push({
			transport: transport,
			preflight: preflight,
			handshake: preflight == null ? RpcHandshake.server(transport, clock, options) : null,
			connection: null
		});
	}

	function prune():Void {
		var index = peers.length;
		while (index > 0) {
			index--;
			if (!peers[index].transport.isOpen()) {
				if (peers[index].connection != null)
					peers[index].connection.close();
				peers.splice(index, 1);
			}
		}
	}

	public function poll():Void {
		for (peer in peers.copy()) {
			var auth = peer.preflight;
			if (auth != null) {
				auth.poll();
				if (!auth.finished)
					continue;
				if (!auth.authenticated) {
					peer.transport.close();
					continue;
				}
				peer.preflight = null;
				peer.handshake = RpcHandshake.server(peer.transport, clock, options);
			}
			var handshake = peer.handshake;
			if (handshake != null) {
				handshake.poll();
				if (!handshake.isFinished())
					continue;
				peer.handshake = null;
				peer.connection = handshake.connection;
				if (peer.connection != null) {
					var grants = handshake.capabilities();
					var currentIdentity = identity;
					if (currentIdentity != null)
						peer.connection.register(WorkspaceProtocol.IDENTITY, function(request, context) {
							if (grants.indexOf(WorkspaceProtocol.READ) < 0 || grants.indexOf(WorkspaceProtocol.IDENTITY_CAPABILITY) < 0) {
								context.fail({code: "unauthorized", message: "Identity query denied", ambiguous: false});
								return;
							}
							if (request.workspace != service.id) {
								context.fail({code: "invalid_request", message: "Invalid workspace identity query", ambiguous: false});
								return;
							}
							context.respond({workspace: currentIdentity.workspace, root: currentIdentity.root, instance: currentIdentity.instance});
						});
					service.bind(peer.connection, grants);
					if (terminals != null) terminals.bind(peer.connection, grants);
				}
			}
			if (peer.connection != null)
				peer.connection.poll(32, 262144);
		}
		prune();
	}

	public function closeClients():Void {
		for (peer in peers) {
			if (peer.connection != null)
				peer.connection.close();
			else
				peer.transport.close();
		}
		peers.resize(0);
	}

	public function dispose():Void
		closeClients();
}
