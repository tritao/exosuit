package workspace.transport;

import haxeon.rpc.*;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminals;
import workspace.service.WorkspaceTerminalProtocol;

/** Registers the catalog watch on a connection with its grants; returns the connection's cleanup. */
typedef CatalogBinding = RpcConnection->Array<String>->CatalogCleanup;

typedef CatalogCleanup = Void->Void;

private typedef Peer = {var transport:MessageTransport; var probeUntil:Float; var options:RpcPeerOptions; var forwarded:Bool; var handshake:Null<RpcHandshake>; var connection:Null<RpcConnection>; var cleanup:Array<Void->Void>;}

/** Bounded headless service loop, shared by daemon and transport tests. */
class WorkspaceRpcServer {
	/** Connections other than forwarded device streams: the owner's editors and clients. */
	static inline final PEER_LIMIT = 16;
	/** Device streams exohost forwards, for all devices together. */
	static inline final FORWARDED_PEER_LIMIT = 16;

	final service:WorkspaceService;
	final clock:Void->Float;
	final identity:Null<WorkspaceIdentity>;
	final terminals:Null<WorkspaceTerminals>;
	final agents:Null<workspace.service.WorkspaceAgents>;
	var catalogBinding:Null<CatalogBinding>;
	var setFolders:Null<Array<String>->Array<String>>;
	final files:Null<workspace.runtime.WorkspaceFileService>;
	final scm:Null<workspace.runtime.WorkspaceScmService>;
	final peers:Array<Peer> = [];

	public final options:RpcPeerOptions;
	var localOptions:RpcPeerOptions;

	/**
		Offers the catalog watch (`workspace.catalog`, M19 Phase 6) on local connections; `bind` registers it on each
		and returns the connection's cleanup.
	**/
	public function enableCatalog(bind:CatalogBinding):Void {
		catalogBinding = bind;
		var offered = localOptions.offered();
		if (offered.indexOf(workspace.service.WorkspaceCatalogProtocol.CAPABILITY) < 0)
			offered.push(workspace.service.WorkspaceCatalogProtocol.CAPABILITY);
		localOptions = new RpcPeerOptions(options.application, offered, [], options.timeoutMs,
			options.maxMessageBytes, options.maxCalls, options.maxQueuedBytes);
	}

	/** What a paired device may be granted: the service's offered set, plus the catalog watch when it is enabled (a device reads its workspace with it). */
	function remoteOffered():Array<String> {
		var offered = options.offered();
		if (catalogBinding != null && offered.indexOf(workspace.service.WorkspaceCatalogProtocol.CAPABILITY) < 0)
			offered.push(workspace.service.WorkspaceCatalogProtocol.CAPABILITY);
		return offered;
	}

	/** Lets same-user peers change the folders served; `change` returns the folders now served, or throws a message. */
	public function enableFolders(change:Array<String>->Array<String>):Void {
		setFolders = change;
		var offered = localOptions.offered();
		offered.push(workspace.service.WorkspaceFoldersProtocol.CAPABILITY);
		localOptions = new RpcPeerOptions(options.application, offered, [], options.timeoutMs,
			options.maxMessageBytes, options.maxCalls, options.maxQueuedBytes);
	}

	function registerFolders(connection:haxeon.rpc.RpcConnection, grants:Array<String>, localAdmin:Bool):Void {
		var setter = setFolders;
		if (!localAdmin || setter == null || grants.indexOf(workspace.service.WorkspaceFoldersProtocol.CAPABILITY) < 0) return;
		connection.register(workspace.service.WorkspaceFoldersProtocol.SET, function(request, context) {
			answerFolders(setter, request, context);
		});
	}

	static function answerFolders(change:Array<String>->Array<String>, request:workspace.service.WorkspaceFoldersProtocol.FoldersSetRequest,
			context:haxeon.rpc.RpcContext<workspace.service.WorkspaceFoldersProtocol.FoldersSetResult>):Void {
		if (request == null || request.folders == null) {
			context.fail(new RpcError("invalid_request", "Invalid folder list", false));
			return;
		}
		try {
			var folders = change(request.folders);
			context.respond({folders: folders, roots: folders.length == 0 ? 1 : folders.length});
		} catch (error:Dynamic) {
			context.fail(new RpcError("invalid_folders", Std.string(error), false));
		}
	}

	/** Only authenticated, fully negotiated connections keep the daemon alive. */
	public function clientCount():Int {
		var count = 0;
		for (peer in peers)
			if (peer.connection != null && peer.connection.isOpen())
				count++;
		return count;
	}

	public function new(service:WorkspaceService, clock:Void->Float, ?capabilities:Array<String>, ?identity:WorkspaceIdentity,
			?terminals:WorkspaceTerminals, ?agents:workspace.service.WorkspaceAgents, ?files:workspace.runtime.WorkspaceFileService,
			?scm:workspace.runtime.WorkspaceScmService) {
		this.service = service;
		this.terminals = terminals;
		this.agents = agents;
		this.files = files;
		this.scm = scm;
		this.clock = clock;
		this.identity = identity == null ? null : {workspace: identity.workspace, root: identity.root, instance: identity.instance};
		if (identity != null && (identity.workspace != service.id || identity.root.length == 0 || identity.instance.length == 0))
			throw "Invalid daemon identity";
		var defaults = [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE, WorkspaceProtocol.REMOVE,
			WorkspaceProtocol.ORDER];
		if (scm != null) {
			defaults.push(workspace.service.WorkspaceScmProtocol.READ);
			defaults.push(workspace.service.WorkspaceScmProtocol.WRITE);
			defaults.push(workspace.service.WorkspaceScmProtocol.REMOTE);
		}
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
		localOptions = options;
	}

	/** NativeKit validates same-user peers and private paths on local sockets. */
	public function acceptLocal(transport:NativeRpcTransport):Void {
		accept(transport);
	}

	/** In-memory transport seam for test fixtures: a local client's connection, or a forwarded device stream when its first message is exohost's intro. */
	@:allow(app)
	private function acceptTestLocal(transport:MessageTransport):Void {
		accept(transport);
	}

	/**
		What a stream exohost forwards for a paired device may do on this service: the grants it names, less any this
		build of the service does not offer (exohost cannot know them while the service is idle).
	**/
	function forwardedOptions(grants:Array<String>):RpcPeerOptions {
		var offered = remoteOffered(), allowed:Array<String> = [];
		for (grant in grants)
			if (offered.indexOf(grant) >= 0 && allowed.indexOf(grant) < 0)
				allowed.push(grant);
		// The stream frame's header takes part of the Noise message, so a message here is smaller than a local one.
		var maxMessageBytes = Std.int(Math.min(options.maxMessageBytes, ForwardedStream.MAX_MESSAGE_BYTES));
		return new RpcPeerOptions(options.application, allowed, [], options.timeoutMs, maxMessageBytes, options.maxCalls,
			options.maxQueuedBytes < maxMessageBytes ? maxMessageBytes : options.maxQueuedBytes);
	}

	/** Waits for a local connection's first message: exohost's intro makes it a forwarded device stream; anything else is a normal client's hello. */
	function classify(peer:Peer):Void {
		var first = peer.transport.receive();
		if (first == null) {
			if (clock() >= peer.probeUntil)
				peer.transport.close();
			return;
		}
		peer.probeUntil = 0;
		if (ForwardedStream.isIntro(first)) {
			var intro = ForwardedStream.parse(first);
			if (intro == null || forwardedCount() >= FORWARDED_PEER_LIMIT) {
				peer.transport.close();
				return;
			}
			peer.options = forwardedOptions(intro.grants);
			peer.forwarded = true;
		} else
			peer.transport = new PushbackTransport(first, peer.transport);
		peer.handshake = RpcHandshake.server(peer.transport, clock, peer.options);
	}

	/** A connection starts as a local client's; its first message may make it a forwarded device stream (`classify`). */
	function accept(transport:MessageTransport):Void {
		prune();
		// Device streams exohost forwards have a pool of their own, so devices cannot take the slots the owner's editor needs.
		if (peers.length - forwardedCount() >= PEER_LIMIT) {
			transport.close();
			return;
		}
		peers.push({
			transport: transport,
			options: localOptions,
			forwarded: false,
			probeUntil: clock() + 5000,
			handshake: null,
			connection: null,
			cleanup: []
		});
	}

	function forwardedCount():Int {
		var count = 0;
		for (peer in peers)
			if (peer.forwarded)
				count++;
		return count;
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
			if (peer.probeUntil > 0) {
				classify(peer);
				if (peer.handshake == null)
					continue;
			}
			var handshake = peer.handshake;
			if (handshake != null) {
				handshake.poll();
				// A poll that reads the Hello only queues the Welcome; send it now rather than on the next loop turn.
				if (!handshake.isFinished())
					handshake.poll();
				if (!handshake.isFinished())
					continue;
				peer.handshake = null;
				peer.connection = handshake.connection;
				if (peer.connection != null) {
					var grants = handshake.capabilities();
					registerFolders(peer.connection, grants, !peer.forwarded);
					var currentIdentity = identity;
					if (currentIdentity != null)
						peer.connection.register(WorkspaceProtocol.IDENTITY, function(request, context) {
							if (grants.indexOf(WorkspaceProtocol.READ) < 0 || grants.indexOf(WorkspaceProtocol.IDENTITY_CAPABILITY) < 0) {
								context.fail(new RpcError("unauthorized", "Identity query denied", false));
								return;
							}
							if (request.workspace != service.id) {
								context.fail(new RpcError("invalid_request", "Invalid workspace identity query", false));
								return;
							}
							context.respond({workspace: currentIdentity.workspace, root: currentIdentity.root, instance: currentIdentity.instance});
						});
					peer.cleanup.push(service.bind(peer.connection, grants));
					if (terminals != null) terminals.bind(peer.connection, grants, peer.forwarded ? "remote" : "local");
					if (agents != null) agents.bind(peer.connection, grants);
					if (files != null) peer.cleanup.push(files.bind(peer.connection, grants));
					if (scm != null) peer.cleanup.push(scm.bind(peer.connection, grants, !peer.forwarded));
					var catalog = catalogBinding;
					if (catalog != null) peer.cleanup.push(catalog(peer.connection, grants));
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
