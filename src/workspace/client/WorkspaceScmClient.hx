package workspace.client;

import haxe.io.Bytes;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceScmProtocol;
import workspace.service.WorkspaceScmProtocol.ScmApplyRequest;
import workspace.service.WorkspaceScmProtocol.ScmApplyResult;
import workspace.service.WorkspaceScmProtocol.ScmBranchesRequest;
import workspace.service.WorkspaceScmProtocol.ScmBranchesResult;
import workspace.service.WorkspaceScmProtocol.ScmOriginalRequest;
import workspace.service.WorkspaceScmProtocol.ScmOriginalResult;
import workspace.service.WorkspaceScmProtocol.ScmRepositoriesRequest;
import workspace.service.WorkspaceScmProtocol.ScmRepositoriesResult;
import workspace.service.WorkspaceScmProtocol.ScmSnapshotRequest;
import workspace.service.WorkspaceScmProtocol.ScmSnapshotResult;
import workspace.service.WorkspaceScmProtocol.ScmTrustRequest;
import workspace.service.WorkspaceScmProtocol.ScmTrustResult;
import workspace.service.WorkspaceScmProtocol.ScmUnwatchRequest;
import workspace.service.WorkspaceScmProtocol.ScmUnwatchResult;
import workspace.service.WorkspaceScmProtocol.ScmWatchEvent;
import workspace.service.WorkspaceScmProtocol.ScmWatchRequest;
import workspace.service.WorkspaceScmProtocol.ScmWatchResult;

/** Typed client for the workspace SCM methods and sequenced change notifications. */
class WorkspaceScmClient {
	public final connection:RpcConnection;
	final watchListeners:Map<String, Array<ScmWatchEvent->Void>> = [];

	public function new(connection:RpcConnection) {
		if (connection == null) throw "Workspace SCM client requires an RPC connection";
		this.connection = connection;
		connection.onNotification(WorkspaceScmProtocol.CHANGED, WorkspaceScmProtocol.decodeEvent, onChanged);
	}

	public function repositories(workspace:String, root:String, onSuccess:ScmRepositoriesResult->Void,
			onError:RpcError->Void, ?timeoutMs:Int = 10000):Void {
		connection.call(WorkspaceScmProtocol.REPOSITORIES, {workspace: workspace, root: root}, timeoutMs, onSuccess, onError);
	}

	public function snapshot(workspace:String, repository:String, onSuccess:ScmSnapshotResult->Void,
			onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceScmProtocol.SNAPSHOT, {workspace: workspace, repository: repository}, timeoutMs, onSuccess, onError);
	}

	public function branches(request:ScmBranchesRequest, onSuccess:ScmBranchesResult->Void,
			onError:RpcError->Void, ?timeoutMs:Int = 10000):Void {
		connection.call(WorkspaceScmProtocol.BRANCHES, request, timeoutMs, onSuccess, onError);
	}

	public function watch(workspace:String, root:String, epoch:Null<String>, cursor:Int, listener:ScmWatchEvent->Void,
		onSuccess:ScmWatchResult->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		var key = watchKey(workspace, root), listeners = watchListeners.get(key);
		if (listeners == null) { listeners = []; watchListeners.set(key, listeners); }
		if (listener != null && listeners.indexOf(listener) < 0) listeners.push(listener);
		connection.call(WorkspaceScmProtocol.WATCH, {workspace: workspace, root: root, epoch: epoch, cursor: cursor},
			timeoutMs, onSuccess, onError);
	}

	public function unwatch(workspace:String, root:String, listener:ScmWatchEvent->Void, ?timeoutMs:Int = 3000):Void {
		var key = watchKey(workspace, root), listeners = watchListeners.get(key);
		if (listeners != null && listener != null) listeners.remove(listener);
		if (listeners != null && listeners.length > 0) return;
		watchListeners.remove(key);
		connection.call(WorkspaceScmProtocol.UNWATCH, {workspace: workspace, root: root}, timeoutMs,
			function(_) {}, function(_) {});
	}

	public function original(request:ScmOriginalRequest, onSuccess:ScmOriginalResult->Void, onError:RpcError->Void,
			?timeoutMs:Int = 10000):Void {
		connection.call(WorkspaceScmProtocol.ORIGINAL, request, timeoutMs, onSuccess, onError);
	}

	public function apply(request:ScmApplyRequest, onSuccess:ScmApplyResult->Void, onError:RpcError->Void,
			?timeoutMs:Int = 30000):Void {
		connection.call(WorkspaceScmProtocol.APPLY, request, timeoutMs, onSuccess, onError);
	}

	public function trust(workspace:String, repository:String, onSuccess:ScmTrustResult->Void,
			onError:RpcError->Void, ?timeoutMs:Int = 10000):Void {
		connection.call(WorkspaceScmProtocol.TRUST, {workspace: workspace, repository: repository}, timeoutMs, onSuccess, onError);
	}

	function onChanged(event:ScmWatchEvent):Void {
		if (event == null || event.workspace == null || event.root == null) return;
		var listeners = watchListeners.get(watchKey(event.workspace, event.root));
		if (listeners != null) for (listener in listeners.copy()) listener(event);
	}

	static function watchKey(workspace:String, root:String):String
		return workspace.length + ":" + workspace + root.length + ":" + root;
}
