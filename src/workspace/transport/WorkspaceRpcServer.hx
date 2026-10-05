package workspace.transport;

import haxeon.rpc.*;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceProtocol;

private typedef Peer = {var transport:NativeRpcTransport; var preflight:Null<SessionPreflight>; var handshake:Null<RpcHandshake>; var connection:Null<RpcConnection>;}

/** Bounded headless service loop, shared by daemon and transport tests. */
class WorkspaceRpcServer {
	final service:WorkspaceService;
	final clock:Void->Float;
	final peers:Array<Peer> = [];

	public final options:RpcPeerOptions;

	public function new(service:WorkspaceService, clock:Void->Float, ?capabilities:Array<String>) {
		this.service = service;
		this.clock = clock;
		options = new RpcPeerOptions("exosuit-agent/1",
			capabilities == null ? [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE] : capabilities, [], 5000, 262144, 32, 1048576);
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
				if (peer.connection != null)
					service.bind(peer.connection, handshake.capabilities());
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
