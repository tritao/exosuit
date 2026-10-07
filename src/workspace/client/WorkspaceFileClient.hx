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

/** Typed workspace file operations over any negotiated Exosuit RPC connection. */
class WorkspaceFileClient {
	final connection:RpcConnection;

	public function new(connection:RpcConnection) {
		if (connection == null)
			throw "Workspace file client requires an RPC connection";
		this.connection = connection;
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
}
