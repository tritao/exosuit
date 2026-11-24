package workspace.client;

import haxeon.rpc.*;
import haxeon.platform.event.EventPump;
import workspace.client.OpenedService.ServiceOpener;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcConnector;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceAgentProtocol;
import workspace.transport.RpcCalls;

/**
	The window's link to one machine workspace: one connection to its service, for everything the window does there
	(the workspace it shows, the catalog rows of its tree, its terminals). `open` names the workspace's running service,
	which exohost starts first when the workspace is idle: on this machine exohost's `workspace.open` over the window's exohost
	link gives its pipe; on a paired device (the phone, the browser) the machine's OPEN gives a relay stream that exohost
	forwards to that pipe. The link connects, checks the service's IDENTITY against what exohost reported and watches its
	catalog.

	A link lives for its workspace only; WorkspaceLinks keeps one per workspace in use and closes it once unused. When
	the connection drops a link that `revive` says is wanted asks exohost again (which starts a new service if the old one
	stopped); any other link ends (`ended`) and is dropped. Closing a link never stops the service.
**/
class WorkspaceLink implements WorkspaceAttachment implements WorkspaceRpcEndpoint implements ServedRoots implements workspace.client.WorkspaceWorkbenchClient implements workspace.client.WorkspaceAgentClient {
	/** How long a first connection may take, the service's start included. */
	static inline final STARTUP_MILLISECONDS = 60000.0;

	/** The workspace this link is for; empty for the link of a window with no workspace, which never connects. */
	public final workspace:String;
	public var root(default, null):Null<String>;
	public var error(default, null):Null<String>;
	public var instance(default, null):String = "";
	public var ready(get, never):Bool;

	final hub:NativeRpcHub;
	final clock:Void->Float;
	final open:ServiceOpener;
	final workbench:RpcWorkspaceWorkbenchClient;
	var client:Null<RpcClient>;
	var fileApiConnection:Null<RpcConnection>;
	var fileApiClient:Null<WorkspaceFileClient>;
	/** The service's group epoch, which GROUP changes name; read once per connection, null until then. */
	var groupEpoch:Null<String>;
	/** The catalog watch on this client's connection: its CHANGED pushes are what make the lists be read again. */
	var catalog:Null<WorkspaceCatalogWatch>;
	/** True while exohost is asked for the service. */
	var opening:Bool = false;
	/** After a failure: the wait before exohost is asked again (doubling from 2 s to 30 s, back to 0 once ready), so a later fix is picked up. */
	var reopenDelay:Float = 0;
	var deadline:Float = 0;
	var startupDeadline:Float = 0;
	var retryAt:Float = 0;
	var selection:Int = 0;
	/** The workspace whose service this attaches to. */
	var serviceTarget:Null<WorkspaceServiceTarget>;
	var selectedTarget:Null<String>;
	var verified:Bool = false;
	var wasReady:Bool = false;
	/** The service is reached through a relay stream (a paired device), not its pipe on this machine. */
	var remote:Bool = false;
	var disposed:Bool = false;
	final events:EventPump;
	/** Whether a connection that dropped is made again (asking exohost, which may start the service); false ends the link. */
	public var revive:Void->Bool = function() return true;
	/** The connection dropped and `revive` said no: the link is done. */
	public var ended(default, null):Bool = false;

	/**
		`open` finds (and starts) a workspace's service: exohost's `workspace.open` in the editor, testing.DirectService in
		tests. A null `target` makes the link of a window with no workspace.
	**/
	public function new(events:EventPump, clock:Void->Float, open:ServiceOpener, target:Null<WorkspaceServiceTarget>) {
		this.events = events;
		this.hub = new NativeRpcHub(events);
		this.clock = clock;
		this.open = open;
		this.workbench = new RpcWorkspaceWorkbenchClient(this, clock);
		workbench.timelineName = timelineName;
		workbench.workspaceIdentity = function() return serviceTarget == null ? null : serviceTarget.workspace;
		workbench.catalogPushes = catalogRevision;
		workspace = target == null ? "" : target.workspace;
		if (target != null) {
			serviceTarget = target;
			selectedTarget = target.signature();
			startupDeadline = clock() + STARTUP_MILLISECONDS;
			ConnectTimeline.mark("attach", target.workspace);
			requestService();
		}
	}

	/**
		Whether `endpoint` has the shape the agent gives its service (AgentState.endpointOf): a named pipe
		`\\.\pipe\exosuit-<key>` on Windows, else `<state folder>/agent.sock`. exohost's reply is data from another
		process, so a link connects to nothing else.
	**/
	public static function validEndpoint(endpoint:String, windows:Bool = true):Bool {
		if (endpoint.length == 0 || endpoint.length > 1024 || endpoint.indexOf("\n") >= 0)
			return false;
		if (windows) {
			if (!StringTools.startsWith(endpoint, WINDOWS_PIPE) || endpoint.length == WINDOWS_PIPE.length)
				return false;
			for (index in WINDOWS_PIPE.length...endpoint.length) {
				var code = StringTools.fastCodeAt(endpoint, index);
				var plain = code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 45 || code == 95;
				if (!plain)
					return false;
			}
			return true;
		}
		if (!StringTools.startsWith(endpoint, "/") || !StringTools.endsWith(endpoint, "/agent.sock"))
			return false;
		return endpoint.split("/").indexOf("..") < 0;
	}

	static inline final WINDOWS_PIPE = "\\\\.\\pipe\\exosuit-";

	/** The catalog its service's watch holds, once read; null before. */
	public function catalogMirror():Null<WorkspaceCatalogMirror> {
		var watch = catalog;
		return watch == null || !verified || watch.mirror.token == null ? null : watch.mirror;
	}

	/** Whether the catalog watch is connected with a complete copy. */
	public function catalogLive():Bool {
		var watch = catalog;
		return watch != null && verified && watch.live;
	}

	/** Whether the link is asking exohost for the service or connecting to it, with no connection ready yet. */
	public function connecting():Bool
		return serviceTarget != null && error == null && !ready && !ended;

	/** The workspace this attachment's events are filed under in the ConnectTimeline. */
	public function timelineName():String {
		var active = serviceTarget;
		return active == null ? "" : active.workspace;
	}

	function get_ready():Bool return verified
		&& client != null && client.current() != null && groupEpoch != null;

	/** The revision of the catalog watch on the current connection; -1 without one. */
	public function catalogRevision():Int {
		var watch = catalog;
		return watch == null ? -1 : watch.revision;
	}

	public function rpc():Null<RpcConnection> return ready && client != null ? client.current() : null;

	public function rootPath():Null<String> return root;

	/**
		The machine workspace whose service this client is attached to, or null while not attached. Its `rootPath()` is
		then the folder that service started in, which need not be one of the workspace's folders now.
	**/
	public function servedWorkspace():Null<String> {
		var target = serviceTarget;
		return ready && target != null ? target.workspace : null;
	}

	/**
		Whether a terminal keyed by `path` belongs to the service this client attaches to: its root, or any of the
		workspace's folders (the service keeps the folder it started in).
	**/
	public function servesRoot(path:String):Bool {
		if (root == null) return false;
		if (root == path) return true;
		var target = serviceTarget;
		return target != null && (target.folders.indexOf(path) >= 0 || target.scratch == path);
	}

	public function serviceGeneration():String return instance;

	var terminalEventRouter:Null<WorkspaceTerminalEvents>;

	public function terminalEvents():Null<WorkspaceTerminalEvents> {
		var c = rpc();
		if (c == null) { terminalEventRouter = null; return null; }
		if (terminalEventRouter == null || terminalEventRouter.connection != c)
			terminalEventRouter = new WorkspaceTerminalEvents(c);
		return terminalEventRouter;
	}

	public function rpcConnection():Null<RpcConnection> return rpc();
	public function failureReason():Null<String> return error;
	public function supportsWorkspaceGroups():Bool return hasGroupTree();
	public function workspaceEpoch():Null<String> return groupEpoch;
	public function hasCapability(capability:String):Bool
		return client != null && client.capabilities().indexOf(capability) >= 0;

	/** A typed file API tied to the currently authenticated local workspace connection. */
	public function fileClient():Null<WorkspaceFileClient> {
		var connection = rpc();
		if (connection == null || client == null || client.capabilities().indexOf(WorkspaceFileProtocol.READ) < 0) {
			fileApiConnection = null;
			fileApiClient = null;
			return null;
		}
		if (connection != fileApiConnection) {
			fileApiConnection = connection;
			fileApiClient = new WorkspaceFileClient(connection);
		}
		return fileApiClient;
	}

	public function fileWorkspace():String return "workspace";
	public function fileScope():Null<String> return root;
	public function hasLocalFileAccess():Bool return !remote;
	/** Local desktop roots use Application.scm; this attachment owns no second SCM source. */
	public function sourceControlSource():Null<scm.ScmSource> return null;

	public function hasGroupTree():Bool return client != null && client.capabilities().indexOf(WorkspaceProtocol.TREE) >= 0;
	public function canEditGroups():Bool return workbench.canEditGroups();

	public function workspaceConnected():Bool return ready;

	/** The failure for a service that does not offer folder changes at all (as opposed to one not connected now). */
	public static inline final CANNOT_SET_FOLDERS = "The workspace service cannot change its folders; restart it to pick them up.";

	/**
		Tells the service to serve exactly `folders` now, with no restart (see WorkspaceFoldersProtocol). `done` gets the
		failure, or null once the service has changed its roots and watchers.
	**/
	public function setServedFolders(folders:Array<String>, done:Null<String>->Void):Void {
		var connection = rpc();
		if (connection == null) {
			done("The workspace service is not connected.");
			return;
		}
		if (!hasCapability(workspace.service.WorkspaceFoldersProtocol.CAPABILITY)) {
			done(CANNOT_SET_FOLDERS);
			return;
		}
		RpcCalls.call(connection, workspace.service.WorkspaceFoldersProtocol.SET, {folders: folders}, 5000, function(_) done(null),
			function(failure) done(failure.message));
	}

	public function agentService():WorkspaceAgentClient return workbench.agentService();
	public function canReadAgents():Bool return workbench.canReadAgents();
	public function canControlAgents():Bool return workbench.canControlAgents();
	public function agentBusy():Bool return workbench.agentBusy();
	public function agentCreation():Null<workspace.client.WorkspaceAgentCreation.AgentCreationStatus> return workbench.agentCreation();
	public function agentRevision():Int return workbench.agentRevision();
	public function agents():Null<AgentCatalog> return workbench.agents();
	public function agentError():Null<String> return workbench.agentError();
	public function refreshAgents():Void workbench.refreshAgents();
	public function showAgents(ids:Array<String>):Void workbench.showAgents(ids);
	public function createAgent(group:String, thread:Null<String>, ?created:AgentRecord->Void,
			?defaults:AgentSessionDefaults, ?failed:String->Void):Void
		workbench.createAgent(group, thread, created, defaults, failed);
	public function deleteAgent(id:String, ?deleted:Void->Void):Void workbench.deleteAgent(id, deleted);
	public function agentDeliveryUncertain(id:String):Bool return workbench.agentDeliveryUncertain(id);
	public function agentDeliveryReviewReady(id:String):Bool return workbench.agentDeliveryReviewReady(id);
	public function acknowledgeAgentDelivery(id:String):Bool return workbench.acknowledgeAgentDelivery(id);
	public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String, ?accepted:Void->Void, ?expectedNativeName:String, ?imageIds:Array<String>, ?order:Int):Void
		workbench.agentAction(id, action, text, request, model, effort, accepted, expectedNativeName, imageIds, order);
	public function uploadAgentImage(id:String, bytes:haxe.io.Bytes, done:(Null<String>, Null<String>)->Void):Void workbench.uploadAgentImage(id, bytes, done);
	public function removeAgentImage(id:String, upload:String):Void workbench.removeAgentImage(id, upload);
	public function loadAgentContent(id:String, turn:String, item:String, token:String, done:(Null<String>, Bool, Null<String>)->Void):Void workbench.loadAgentContent(id,turn,item,token,done);
	public function loadAgentImage(id:String, turn:String, item:String, imageId:String, done:(Null<haxe.io.Bytes>, Null<String>)->Void):Void workbench.loadAgentImage(id,turn,item,imageId,done);
	public function discoverAgents(group:String, cursor:Null<String>):Void workbench.discoverAgents(group, cursor);
	public function discoveredAgents():Null<AgentDiscovery> return workbench.discoveredAgents();
	public function agentView(id:String):Null<AgentView> return workbench.agentView(id);
	public function agentHistory(id:String):AgentHistoryState return workbench.agentHistory(id);
	public function loadOlderAgentItems(id:String, done:Null<String>->Void):Void workbench.loadOlderAgentItems(id,done);
	public function resetAgentHistory(id:String):Void workbench.resetAgentHistory(id);
	public function listModels(cursor:Null<String>, done:Null<AgentModelsPage>->Null<String>->Void):Void
		workbench.listModels(cursor, done);

	public function canReadTerminals():Bool return workbench.canReadTerminals();
	public function canControlTerminals():Bool return workbench.canControlTerminals();
	public function canCreateTerminals():Bool return workbench.canCreateTerminals();
	public function canCreateGroupedTerminals():Bool return workbench.canCreateGroupedTerminals();
	public function canReorder():Bool return workbench.canReorder();
	public function terminalCatalog():Null<TerminalCatalog> return workbench.terminalCatalog();
	public function terminalCatalogError():Null<String> return workbench.terminalCatalogError();
	public function terminalCatalogRevision():Int return workbench.terminalCatalogRevision();
	public function terminalCatalogBusy():Bool return workbench.terminalCatalogBusy();
	public function refreshTerminals(force:Bool):Void workbench.refreshTerminals(force);
	public function renameTerminal(record:TerminalRecord, name:String, group:String, ?order:Int):Void
		workbench.renameTerminal(record, name, group, order);
	public function canRemoveGroups():Bool return workbench.canRemoveGroups();
	public function removeGroup(owner:String, group:WorkspaceGroup):Void workbench.removeGroup(owner, group);
	public function changeGroup(owner:String, group:WorkspaceGroup, name:String, parent:Null<String>,
			cwd:Null<String>, order:Int, create:Bool, ?done:(Null<WorkspaceGroup>, Null<String>)->Void):Void
		workbench.changeGroup(owner, group, name, parent, cwd, order, create, done);
	public function stopTerminal(record:TerminalRecord):Void workbench.stopTerminal(record);
	public function restartTerminal(record:TerminalRecord):Void workbench.restartTerminal(record);
	public function forgetTerminal(record:TerminalRecord):Void workbench.forgetTerminal(record);
	public function closeTerminal(record:TerminalRecord, ?closed:Void->Void):Void workbench.closeTerminal(record, closed);

	public function failure():Null<String> return error;

	public function statusLabel():String {
		if (serviceTarget == null) return "";
		if (error != null) return "Workspace unavailable";
		if (ready) return "Workspace connected";
		return wasReady ? "Workspace reconnecting" : "Connecting workspace…";
	}

	/**
		The workspace's folders changed: the service follows them without a restart (`setServedFolders`), so the
		connection stays, and with it the catalog, the terminals and the sessions.
	**/
	public function follow(next:WorkspaceServiceTarget):Void {
		if (disposed || next.workspace != workspace) return;
		var signature = next.signature();
		if (signature == selectedTarget) return;
		selectedTarget = signature;
		serviceTarget = next;
	}

	function stopCatalog():Void {
		var watch = catalog;
		catalog = null;
		if (watch != null) watch.dispose();
	}

	function stopConnection():Void {
		terminalEventRouter = null;
		groupEpoch = null;
		stopCatalog();
		if (client != null) client.close();
		client = null;
		verified = false;
		opening = false;
		workbench.poll();
	}

	/**
		Shows `message` and asks exohost again after the backoff. A service of another identity is not asked again, and a
		link that was ready ends when `revive` says no, as when its connection drops.
	**/
	function fail(message:String, retry:Bool = true):Void {
		error = message;
		stopConnection();
		if (retry && wasReady && !revive()) {
			ended = true;
			return;
		}
		reopenDelay = retry ? Math.min(30000, Math.max(2000, reopenDelay * 2)) : 0;
		retryAt = clock() + reopenDelay;
	}

	/** Asks for the workspace's service (exohost starts it when it is idle), then connects to it. */
	function requestService():Void {
		var target = serviceTarget;
		if (target == null || disposed) return;
		// exohost does not count the service of a workspace this window uses as orphaned.
		var link = exohost.ExohostLink.instance;
		if (link != null) link.usesWorkspace(target.workspace);
		opening = true;
		var selected = selection;
		ConnectTimeline.mark("open-asked", timelineName());
		open(target.workspace, function(service, failure) {
			if (disposed || selected != selection || !opening) return;
			opening = false;
			if (service == null) {
				fail(failure == null ? "The workspace service did not start" : failure);
				return;
			}
			try install(service) catch (problem:Dynamic) fail(Std.string(problem));
		});
	}

	function install(service:OpenedService):Void {
		var route = service.connector;
		if (route == null && !validEndpoint(service.endpoint, Sys.systemName() == "Windows") || service.generation.length != 32
			|| service.root.length == 0) throw "exohost named an invalid workspace service";
		remote = route != null;
		var expectedInstance = service.generation, expectedRoot = service.root, selected = selection;
		// A workspace's service keeps the root it started in, which later changes to the workspace's folders do not move.
		root = service.root;
		instance = expectedInstance;
		verified = false;
		var required = [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY];
		var caps = required.copy();
		caps.push(WorkspaceProtocol.WRITE);
		caps.push(WorkspaceProtocol.TREE);
		caps.push(WorkspaceProtocol.REMOVE);
		caps.push(WorkspaceProtocol.ORDER);
		caps.push(WorkspaceTerminalProtocol.CATALOG);
		caps.push(WorkspaceAgentProtocol.READ);
		caps.push(WorkspaceAgentProtocol.CONTROL);
		caps.push(WorkspaceTerminalProtocol.READ);
		caps.push(WorkspaceTerminalProtocol.CONTROL);
		caps.push(WorkspaceFileProtocol.READ);
		caps.push(workspace.service.WorkspaceFoldersProtocol.CAPABILITY);
		caps.push(WorkspaceCatalogProtocol.CAPABILITY);
		deadline = clock() + 12000;
		ConnectTimeline.mark("discovered", timelineName());
		// A relay stream starts with exohost's OPEN, which may start the service: it gets the time that takes.
		var connectMs = route == null ? 2000 : 40000;
		client = new RpcClient(route != null ? route : new NativeRpcConnector(hub,
			NativeRpcHub.local(service.endpoint)), clock, function() return Math.random(), new RpcPeerOptions(
				"exosuit-editor/1",
				caps,
				required,
				remote ? 8000 : 2000,
				262144,
				32,
				1048576
			), function(connection, token, _) connected(connection, token, expectedInstance, expectedRoot, selected),
			100, route == null ? 1000 : 10000, connectMs);
		if (remote) deadline = clock() + connectMs + 12000;
	}

	/** The network came back or changed: a relay link dials now instead of waiting out its backoff (see RpcClient.retryNow). */
	public function retryNow(redial:Bool):Void {
		var current = client;
		if (current != null) current.retryNow(redial);
		else if (error != null && reopenDelay > 0) retryAt = clock();
	}

	/**
		The connection made in `install` (or after it reconnected by itself) completed its handshake: checks the service's
		identity, reads the group epoch and starts the catalog watch.
	**/
	function connected(connection:RpcConnection, token:Int, expectedInstance:String, expectedRoot:String, selected:Int):Void {
		ConnectTimeline.mark("handshake", timelineName());
		var current = client;
		if (current == null || selected != selection) return;
		verified = false;
		groupEpoch = null;
		stopCatalog();
		if (current.remoteApplication != "exosuit-agent/1") {
			fail("Unexpected workspace service");
			return;
		}
		// IDENTITY, QUERY and the catalog watch go out together: one round trip, not three. Nothing they bring is used
		// before IDENTITY names the generation exohost reported (`ready` needs `verified`), and a mismatch drops them all.
		var callMs = remote ? 8000 : 2000;
		RpcCalls.call(connection, WorkspaceProtocol.IDENTITY, {workspace: "workspace"}, callMs, function(identity) {
			if (selected != selection || !current.isCurrent(token)) return;
			// Another generation answers on the pipe: the service exohost named stopped and another took its place. Ask again.
			if (identity.instance != expectedInstance) {
				stopConnection();
				retryAt = clock() + 100;
				return;
			}
			if (identity.workspace != "workspace" || identity.root != expectedRoot) {
				fail("Workspace service identity mismatch", false);
				return;
			}
			verified = true;
			ConnectTimeline.mark("identity-verified", timelineName());
			deadline = clock() + (remote ? 20000 : 6000);
		}, function(failure) {
			if (selected != selection || !current.isCurrent(token)) return;
			fail("Workspace identity validation failed: " + failure.code);
		});
		RpcCalls.call(connection, WorkspaceProtocol.QUERY, {workspace: "workspace"}, callMs, function(snapshot) {
			if (selected != selection || !current.isCurrent(token) || error != null) return;
			ConnectTimeline.mark("query-reply", timelineName());
			if (snapshot.epoch == null || snapshot.epoch.length == 0) { fail("Workspace catalog unavailable: invalid_response"); return; }
			groupEpoch = snapshot.epoch;
		}, function(failure) {
			if (selected != selection || !current.isCurrent(token)) return;
			fail("Workspace catalog unavailable: " + failure.code);
		});
		// The service names its real id in the first page; the machine is only echoed back.
		if (hasCapability(WorkspaceCatalogProtocol.CAPABILITY)) {
			var watch = WorkspaceCatalogWatch.shared({machine: "local", workspace: "workspace"}, clock, true);
			catalog = watch;
			watch.attach(connection);
		}
	}

	public function poll():Void {
		workbench.poll();
		if (disposed || ended || serviceTarget == null) return;
		var now = clock();
		if (error != null) {
			if (reopenDelay == 0 || now < retryAt) return;
			error = null;
			startupDeadline = now + STARTUP_MILLISECONDS;
		}
		if (!wasReady && now >= startupDeadline) {
			fail("Workspace startup timed out");
			return;
		}
		var current = client;
		if (current == null) {
			if (!opening && now >= retryAt) requestService();
			return;
		}
		current.poll();
		workbench.poll();
		if (client != current || error != null) return;
		if (current.state == Closed && !wasReady) {
			fail(current.lastError == null ? "Workspace connection closed" : current.lastError.code);
			return;
		}
		var watch = catalog;
		if (watch != null) watch.poll();
		if (ready) {
			if (!wasReady) ConnectTimeline.mark("ready", timelineName());
			wasReady = true;
			reopenDelay = 0;
			// Over the relay a dropped stream comes back through the client's own reconnect (a new OPEN), which takes longer.
			deadline = now + (remote ? 20000 : 3000);
			return;
		}
		if (current.state == Closed || now >= deadline) {
			stopConnection();
			// The connection closed, or has not been ready for 3 s (the client redials a pipe that may be gone): the
			// service stopped (idle, exohost restarted it on another build, the user stopped it), or never got ready. A link
			// the window needs asks exohost again, which starts a new one; a link kept only for the tree's rows ends.
			if (wasReady && !revive()) {
				ended = true;
				return;
			}
			retryAt = now + (wasReady ? 250 : 1000);
		}
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		selection++;
		stopConnection();
		workbench.dispose();
		hub.dispose();
		root = null;
	}
}
