package workspace.service;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceProtocol.WorkspaceRepositoryRequest;
import workspace.service.WorkspaceProtocol.WorkspaceRootRequest;
import workspace.service.WorkspaceProtocol.WorkspaceRootWatchRequest;
import workspace.service.WorkspaceProtocol.WorkspaceUnwatchResult;

@:wire typedef WorkspaceScmRepository = {
	@:id(1) var id:String;
	@:id(2) var provider:String;
	@:id(3) var root:String;
	@:id(4) var kind:String;
	@:optional @:id(5) var parentId:Null<String>;
	@:id(6) var trusted:Bool;
	@:id(7) var staging:Bool;
	@:id(8) var partialStaging:Bool;
	@:id(9) var amend:Bool;
	@:id(10) var branches:Bool;
	@:id(11) var remotes:Bool;
	@:id(12) var stash:Bool;
}

@:wire typedef WorkspaceScmHead = {
	@:optional @:id(1) var branch:Null<String>;
	@:optional @:id(2) var detachedCommit:Null<String>;
	@:id(3) var unborn:Bool;
	@:optional @:id(4) var upstream:Null<String>;
	@:id(5) var ahead:Int;
	@:id(6) var behind:Int;
	@:id(7) var upstreamGone:Bool;
	@:id(8) var operation:String;
}

@:wire typedef WorkspaceScmResource = {
	@:id(1) var path:String;
	@:optional @:id(2) var originalPath:Null<String>;
	@:id(3) var pathBytes:Bytes;
	@:optional @:id(4) var originalPathBytes:Null<Bytes>;
	@:id(5) var changeKind:String;
	@:optional @:id(6) var conflictKind:Null<String>;
	@:id(7) var submoduleStatus:String;
	@:optional @:id(8) var renameScore:Null<Int>;
}

@:wire typedef WorkspaceScmGroup = {
	@:id(1) var id:String;
	@:id(2) var resources:Array<WorkspaceScmResource>;
}

@:wire typedef WorkspaceScmSnapshot = {
	@:id(1) var revision:Int64;
	@:id(2) var head:WorkspaceScmHead;
	@:id(3) var groups:Array<WorkspaceScmGroup>;
	@:id(4) var truncated:Bool;
}

@:wire typedef WorkspaceScmError = {
	@:id(1) var code:String;
	@:id(2) var message:String;
	@:id(3) var retryable:Bool;
}

typedef ScmRepositoriesRequest = WorkspaceRootRequest;

@:wire typedef ScmRepositoriesResult = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var repositories:Array<WorkspaceScmRepository>;
}

typedef ScmSnapshotRequest = WorkspaceRepositoryRequest;

@:wire typedef ScmSnapshotResult = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	@:optional @:id(3) var snapshot:Null<WorkspaceScmSnapshot>;
	@:optional @:id(4) var error:Null<WorkspaceScmError>;
}

typedef ScmWatchRequest = WorkspaceRootWatchRequest;

@:wire typedef ScmWatchEvent = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var epoch:String;
	@:id(4) var sequence:Int;
	@:id(5) var repository:String;
	@:id(6) var revision:Int64;
}

@:wire typedef ScmWatchResult = {
	@:id(1) var workspace:String;
	@:id(2) var root:String;
	@:id(3) var epoch:String;
	@:id(4) var cursor:Int;
	@:id(5) var reset:Bool;
	@:id(6) var events:Array<ScmWatchEvent>;
}

typedef ScmUnwatchRequest = WorkspaceRootRequest;

typedef ScmUnwatchResult = WorkspaceUnwatchResult;

@:wire typedef ScmOriginalRequest = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	/** head, index, commit, or conflict */
	@:id(3) var reference:String;
	@:optional @:id(4) var referenceValue:Null<String>;
	/** Raw path bytes preserve names that are not valid UTF-8. */
	@:id(5) var path:Bytes;
}

@:wire typedef ScmOriginalResult = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	@:optional @:id(3) var bytes:Null<Bytes>;
	@:optional @:id(4) var binary:Null<Bool>;
}

@:wire typedef ScmApplyRequest = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	@:id(3) var operationId:String;
	@:id(4) var expectedRevision:Int64;
	/** stage, stage_all, stage_paths, unstage, unstage_all, unstage_paths, discard, restore_discard, resolve_conflict, commit, stage_patch, unstage_patch, revert_patch, checkout, create_branch, fetch, pull, push */
	@:id(5) var kind:String;
	@:optional @:id(6) var path:Null<String>;
	@:optional @:id(7) var message:Null<String>;
	@:optional @:id(8) var amend:Null<Bool>;
	@:optional @:id(9) var patch:Null<Bytes>;
	@:optional @:id(10) var reference:Null<String>;
	@:optional @:id(11) var remote:Null<String>;
	@:optional @:id(12) var name:Null<String>;
	@:optional @:id(13) var paths:Null<Array<String>>;
	@:optional @:id(14) var recoveryToken:Null<String>;
	@:optional @:id(15) var choice:Null<String>;
}

@:wire typedef ScmApplyResult = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	@:id(3) var operationId:String;
	@:optional @:id(4) var message:Null<String>;
	@:optional @:id(5) var snapshot:Null<WorkspaceScmSnapshot>;
	@:optional @:id(6) var recoveryToken:Null<String>;
}

typedef ScmTrustRequest = WorkspaceRepositoryRequest;

@:wire typedef ScmTrustResult = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	@:id(3) var trusted:Bool;
}

@:wire typedef WorkspaceScmBranch = {
	@:id(1) var reference:String;
	@:id(2) var name:String;
	@:id(3) var remote:Bool;
	@:id(4) var current:Bool;
}

typedef ScmBranchesRequest = WorkspaceRepositoryRequest;

@:wire typedef ScmBranchesResult = {
	@:id(1) var workspace:String;
	@:id(2) var repository:String;
	@:optional @:id(3) var branches:Null<Array<WorkspaceScmBranch>>;
	@:optional @:id(4) var error:Null<WorkspaceScmError>;
}

/** Permanent workspace SCM method IDs. Reserve 160–168; do not reuse them. */
class WorkspaceScmProtocol {
	public static inline final ORIGINAL_MAX_BYTES = 131072;
	public static inline final READ = "workspace.scm.read";
	public static inline final WRITE = "workspace.scm.write";
	public static inline final REMOTE = "workspace.scm.remote";
	public static inline final CHANGED = 167;

	public static final REPOSITORIES = new RpcMethod<ScmRepositoriesRequest, ScmRepositoriesResult>(160,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmRepositoriesRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmRepositoriesResult return MessagePack.decode(bytes));
	public static final SNAPSHOT = new RpcMethod<ScmSnapshotRequest, ScmSnapshotResult>(161,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmSnapshotRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmSnapshotResult return MessagePack.decode(bytes));
	public static final WATCH = new RpcMethod<ScmWatchRequest, ScmWatchResult>(162,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmWatchRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmWatchResult return MessagePack.decode(bytes));
	public static final UNWATCH = new RpcMethod<ScmUnwatchRequest, ScmUnwatchResult>(163,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmUnwatchRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmUnwatchResult return MessagePack.decode(bytes));
	public static final ORIGINAL = new RpcMethod<ScmOriginalRequest, ScmOriginalResult>(164,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmOriginalRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmOriginalResult return MessagePack.decode(bytes));
	public static final APPLY = new RpcMethod<ScmApplyRequest, ScmApplyResult>(165,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmApplyRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmApplyResult return MessagePack.decode(bytes));
	public static final TRUST = new RpcMethod<ScmTrustRequest, ScmTrustResult>(166,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmTrustRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmTrustResult return MessagePack.decode(bytes));
	public static final BRANCHES = new RpcMethod<ScmBranchesRequest, ScmBranchesResult>(168,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmBranchesRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ScmBranchesResult return MessagePack.decode(bytes));

	public static function encodeEvent(value:ScmWatchEvent):Bytes return MessagePack.encode(value);
	public static function decodeEvent(bytes:Bytes):ScmWatchEvent return MessagePack.decode(bytes);
}
