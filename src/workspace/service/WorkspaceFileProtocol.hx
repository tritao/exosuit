package workspace.service;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceProtocol.WorkspaceQuery;

@:wire typedef FileRootDescriptor = {
	@:id(1) var id:String;
	@:id(2) var name:String;
	@:id(3) var capabilities:Array<String>;
}

@:wire typedef FileRootsResult = {
	@:id(1) var workspace:String;
	@:id(2) var roots:Array<FileRootDescriptor>;
}

@:wire typedef FileStatRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var path:String;
}

@:wire typedef WorkspaceFileEntry = {
	@:id(1) var name:Null<String>;
	@:id(2) var kind:String;
	@:id(3) var size:Int64;
	@:id(4) var modifiedUnixNs:Int64;
	@:id(5) var fileIdHigh:Int64;
	@:id(6) var fileIdLow:Int64;
	@:id(7) var nameUnsupported:Bool;
	@:id(8) var revision:String;
}

@:wire typedef FileStatResult = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var path:String;
	@:id(4) var entry:WorkspaceFileEntry;
}

@:wire typedef FileListRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var path:String;
	@:id(4) var limit:Int;
	@:id(5) var cursor:Null<String>;
}

@:wire typedef FileListPage = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var path:String;
	@:id(4) var directoryRevision:String;
	@:id(5) var entries:Array<WorkspaceFileEntry>;
	@:id(6) var next:Null<String>;
}

@:wire typedef FileReadOpenRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var path:String;
	@:id(4) var expectedRevision:Null<String>;
}

@:wire typedef FileReadOpenResult = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var path:String;
	@:id(4) var handle:String;
	@:id(5) var revision:String;
	@:id(6) var size:Int64;
}

@:wire typedef FileReadChunkRequest = {
	@:id(1) var workspace:String;
	@:id(2) var handle:String;
	@:id(3) var offset:Int64;
	@:id(4) var length:Int;
}

@:wire typedef FileReadChunkResult = {
	@:id(1) var handle:String;
	@:id(2) var revision:String;
	@:id(3) var offset:Int64;
	@:id(4) var bytes:Bytes;
	@:id(5) var eof:Bool;
}

@:wire typedef FileReadCloseRequest = {
	@:id(1) var workspace:String;
	@:id(2) var handle:String;
}

@:wire typedef FileReadCloseResult = {
	@:id(1) var closed:Bool;
}

@:wire typedef FileWatchRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var epoch:Null<String>;
	@:id(4) var cursor:Int;
}

@:wire typedef FileWatchResult = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var epoch:String;
	@:id(4) var cursor:Int;
	@:id(5) var reset:Bool;
}

@:wire typedef FileUnwatchRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
}

@:wire typedef FileUnwatchResult = {
	@:id(1) var unwatched:Bool;
}

@:wire typedef FileChangeEvent = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var epoch:String;
	@:id(4) var cursor:Int;
}

@:wire typedef FileSearchStartRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	/** "name" searches entry names; "content" searches UTF-8 text in regular files. */
	@:id(3) var mode:String;
	@:id(4) var query:String;
	@:id(5) var caseSensitive:Bool;
}

@:wire typedef FileSearchHandle = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var searchId:String;
}

@:wire typedef FileSearchPageRequest = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var searchId:String;
	@:id(4) var limit:Int;
}

@:wire typedef FileSearchMatch = {
	@:id(1) var path:String;
	@:id(2) var kind:String;
	@:id(3) var revision:String;
	/** Content matches use zero-based lines and UTF-8 byte columns; name matches use -1. */
	@:id(4) var line:Int;
	@:id(5) var column:Int;
	@:id(6) var length:Int;
	@:id(7) var preview:String;
}

@:wire typedef FileSearchPageResult = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var searchId:String;
	@:id(4) var matches:Array<FileSearchMatch>;
	@:id(5) var complete:Bool;
	@:id(6) var truncated:Bool;
	@:id(7) var scannedFiles:Int;
	@:id(8) var scannedBytes:Int;
	@:id(9) var skippedEntries:Int;
	@:id(10) var scannedEntries:Int;
}

@:wire typedef FileSearchCancelResult = {
	@:id(1) var cancelled:Bool;
}

/** Permanent ids for root-scoped workspace file metadata operations. */
class WorkspaceFileProtocol {
	public static inline final READ = "workspace.files.read";
	public static final ROOTS = new RpcMethod<WorkspaceQuery, FileRootsResult>(140,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):WorkspaceQuery return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileRootsResult return MessagePack.decode(bytes));
	public static final STAT = new RpcMethod<FileStatRequest, FileStatResult>(141,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileStatRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileStatResult return MessagePack.decode(bytes));
	public static final LIST = new RpcMethod<FileListRequest, FileListPage>(142,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileListRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileListPage return MessagePack.decode(bytes));
	public static final READ_OPEN = new RpcMethod<FileReadOpenRequest, FileReadOpenResult>(143,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileReadOpenRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileReadOpenResult return MessagePack.decode(bytes));
	public static final READ_CHUNK = new RpcMethod<FileReadChunkRequest, FileReadChunkResult>(144,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileReadChunkRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileReadChunkResult return MessagePack.decode(bytes));
	public static final READ_CLOSE = new RpcMethod<FileReadCloseRequest, FileReadCloseResult>(145,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileReadCloseRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileReadCloseResult return MessagePack.decode(bytes));
	public static final WATCH = new RpcMethod<FileWatchRequest, FileWatchResult>(146,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileWatchRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileWatchResult return MessagePack.decode(bytes));
	public static final UNWATCH = new RpcMethod<FileUnwatchRequest, FileUnwatchResult>(147,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileUnwatchRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileUnwatchResult return MessagePack.decode(bytes));
	public static inline final CHANGED = 148;

	public static function encodeChange(event:FileChangeEvent):Bytes return MessagePack.encode(event);
	public static function decodeChange(bytes:Bytes):FileChangeEvent return MessagePack.decode(bytes);
	public static final SEARCH_START = new RpcMethod<FileSearchStartRequest, FileSearchHandle>(149,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileSearchStartRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileSearchHandle return MessagePack.decode(bytes));
	public static final SEARCH_PAGE = new RpcMethod<FileSearchPageRequest, FileSearchPageResult>(150,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileSearchPageRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileSearchPageResult return MessagePack.decode(bytes));
	public static final SEARCH_CANCEL = new RpcMethod<FileSearchHandle, FileSearchCancelResult>(151,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileSearchHandle return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):FileSearchCancelResult return MessagePack.decode(bytes));
}
