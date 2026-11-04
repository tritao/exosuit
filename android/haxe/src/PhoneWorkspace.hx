import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcClientState;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcPeerOptions;
import workspace.client.DeviceMachine;
import workspace.client.WorkspaceCatalogWatch;
import workspace.client.WorkspaceFileClient;
import workspace.client.WorkspaceTerminalEvents;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/**
	The workspace the phone has open: one stream of its machine's channel, run by the ordinary RpcClient (so it
	reconnects through OPEN when the stream or the channel goes), with the full client grants, a shared catalog watch on
	that connection, and the file and terminal helpers the shared Workbench client uses. PhoneRemote presents it to
	ExosuitApp as the attachment; other workspaces of the machine only have catalog watches (PhoneMachine's pool).

	Requests on the stream still name the service with the alias "workspace" (docs/roadmap/RPC-VECTORS.md); the catalog
	names it by id.
**/
class PhoneWorkspace {
	static final REQUESTED = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceProtocol.TREE,
		WorkspaceFileProtocol.READ, WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG, WorkspaceTerminalProtocol.CONTROL,
		WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL, WorkspaceCatalogProtocol.CAPABILITY];

	public final id:String;
	public final machine:DeviceMachine;
	public var root(default, null):Null<String>;
	public var serviceInstance(default, null) = "";
	public var grants(default, null):Array<String> = [];
	public var connection(default, null):Null<RpcConnection>;
	public var catalog(default, null):Null<WorkspaceCatalogWatch>;
	/** Why the workspace cannot be used (a refusal that will not clear by itself); null while it connects or works. */
	public var failure(default, null):Null<String>;

	final clock:Void->Float;
	final client:RpcClient;
	public var fileApiConnection:Null<RpcConnection>;
	public var fileApiClient:Null<WorkspaceFileClient>;
	public var terminalRouter:Null<WorkspaceTerminalEvents>;

	public function new(machine:DeviceMachine, id:String, clock:Void->Float) {
		this.machine = machine;
		this.id = id;
		this.clock = clock;
		var self = this;
		client = new RpcClient(machine.workspaceConnector(id), clock, function() return Math.random(),
			new RpcPeerOptions("exosuit-editor/1", REQUESTED, [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY], 5000, 262144, 32, 1048576),
			function(established, token, _) self.ready(established, token), 100, 10000, DeviceMachine.OPEN_TIMEOUT + 10000);
	}

	function ready(established:RpcConnection, token:Int):Void {
		established.call(WorkspaceProtocol.IDENTITY, {workspace: "workspace"}, 5000, function(identity) {
			if (!client.isCurrent(token)) return;
			if (identity == null || identity.root == null || identity.root.length == 0 || identity.instance == null || identity.instance.length == 0) {
				failure = "The workspace identity answer was invalid.";
				established.close("invalid_workspace_identity");
				return;
			}
			failure = null;
			connection = established;
			root = identity.root;
			serviceInstance = identity.instance;
			grants = client.capabilities();
			var machineId = machine.machineId;
			if (machineId != null && grants.indexOf(WorkspaceCatalogProtocol.CAPABILITY) >= 0) {
				var watch = catalog;
				if (watch == null) {
					watch = WorkspaceCatalogWatch.shared({machine: machineId, workspace: id}, clock, false);
					catalog = watch;
				}
				watch.attach(established);
			}
		}, function(_) {
			if (client.isCurrent(token)) {
				established.close("workspace_identity_check_failed");
			}
		});
	}

	public function isConnected():Bool
		return root != null && connection != null && client.current() == connection;

	/** True until the first connection is up, and again while it reconnects. */
	public function connecting():Bool
		return failure == null && !isConnected();

	public function poll():Void {
		client.poll();
		var watch = catalog;
		if (watch != null) watch.poll();
		if (client.state == RpcClientState.Closed && failure == null) {
			var code = client.lastError == null ? "" : client.lastError.code;
			failure = switch code {
				case "missing_capability", "capability_widening": "The owner has not granted this phone enough in this workspace.";
				case "unauthorized", "authorization_failed", "authentication_refused": "This phone may no longer open this workspace.";
				case _: "The workspace connection ended (" + code + ").";
			}
		}
		if (connection != null && client.current() != connection) connection = null;
	}

	public function dispose():Void {
		if (catalog != null) catalog.dispose();
		catalog = null;
		client.close();
		connection = null;
		fileApiConnection = null;
		fileApiClient = null;
		terminalRouter = null;
		root = null;
		grants = [];
	}
}
