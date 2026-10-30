package workspace.service;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

/**
	Names a workspace: the machine suit runs on and the workspace's id in that machine's catalog
	(docs/architecture/0006-workspaces-without-folders.md). A folder is an attribute of a workspace, not its name.
**/
@:wire typedef WorkspaceRef = {
	@:id(1) var machine:String;
	@:id(2) var workspace:String;
}

/**
	Reads one service's catalog. Without `resume`, or with a token the service no longer knows, the reply resets
	the client's copy; with a known token it holds only what changed since. `watch` also asks for CATALOG_CHANGED
	notifications on this connection, like terminal open's `watch`.
**/
@:wire typedef CatalogQuery = {
	@:id(1) var ref:WorkspaceRef;
	@:id(2) var resume:Null<String>;
	@:id(3) var watch:Bool;
}

/** An agent session in the catalog: no activity, only what a list shows. */
@:wire typedef CatalogSession = {
	@:id(1) var id:String;
	@:id(2) var name:String;
	@:id(3) var group:String;
	/** The working directory resolved when the session was created. */
	@:id(4) var directory:String;
	/** Null means Codex, as on AgentRecord. */
	@:id(5) var provider:Null<String>;
	@:id(6) var state:String;
	/** Requests waiting for an answer, plus one when the session's state needs attention. */
	@:id(7) var attention:Int;
}

@:wire typedef CatalogTerminal = {
	@:id(1) var id:String;
	@:id(2) var name:String;
	@:id(3) var group:String;
	/** The working directory resolved when the terminal was created. */
	@:id(4) var directory:String;
	@:id(5) var state:String;
	@:id(6) var exitCode:Int;
	@:id(7) var available:Bool;
	@:id(8) var revision:Int64;
	@:id(9) var agentProvider:Null<String>;
	@:id(10) var attention:Int;
}

/**
	One page of a service's catalog. `token` resumes after this page; `more` asks the client to call again with it
	at once. `reset` is set only on the first page of a reset, which replaces everything the client holds; the pages
	that follow it through `more` belong to the same reset. Every page fits PAGE_BYTES.
**/
@:wire typedef WorkspaceCatalog = {
	@:id(1) var ref:WorkspaceRef;
	@:id(2) var instance:String;
	@:id(3) var token:String;
	@:id(4) var reset:Bool;
	@:id(5) var more:Bool;
	@:id(6) var name:String;
	/**
		Attached folders, possibly none. Sent only in a reset, split across its pages when they do not fit one: the
		client joins them. A change to the folders, name or scratch folder makes the next read a reset.
	**/
	@:id(7) var folders:Array<String>;
	/** The scratch folder once suit made one. */
	@:id(8) var scratch:Null<String>;
	@:id(9) var status:String;
	/** Sessions and terminals in the whole workspace that need attention, not only those on this page. */
	@:id(10) var attention:Int;
	@:id(11) var groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup>;
	@:id(12) var sessions:Array<CatalogSession>;
	@:id(13) var terminals:Array<CatalogTerminal>;
	@:id(14) var removedGroups:Array<String>;
	@:id(15) var removedSessions:Array<String>;
	@:id(16) var removedTerminals:Array<String>;
	/** True when this connection now receives CATALOG_CHANGED for the workspace. */
	@:id(17) var watching:Bool;
}

/** A hint that the catalog changed after `token`; CATALOG reads the change. Coalesced per service tick. */
@:wire typedef CatalogChange = {
	@:id(1) var ref:WorkspaceRef;
	@:id(2) var token:String;
}

/**
	Permanent ids for the catalog watch (M19 Phase 0), behind the negotiated CAPABILITY. Proposed, pending the
	mobile-app review (docs/roadmap/RPC-VECTORS.md). Never reuse ids.
**/
class WorkspaceCatalogProtocol {
	public static inline final CAPABILITY = "workspace.catalog";
	/** Groups, sessions, terminals, removals and folders together, on one page. */
	public static inline final PAGE_LIMIT = 24;
	/**
		The most an encoded page may take. Pages reach devices through the relay, whose messages are at most
		RelaySocketLink.MAX_MESSAGE_BYTES (about 64 KiB); this leaves room for the RPC envelope. A page always holds
		at least one item while any remain: the workspace's own fields and one item of the largest kind fit.
	**/
	public static inline final PAGE_BYTES = 49152;
	public static inline final TOKEN_LIMIT = 128;
	public static inline final ID_LIMIT = 256;
	public static inline final CHANGED = 172;
	public static final CATALOG = new RpcMethod<CatalogQuery, WorkspaceCatalog>(170, function(v:CatalogQuery) return MessagePack.encode(v),
		function(b:Bytes):CatalogQuery return MessagePack.decode(b), function(v:WorkspaceCatalog) return MessagePack.encode(v),
		function(b:Bytes):WorkspaceCatalog return MessagePack.decode(b));
	/** Stops this connection's notifications for the workspace; disconnecting also stops them. */
	public static final UNWATCH = new RpcMethod<WorkspaceRef, WorkspaceRef>(171, encodeRef, decodeRef, encodeRef, decodeRef);

	public static function encodeRef(value:WorkspaceRef):Bytes
		return MessagePack.encode(value);

	public static function decodeRef(bytes:Bytes):WorkspaceRef
		return MessagePack.decode(bytes);

	public static function encodeChange(value:CatalogChange):Bytes
		return MessagePack.encode(value);

	public static function decodeChange(bytes:Bytes):CatalogChange
		return MessagePack.decode(bytes);

	/** Both ids are present and bounded; anything else is an `invalid_request`. */
	public static function validRef(value:Null<WorkspaceRef>):Bool
		return value != null && value.machine.length > 0 && value.machine.length <= ID_LIMIT && value.workspace.length > 0
			&& value.workspace.length <= ID_LIMIT;

	/** A valid ref, and a resume token that is absent or bounded; anything else is an `invalid_request`. */
	public static function validQuery(value:CatalogQuery):Bool {
		var resume = value.resume;
		return validRef(value.ref) && (resume == null || resume.length > 0 && resume.length <= TOKEN_LIMIT);
	}

	/** Whether `page` fits PAGE_BYTES; a service adds items to a page while it does. */
	public static function fits(page:WorkspaceCatalog):Bool
		return CATALOG.encodeResponse(page).length <= PAGE_BYTES;

	public static function sameRef(a:WorkspaceRef, b:WorkspaceRef):Bool
		return a.machine == b.machine && a.workspace == b.workspace;

	/** An agent state that asks for the user, counted in a session's attention. */
	public static inline final NEEDS_ATTENTION = "needs-attention";

	/** A session's attention: its pending requests, plus one when its state needs attention. */
	public static function sessionAttention(record:AgentRecord, requests:Int):Int
		return requests + (record.state == NEEDS_ATTENTION ? 1 : 0);

	/** A session's catalog entry; its directory is the record's resolved cwd. */
	public static function session(record:AgentRecord, attention:Int):CatalogSession
		return {
			id: record.id,
			name: record.name,
			group: record.group,
			directory: record.cwd,
			provider: record.provider,
			state: record.state,
			attention: attention
		};

	/** A terminal's catalog entry; its directory is the record's resolved cwd. */
	public static function terminal(record:TerminalRecord, attention:Int):CatalogTerminal
		return {
			id: record.id,
			name: record.name,
			group: record.group,
			directory: record.cwd,
			state: record.state,
			exitCode: record.exitCode,
			available: record.available,
			revision: record.revision,
			agentProvider: record.agentProvider,
			attention: attention
		};
}
