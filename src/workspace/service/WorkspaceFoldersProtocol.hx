package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

@:wire
typedef FoldersSetRequest = {
	@:id(1) var folders:Array<String>;
}

@:wire
typedef FoldersSetResult = {
	/** The folders now recorded for the workspace, normalized and in order. */
	@:id(1) var folders:Array<String>;
	/** How many roots the service serves: the folders, or its fallback folder when there are none. */
	@:id(2) var roots:Int;
}

// Same-user change of the folders a workspace service serves, without restarting it: file service roots, watchers
// and source control roots follow, and the list is kept in the state folder's workspace.json. Never offered to remote
// or loopback WebSocket peers.
class WorkspaceFoldersProtocol {
	public static inline final CAPABILITY = "workspace.folders.manage";
	public static final SET = new RpcMethod<FoldersSetRequest, FoldersSetResult>(153,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FoldersSetRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FoldersSetResult return MessagePack.decode(bytes));
}
