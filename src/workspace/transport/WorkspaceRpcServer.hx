package workspace.transport;

import haxeon.rpc.*;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminals;
import workspace.service.WorkspaceTerminalProtocol;

private typedef Peer = {var transport:MessageTransport; var options:RpcPeerOptions; var localAdmin:Bool; var preflight:Null<SessionPreflight>; var handshake:Null<RpcHandshake>; var connection:Null<RpcConnection>; var cleanup:Array<Void->Void>;}

/** Bounded headless service loop, shared by daemon and transport tests. */
class WorkspaceRpcServer {
	final service:WorkspaceService;
	final clock:Void->Float;
	final identity:Null<WorkspaceIdentity>;
	final terminals:Null<WorkspaceTerminals>;
	final agents:Null<workspace.service.WorkspaceAgents>;
	final pairingAdmin:Null<workspace.service.WorkspacePairingAdmin>;
	final files:Null<workspace.runtime.WorkspaceFileService>;
	final peers:Array<Peer> = [];

	public final options:RpcPeerOptions;
	final localOptions:RpcPeerOptions;

	/** Only authenticated, fully negotiated connections keep the daemon alive. */
	public function clientCount():Int {
		var count = 0;
		for (peer in peers)
			if (peer.connection != null && peer.connection.isOpen())
				count++;
		return count;
	}

	public function new(service:WorkspaceService, clock:Void->Float, ?capabilities:Array<String>, ?identity:WorkspaceIdentity, ?terminals:WorkspaceTerminals, ?agents:workspace.service.WorkspaceAgents, ?pairingAdmin:workspace.service.WorkspacePairingAdmin, ?files:workspace.runtime.WorkspaceFileService) {
		this.service = service;
		this.terminals = terminals;
		this.agents = agents;
		this.pairingAdmin = pairingAdmin;
		this.files = files;
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
		if (agents != null) {
			defaults.push(workspace.service.WorkspaceAgentProtocol.READ);
			defaults.push(workspace.service.WorkspaceAgentProtocol.CONTROL);
		}
		if (files != null)
			defaults.push(workspace.service.WorkspaceFileProtocol.READ);
		options = new RpcPeerOptions("exosuit-agent/1", capabilities == null ? defaults : capabilities, [], 5000, 262144, 32, 1048576);
		var localDefaults = options.offered();
		if (pairingAdmin != null)
			localDefaults.push(workspace.service.WorkspacePairingProtocol.ADMIN);
		localOptions = new RpcPeerOptions(options.application, localDefaults, [], options.timeoutMs,
			options.maxMessageBytes, options.maxCalls, options.maxQueuedBytes, options.protocol, options.codec);
	}

	/** NativeKit validates same-user peers and private paths on local sockets. */
	public function acceptLocal(transport:NativeRpcTransport):Void {
		accept(transport, null, localOptions, true);
	}

	public function acceptWebSocket(transport:NativeRpcTransport, token:String):Void {
		accept(transport, new SessionPreflight(transport, token, clock, true), options, false);
	}

	/** A Noise-authenticated remote peer is restricted to its persisted device grants. */
	public function acceptRemote(transport:MessageTransport, grants:Array<String>):Void {
		if (grants == null) {
			transport.close();
			return;
		}
		var allowed:Array<String> = [];
		for (grant in grants) {
			if (grant == null || allowed.indexOf(grant) >= 0 || options.offered().indexOf(grant) < 0) {
				transport.close();
				return;
			}
			allowed.push(grant);
		}
		var maxMessageBytes = Std.int(Math.min(options.maxMessageBytes, NoiseMessageTransport.MAX_PLAINTEXT_BYTES));
		var remoteOptions = new RpcPeerOptions(options.application, allowed, [], options.timeoutMs,
			maxMessageBytes, options.maxCalls,
			options.maxQueuedBytes < maxMessageBytes ? maxMessageBytes : options.maxQueuedBytes,
			options.protocol, options.codec);
		accept(transport, null, remoteOptions, false);
	}

	function accept(transport:MessageTransport, preflight:Null<SessionPreflight>, peerOptions:RpcPeerOptions, localAdmin:Bool):Void {
		prune();
		if (peers.length >= 16) {
			transport.close();
			return;
		}
		peers.push({
			transport: transport,
			options: peerOptions,
			localAdmin: localAdmin,
			preflight: preflight,
			handshake: preflight == null ? RpcHandshake.server(transport, clock, peerOptions) : null,
			connection: null,
			cleanup: []
		});
	}

	function prune():Void {
		var index = peers.length;
		while (index > 0) {
			index--;
			if (!peers[index].transport.isOpen()) {
				if (peers[index].connection != null)
					peers[index].connection.close();
				for (cleanup in peers[index].cleanup)
					cleanup();
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
				peer.handshake = RpcHandshake.server(peer.transport, clock, peer.options);
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
					if (pairingAdmin != null && peer.localAdmin
						&& grants.indexOf(workspace.service.WorkspacePairingProtocol.ADMIN) >= 0) {
						var admin = pairingAdmin;
						peer.connection.register(workspace.service.WorkspacePairingProtocol.CREATE, function(request, context) {
							admin.createInvitation(request.ttlSeconds, function(invitation, error) {
								if (error != null || invitation == null)
									context.fail({code: "pairing_unavailable", message: error == null ? "Could not create pairing invitation" : error, ambiguous: false});
								else
									context.respond(invitation);
							});
						});
						peer.connection.register(workspace.service.WorkspacePairingProtocol.LIST, function(_, context) {
							context.respond({pending: admin.listPending(), devices: admin.listDevices()});
						});
						peer.connection.register(workspace.service.WorkspacePairingProtocol.APPROVE, function(request, context) {
							admin.approve(request.deviceId, request.grants, function(error) {
								context.respond({accepted: error == null, error: error});
							});
						});
						peer.connection.register(workspace.service.WorkspacePairingProtocol.REJECT, function(request, context) {
							var accepted = admin.reject(request.deviceId);
							context.respond({accepted: accepted, error: accepted ? null : "pairing_not_found"});
						});
						peer.connection.register(workspace.service.WorkspacePairingProtocol.REVOKE, function(request, context) {
							admin.revoke(request.deviceId, function(error) {
								context.respond({accepted: error == null, error: error});
							});
						});
					}
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
					peer.cleanup.push(service.bind(peer.connection, grants));
					if (terminals != null) terminals.bind(peer.connection, grants);
					if (agents != null) agents.bind(peer.connection, grants);
					if (files != null) peer.cleanup.push(files.bind(peer.connection, grants));
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
			for (cleanup in peer.cleanup)
				cleanup();
		}
		peers.resize(0);
	}

	public function dispose():Void
		closeClients();
}
