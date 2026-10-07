package workspace.client;

import haxe.Int64;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceFileProtocol.FileRootsResult;
import workspace.service.WorkspaceFileProtocol.FileStatResult;
import workspace.service.WorkspaceFileProtocol.FileListPage;
import workspace.service.WorkspaceFileProtocol.FileReadOpenResult;
import workspace.service.WorkspaceFileProtocol.FileReadChunkResult;
import workspace.service.WorkspaceFileProtocol.FileReadCloseResult;
import workspace.service.WorkspaceFileProtocol.FileWatchResult;
import workspace.service.WorkspaceFileProtocol.FileChangeEvent;
import workspace.service.WorkspaceFileProtocol.FileSearchHandle;
import workspace.service.WorkspaceFileProtocol.FileSearchPageResult;
import workspace.service.WorkspaceFileProtocol.FileSearchCancelResult;

/** Typed workspace file operations over any negotiated Exosuit RPC connection. */
class WorkspaceFileClient {
	final connection:RpcConnection;
	final watchListeners:Map<String, Array<FileChangeEvent->Void>> = [];

	public function new(connection:RpcConnection) {
		if (connection == null)
			throw "Workspace file client requires an RPC connection";
		this.connection = connection;
		connection.onNotification(WorkspaceFileProtocol.CHANGED, WorkspaceFileProtocol.decodeChange, onChanged);
	}

	public function roots(workspace:String, onSuccess:FileRootsResult->Void, onError:RpcError->Void,
		?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.ROOTS, {workspace: workspace}, timeoutMs, onSuccess, onError);
	}

	public function stat(workspace:String, root:String, path:String, onSuccess:FileStatResult->Void,
		onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.STAT,
			{workspace: workspace, root: root, path: path}, timeoutMs, onSuccess, onError);
	}

	public function list(workspace:String, root:String, path:String, limit:Int, cursor:Null<String>,
		onSuccess:FileListPage->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.LIST,
			{workspace: workspace, root: root, path: path, limit: limit, cursor: cursor}, timeoutMs, onSuccess, onError);
	}

	public function openRead(workspace:String, root:String, path:String, expectedRevision:Null<String>,
		onSuccess:FileReadOpenResult->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.READ_OPEN,
			{workspace: workspace, root: root, path: path, expectedRevision: expectedRevision}, timeoutMs, onSuccess, onError);
	}

	public function readChunk(workspace:String, handle:String, offset:Int64, length:Int,
		onSuccess:FileReadChunkResult->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.READ_CHUNK,
			{workspace: workspace, handle: handle, offset: offset, length: length}, timeoutMs, onSuccess, onError);
	}

	public function closeRead(workspace:String, handle:String, onSuccess:FileReadCloseResult->Void,
		onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.READ_CLOSE,
			{workspace: workspace, handle: handle}, timeoutMs, onSuccess, onError);
	}

	public function searchStart(workspace:String, root:String, mode:String, query:String, caseSensitive:Bool,
		onSuccess:FileSearchHandle->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.SEARCH_START,
			{workspace: workspace, root: root, mode: mode, query: query, caseSensitive: caseSensitive},
			timeoutMs, onSuccess, onError);
	}

	public function searchPage(workspace:String, root:String, searchId:String, limit:Int,
		onSuccess:FileSearchPageResult->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.SEARCH_PAGE,
			{workspace: workspace, root: root, searchId: searchId, limit: limit}, timeoutMs, onSuccess, onError);
	}

	public function searchCancel(workspace:String, root:String, searchId:String,
		onSuccess:FileSearchCancelResult->Void, onError:RpcError->Void, ?timeoutMs:Int = 5000):Void {
		connection.call(WorkspaceFileProtocol.SEARCH_CANCEL,
			{workspace: workspace, root: root, searchId: searchId}, timeoutMs, onSuccess, onError);
	}

	public function watch(workspace:String, root:String, epoch:Null<String>, cursor:Int,
		listener:FileChangeEvent->Void, onSuccess:FileWatchResult->Void, onError:RpcError->Void,
		?timeoutMs:Int = 5000):Void {
		var key = watchKey(workspace, root), listeners = watchListeners.get(key);
		if (listeners == null) {
			listeners = [];
			watchListeners.set(key, listeners);
		}
		if (listener != null && listeners.indexOf(listener) < 0) listeners.push(listener);
		connection.call(WorkspaceFileProtocol.WATCH,
			{workspace: workspace, root: root, epoch: epoch, cursor: cursor}, timeoutMs, onSuccess, onError);
	}

	public function unwatch(workspace:String, root:String, listener:FileChangeEvent->Void,
		?timeoutMs:Int = 5000):Void {
		var key = watchKey(workspace, root), listeners = watchListeners.get(key);
		if (listeners != null && listener != null) listeners.remove(listener);
		if (listeners != null && listeners.length > 0) return;
		watchListeners.remove(key);
		connection.call(WorkspaceFileProtocol.UNWATCH, {workspace: workspace, root: root}, timeoutMs,
			function(_) {}, function(_) {});
	}

	function onChanged(event:FileChangeEvent):Void {
		if (event == null || event.workspace == null || event.root == null) return;
		var listeners = watchListeners.get(watchKey(event.workspace, event.root));
		if (listeners == null) return;
		for (listener in listeners.copy()) listener(event);
	}

	static function watchKey(workspace:String, root:String):String
		return workspace.length + ":" + workspace + root.length + ":" + root;
}
