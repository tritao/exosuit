package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

/** Durable intent written before changing a native tool's title. */
@:wire typedef AgentRenameIntent = {
 @:id(1) var expected:Null<String>;
 @:id(2) var target:String;
 @:id(3) var session:String;
}

@:wire typedef AgentNameMetadata = {
 /** Legacy/explicit local labels are workbench; confirmed native renames are native. */
 @:id(1) var source:String;
 @:id(2) var nativeName:Null<String>;
 @:optional @:id(3) var pending:Null<AgentRenameIntent>;
}

@:wire typedef AgentRecord = {
	@:id(1) var id:String;
	@:id(2) var name:String;
	@:id(3) var group:String;
	@:id(4) var cwd:String;
	@:id(5) var thread:String;
	@:id(6) var state:String;
	@:id(7) var turn:Null<String>;
	@:id(8) var workspaceRoot:String;
	/** Latest Exosuit permission choice, applied to this and subsequent turns. */
	@:optional @:id(9) var sandboxPolicy:Null<String>;
	@:optional @:id(10) var approvalPolicy:Null<String>;
	@:optional @:id(11) var permissionProfile:Null<String>;
	/** Composer overrides retained with the resource across daemon restarts. */
	@:optional @:id(12) var preferredModel:Null<String>;
	@:optional @:id(13) var preferredEffort:Null<String>;
	/** Absent on legacy records means Codex. Claude thread is its CLI session UUID. */
	@:optional @:id(14) var provider:Null<String>;
	@:optional @:id(15) var permissionMode:Null<String>;
	@:optional @:id(16) var replay:Null<Array<AgentActivityItem>>;
	/** A native conversation must exist after delivery was attempted, independently of bounded replay. */
	@:optional @:id(17) var nativeSessionRequired:Null<Bool>;
	@:optional @:id(18) var inputSerial:Null<Int>;
	@:optional @:id(19) var inputMessages:Null<Array<AgentInputMessage>>;
	@:optional @:id(20) var queuePaused:Null<Bool>;
	@:optional @:id(21) var nameMetadata:Null<AgentNameMetadata>;
}

@:wire typedef AgentQuery = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:optional @:id(3) var after:Null<String>;
}

@:wire typedef AgentCatalog = {
	@:id(1) var instance:String;
	@:id(2) var root:String;
	@:id(3) var records:Array<AgentRecord>;
	@:id(4) var status:String;
	@:optional @:id(5) var next:Null<String>;
	/** Missing on legacy daemons, which route every create request to Codex. */
	@:optional @:id(6) var providers:Null<Array<String>>;
	/** Explicit feature negotiation; absent on services that cannot move agent leaves. */
	@:optional @:id(7) var canMove:Null<Bool>;
	@:optional @:id(8) var canRename:Null<Bool>;
	/** Providers implementing inspect-name/rename-native; rename retains its local-only meaning. */
	@:optional @:id(9) var nativeRenameProviders:Null<Array<String>>;
}

@:wire typedef AgentCreate = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var id:String;
	@:id(4) var group:String;
	@:id(5) var name:String;
	// Null creates a new thread; non-null explicitly attaches an existing thread.
	@:id(6) var thread:Null<String>;
	/** Defaults for new threads only; ignored when attaching an existing thread. */
	@:optional @:id(7) var defaultModel:Null<String>;
	@:optional @:id(8) var defaultEffort:Null<String>;
	@:optional @:id(9) var permissionProfile:Null<String>;
	@:optional @:id(10) var provider:Null<String>;
}

@:wire typedef AgentModel = {
	@:id(1) var model:String;
	@:id(2) var name:String;
	@:optional @:id(3) var defaultEffort:Null<String>;
	@:optional @:id(4) var supportedEfforts:Null<Array<String>>;
}

/** Discovered on the workspace host; invocation is the native text sent to the agent. */
@:wire typedef AgentCommand = {
	@:id(1) var name:String;
	@:id(2) var description:String;
	@:id(3) var kind:String;
	@:id(4) var invocation:String;
	@:optional @:id(5) var scope:Null<String>;
}

/** Durable user submission and its bounded idempotency receipt. */
@:wire typedef AgentInputMessage = {
	@:id(1) var id:String;
	@:id(2) var kind:String;
	@:id(3) var text:String;
	@:id(4) var fingerprint:String;
	@:id(5) var state:String;
	@:optional @:id(6) var error:Null<String>;
}

/** Native queue contents can be expanded or transformed by Pi extensions. */
@:wire typedef AgentNativeInput = {
	@:id(1) var kind:String;
	@:id(2) var text:String;
	@:id(3) var truncated:Bool;
}

@:wire typedef AgentAction = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var id:String;
	/** Move uses text as destination group and request as expected source group. Rename uses text as new name and request as expected old name. Neither changes native cwd. */
	@:id(4) var action:String;
	@:id(5) var text:String;
	@:id(6) var request:Null<String>;
	@:optional @:id(7) var model:Null<String>;
	@:optional @:id(8) var effort:Null<String>;
	/** Older activity page; absent starts with the newest items. */
	@:optional @:id(9) var after:Null<String>;
	/** Expected native custom title, captured by inspect-name before opening an editor. */
	@:optional @:id(10) var expectedNativeName:Null<String>;
	/** Opaque host-staged image IDs; accepted only by providers advertising support. */
	@:optional @:id(11) var imageIds:Null<Array<String>>;
}

@:wire typedef AgentImageUpload = {
  @:id(1) var workspace:String;
  @:id(2) var instance:String;
  @:id(3) var session:String;
  @:id(4) var operation:String;
  @:id(5) var upload:Null<String>;
  @:id(6) var size:Int;
  @:id(7) var offset:Int;
  @:id(8) var bytes:Null<Bytes>;
}

@:wire typedef AgentImageUploadResult = {
  @:id(1) var upload:String;
  @:id(2) var offset:Int;
  @:id(3) var complete:Bool;
}

@:wire typedef AgentRequest = {
	@:id(1) var id:String;
	@:id(2) var method:String;
	@:id(3) var detail:String;
	@:id(4) var reviewable:Bool;
	/** Native extension dialog type. Absent preserves existing provider request semantics. */
	@:optional @:id(5) var inputKind:Null<String>;
	@:optional @:id(6) var options:Null<Array<String>>;
}

@:wire typedef AgentView = {
	@:id(1) var record:AgentRecord;
	@:id(2) var activity:String;
	@:id(3) var requests:Array<AgentRequest>;
	@:id(4) var error:Null<String>;
	@:optional @:id(5) var items:Null<Array<AgentActivityItem>>;
	@:optional @:id(6) var itemsOmitted:Null<Bool>;
	@:optional @:id(7) var models:Null<Array<AgentModel>>;
	@:optional @:id(8) var modelsNext:Null<String>;
	@:optional @:id(9) var currentModel:Null<String>;
	@:optional @:id(10) var currentEffort:Null<String>;
	/** Transport/session readiness, separate from the Codex turn state. */
	@:optional @:id(11) var connectionState:Null<String>;
	/** Stable recovery category for actionable UI; raw diagnostics remain in error. */
	@:optional @:id(12) var recoveryReason:Null<String>;
	@:optional @:id(13) var itemsNext:Null<String>;
	@:optional @:id(14) var commands:Null<Array<AgentCommand>>;
	@:optional @:id(15) var commandsError:Null<String>;
	@:optional @:id(16) var commandsLoading:Null<Bool>;
	@:optional @:id(17) var inputToken:Null<String>;
	@:optional @:id(18) var pendingInputs:Null<Array<AgentInputMessage>>;
	@:optional @:id(19) var queuePaused:Null<Bool>;
	@:optional @:id(20) var nativePending:Null<Array<AgentNativeInput>>;
	@:optional @:id(21) var inputBusy:Null<Bool>;
	@:optional @:id(22) var supportsSteering:Null<Bool>;
	@:optional @:id(23) var supportsQueue:Null<Bool>;
	@:optional @:id(24) var supportsImageUpload:Null<Bool>;
}

/** Bounded presentation data; provider protocol and policy stay on the host. */
@:wire typedef AgentFileChange = {
	@:id(1) var path:String;
	@:id(2) var kind:String;
	/** Slice of the containing item's detail. Avoids duplicating bounded patch data on the wire. */
	@:id(3) var offset:Int;
	@:id(4) var length:Int;
	@:id(5) var truncated:Bool;
}

@:wire typedef AgentActivityItem = {
	@:id(1) var id:String;
	@:id(2) var turn:String;
	@:id(3) var kind:String;
	@:id(4) var title:String;
	@:id(5) var text:String;
	@:id(6) var detail:String;
	@:id(7) var state:String;
	@:id(8) var truncated:Bool;
	/** Authoritative file association, absent on legacy services and unstructured tool output. */
	@:optional @:id(9) var files:Null<Array<AgentFileChange>>;
}

@:wire typedef AgentDiscoveryQuery = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var group:String;
	@:id(4) var cursor:Null<String>;
	@:optional @:id(5) var provider:Null<String>;
}

@:wire typedef AgentThread = {
	@:id(1) var id:String;
	@:id(2) var title:String;
	@:id(3) var cwd:String;
}

@:wire typedef AgentDiscovery = {
	@:id(1) var threads:Array<AgentThread>;
	@:id(2) var next:Null<String>;
}

@:wire typedef AgentModelsQuery = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var cursor:Null<String>;
	@:optional @:id(4) var provider:Null<String>;
}

@:wire typedef AgentModelsPage = {
	@:id(1) var models:Array<AgentModel>;
	@:id(2) var next:Null<String>;
}

class WorkspaceAgentProtocol {
	public static inline final READ = "workspace.agents.read";
	public static inline final CONTROL = "workspace.agents.control";
	public static final MODELS = new RpcMethod<AgentModelsQuery, AgentModelsPage>(124, function(v:AgentModelsQuery) return MessagePack.encode(v),
		function(b:Bytes):AgentModelsQuery return MessagePack.decode(b), function(v:AgentModelsPage) return MessagePack.encode(v),
		function(b:Bytes):AgentModelsPage return MessagePack.decode(b));
	public static final DISCOVER = new RpcMethod<AgentDiscoveryQuery, AgentDiscovery>(123, function(v:AgentDiscoveryQuery) return MessagePack.encode(v),
		function(b:Bytes):AgentDiscoveryQuery return MessagePack.decode(b), function(v:AgentDiscovery) return MessagePack.encode(v),
		function(b:Bytes):AgentDiscovery return MessagePack.decode(b));
	public static final LIST = new RpcMethod<AgentQuery, AgentCatalog>(120, function(v:AgentQuery) return MessagePack.encode(v),
		function(b:Bytes):AgentQuery return MessagePack.decode(b), function(v:AgentCatalog) return MessagePack.encode(v),
		function(b:Bytes):AgentCatalog return MessagePack.decode(b));
	public static final CREATE = new RpcMethod<AgentCreate, AgentRecord>(121, function(v:AgentCreate) return MessagePack.encode(v),
		function(b:Bytes):AgentCreate return MessagePack.decode(b), function(v:AgentRecord) return MessagePack.encode(v),
		function(b:Bytes):AgentRecord return MessagePack.decode(b));
	public static final ACTION = new RpcMethod<AgentAction, AgentView>(122, function(v:AgentAction) return MessagePack.encode(v),
		function(b:Bytes):AgentAction return MessagePack.decode(b), function(v:AgentView) return MessagePack.encode(v),
		function(b:Bytes):AgentView return MessagePack.decode(b));
	public static final IMAGE_UPLOAD = new RpcMethod<AgentImageUpload, AgentImageUploadResult>(125,
		function(v:AgentImageUpload) return MessagePack.encode(v), function(b:Bytes):AgentImageUpload return MessagePack.decode(b),
		function(v:AgentImageUploadResult) return MessagePack.encode(v), function(b:Bytes):AgentImageUploadResult return MessagePack.decode(b));
}
