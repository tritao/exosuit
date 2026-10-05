package app;

import haxe.io.Bytes;
import haxeon.rpc.*;
import haxeon.wire.MessagePack;
import haxeon.wire.MessagePackFrame;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceAgentProtocol;

/** Frozen independent MessagePack vectors: both bytes and semantic decode are checked. */
class RpcCompatibilityTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	public static function bytes(hex:String):Bytes {
		var result = Bytes.alloc(Std.int(hex.length / 2));
		for (index in 0...result.length) {
			var value = Std.parseInt("0x" + hex.substr(index * 2, 2));
			result.set(index, value);
		}
		return result;
	}

	static function vector(value:RpcEnvelope, hex:String):Void {
		var expected = bytes(hex);
		require(RpcProtocol.encode(value, 4096).compare(expected) == 0, "Envelope vector changed: " + hex);
		require(RpcProtocol.encode(RpcProtocol.decode(expected, 4096), 4096).compare(expected) == 0, "Envelope vector decode changed");
	}

	static function rejects(action:Void->Void, label:String):Void {
		var failed = false;
		try
			action()
		catch (_:Dynamic)
			failed = true;
		require(failed, label);
	}

	public static function run():Void {

  var agentCreate:AgentCreate={workspace:"w",instance:"i",id:"a",group:"g",name:"Codex",thread:null};
  require(WorkspaceAgentProtocol.CREATE.encodeRequest(agentCreate).compare(bytes("8601a17702a16903a16104a16705a5436f64657806c0"))==0,"Agent create vector changed");
  var agentAction:AgentAction={workspace:"w",instance:"i",id:"a",action:"prompt",text:"hi",request:null};
  require(WorkspaceAgentProtocol.ACTION.encodeRequest(agentAction).compare(bytes("8601a17702a16903a16104a670726f6d707405a2686906c0"))==0,"Agent prompt vector changed");
  var agentWideRoot="";for(_ in 0...1024) agentWideRoot+="😀";
  var agentWideName="";for(_ in 0...256) agentWideName+="😀";
  var agents:Array<AgentRecord> = [];
  for(i in 0...6) agents.push({id:"a"+i,name:agentWideName,group:"g",cwd:agentWideRoot,thread:"t",state:"needs-attention",turn:"turn",workspaceRoot:agentWideRoot});
  var page:AgentCatalog={instance:"i",root:agentWideRoot,records:agents,status:"connected",next:"a5"};
  var agentBytes=WorkspaceAgentProtocol.LIST.encodeResponse(page);
  require(RpcProtocol.encode(Response(1,agentBytes),262144).length<=262144,"Agent page exceeded message bound");
  require(WorkspaceAgentProtocol.LIST.decodeResponse(agentBytes).records.length==6,"Agent page decode lost records");
  var activity="";for(_ in 0...16384) activity+="😀";
  var detail="";for(_ in 0...2048) detail+="😀";
  var requests:Array<AgentRequest> = [];
  for(i in 0...16) requests.push({id:"request"+i,method:"item/commandExecution/requestApproval",detail:detail,reviewable:true});
  var agentView:AgentView={record:agents[0],activity:activity,requests:requests,error:detail};
  require(RpcProtocol.encode(Response(1,WorkspaceAgentProtocol.ACTION.encodeResponse(agentView)),262144).length<=262144,"Agent activity view exceeded message bound");
		var error:RpcError = {code: "unknown_method", message: "unknown_method", ambiguous: false};
		var query = WorkspaceProtocol.QUERY.encodeRequest({workspace: "w"});
		vector(Hello(1, 1, "test/1", [WorkspaceProtocol.READ]), "8101940101a6746573742f3191ae776f726b73706163652e72656164");
		vector(Welcome(1, 1, "agent/1", [WorkspaceProtocol.READ]), "8102940101a76167656e742f3191ae776f726b73706163652e72656164");
		vector(Refused(error), "8103918301ae756e6b6e6f776e5f6d6574686f6402ae756e6b6e6f776e5f6d6574686f6403c2");
		vector(Request(1, 100, 1000, query), "8104940164cd03e8c4048101a177");
		vector(Response(1, Bytes.alloc(0)), "81059201c400");
		vector(Failed(1, error), "810692018301ae756e6b6e6f776e5f6d6574686f6402ae756e6b6e6f776e5f6d6574686f6403c2");
		vector(Cancel(1), "81079101");
		vector(Notification(200, Bytes.alloc(0)), "810892ccc8c400");
		require(query.compare(bytes("8101a177")) == 0, "Workspace query vector changed");
		require(WorkspaceProtocol.QUERY.decodeRequest(bytes("8101a177")).workspace == "w", "Workspace query decode changed");
		var identity:WorkspaceIdentity = {workspace: "w", root: "/w", instance: "i"};
		var identityBytes = bytes("8301a17702a22f7703a169");
		require(WorkspaceProtocol.IDENTITY.encodeRequest({workspace: "w"}).compare(query) == 0, "Identity request vector changed");
		require(WorkspaceProtocol.IDENTITY.encodeResponse(identity).compare(identityBytes) == 0, "Identity response vector changed");
		var identified = WorkspaceProtocol.IDENTITY.decodeResponse(identityBytes);
		require(identified.workspace == "w" && identified.root == "/w" && identified.instance == "i", "Identity decode changed");
		var target:TerminalTarget = {workspace:"w",instance:"i",id:"t"};
		require(WorkspaceTerminalProtocol.TERMINATE.encodeRequest(target).compare(bytes("8301a17702a16903a174"))==0,"Terminal target vector changed");
		var terminalRead:TerminalRead = {workspace:"w",instance:"i",id:"t",offset:haxe.Int64.make(1,2)};
		var terminalReadBytes=bytes("8401a17702a16903a17404d30000000100000002");
		require(WorkspaceTerminalProtocol.OUTPUT.encodeRequest(terminalRead).compare(terminalReadBytes)==0,"Terminal byte-offset vector changed");
		require(WorkspaceTerminalProtocol.OUTPUT.decodeRequest(terminalReadBytes).offset==haxe.Int64.make(1,2),"64-bit terminal offset truncated");
		var terminalInput:TerminalInput={workspace:"w",instance:"i",id:"t",sequence:1,data:bytes("0001")};
		require(WorkspaceTerminalProtocol.INPUT.encodeRequest(terminalInput).compare(bytes("8501a17702a16903a174040105c4020001"))==0,"Terminal binary input vector changed");
        var catalogQuery:TerminalCatalogQuery={workspace:"w",instance:"i",after:null};
        require(WorkspaceTerminalProtocol.LIST.encodeRequest(catalogQuery).compare(bytes("8301a17702a16903c0"))==0,"Terminal catalog query vector changed");
        var renameTerminal:TerminalRename={workspace:"w",instance:"i",id:"t",name:"N",group:"w",expectedRevision:haxe.Int64.make(1,2)};
        var renameTerminalBytes=bytes("8601a17702a16903a17404a14e05a17706d30000000100000002");
        require(WorkspaceTerminalProtocol.RENAME.encodeRequest(renameTerminal).compare(renameTerminalBytes)==0,"Terminal metadata vector changed");
        require(WorkspaceTerminalProtocol.RENAME.decodeRequest(renameTerminalBytes).expectedRevision==haxe.Int64.make(1,2),"Terminal revision truncated");

		var snapshot:WorkspaceSnapshot = {
			epoch: "e",
			cursor: 0,
			groups: [
				{
					id: "g",
					name: "Work",
					cwd: null,
					revision: 1
				}
			]
		};
		require(WorkspaceProtocol.QUERY.encodeResponse(snapshot).compare(bytes("8301a165020003918601a16702a4576f726b03c0040105c006c0")) == 0,
			"Snapshot vector changed");
		var decoded = WorkspaceProtocol.QUERY.decodeResponse(bytes("8301a165020003918401a16702a4576f726b03c00401"));
		require(decoded.epoch == "e" && decoded.groups.length == 1 && decoded.groups[0].cwd == null, "Snapshot decode changed");
		var rename:RenameGroup = {
			workspace: "w",
			epoch: "e",
			operation: "op",
			group: "g",
			expectedRevision: 1,
			name: "New"
		};
		require(WorkspaceProtocol.RENAME.encodeRequest(rename).compare(bytes("8a01a17702a16503a26f7004a167050106a34e657707c008c009c00ac0")) == 0, "Rename vector changed");
		require(WorkspaceProtocol.RENAME.decodeRequest(bytes("8601a17702a16503a26f7004a167050106a34e6577")).expectedRevision == 1, "Rename decode changed");
		// Conservative UTF-8 upper bounds: every bounded character can occupy four bytes.
		var wideName="",wideRoot="";
		for (_ in 0...126) wideName += "😀";
		for (_ in 0...1024) wideRoot += "😀";
		var wideGroups:Array<WorkspaceGroup> = [for (i in 0...32) {
			id:wideName+StringTools.lpad(Std.string(i),"0",2),name:wideName+"00",cwd:wideRoot,revision:0x7fffffff,parent:wideName+"00",order:1000000
		}];
		var wideRecords:Array<TerminalRecord> = [for (i in 0...WorkspaceTerminalProtocol.CATALOG_PAGE_LIMIT) {
			id:wideName+"00",name:wideName+"00",group:wideName+"00",cwd:wideRoot,instance:wideName+"00",
			state:"running",exitCode:0x7fffffff,available:true,revision:haxe.Int64.make(0x7fffffff,0xffffffff),workspaceRoot:wideRoot
		}];
		var wideCatalog:TerminalCatalog={instance:wideName+"00",groups:wideGroups,terminals:wideRecords,next:wideName+"00",workspaceRoot:wideRoot};
		require(WorkspaceTerminalProtocol.LIST.encodeResponse(wideCatalog).length<=262144,"Maximum Unicode catalog page exceeds RPC budget");

		var createGroup:RenameGroup={workspace:"w",epoch:"e",operation:"op",group:"g",expectedRevision:0,name:"N",action:"create",parent:"work",cwd:null,order:2};
		require(WorkspaceProtocol.GROUP.encodeRequest(createGroup).compare(bytes("8a01a17702a16503a26f7004a167050006a14e07a663726561746508a4776f726b09c00a02"))==0,"Group tree mutation vector changed");
		var groupedOpen:TerminalOpen={workspace:"w",instance:"i",id:"t",create:true,columns:80,rows:24,group:"g",directory:"/w"};
		require(WorkspaceTerminalProtocol.OPEN.encodeRequest(groupedOpen).compare(bytes("8801a17702a16903a17404c30550061807a16708a22f77"))==0,"Grouped terminal open vector changed");

		require(MessagePackFrame.pack(query).compare(bytes("484d504b0100000000048101a177")) == 0, "Frame vector changed");
		// Unknown map fields are skipped even when they contain nested values; scalar/collection wire defaults remain domain-validated.
		require(WorkspaceProtocol.QUERY.decodeRequest(bytes("8201a17763928101a17892c301")).workspace == "w", "Unknown field was not skipped");
		require(WorkspaceProtocol.QUERY.decodeRequest(bytes("80")).workspace == "", "Missing string default changed");
		rejects(function() WorkspaceProtocol.QUERY.decodeRequest(bytes("8101c0")), "Null workspace accepted");
		rejects(function() WorkspaceProtocol.QUERY.decodeRequest(bytes("810101")), "Wrong workspace type accepted");
		rejects(function() WorkspaceProtocol.QUERY.decodeRequest(bytes("8101a17700")), "Trailing data accepted");
		require(WorkspaceProtocol.QUERY.decodeResponse(bytes("8201a1650200")).groups.length == 0, "Missing array default changed");
		rejects(function() WorkspaceProtocol.decodeEvent(bytes("8201a1650201")), "Missing required group object accepted");
		rejects(function() RpcProtocol.decode(bytes("816390"), 4096), "Unknown envelope variant accepted");
		rejects(function() RpcProtocol.decode(bytes("81079201c0"), 4096), "Changed constructor arity accepted");
		rejects(function() MessagePackFrame.unpack(bytes("484d504b0200000000048101a177")), "Unsupported frame version accepted");
		rejects(function() MessagePackFrame.unpack(bytes("484d504b0101000000048101a177")), "Reserved flags accepted");
		var legacy:WorkspaceGroup = MessagePack.decode(bytes("8301a16702a4576f726b0401"));
		require(legacy.cwd == null && legacy.revision == 1, "Missing nullable cwd default changed");
		require(WorkspaceProtocol.RENAME.decodeRequest(bytes("8606a34e6577050104a16703a26f7002a16501a177")).operation == "op",
			"Input map order became significant");
		versionRefusal();
		methodErrors();
		missingIdentity();
	}

	static function methodErrors():Void {
		var service = new workspace.service.WorkspaceService("w", "e", [
			{
				id: "g",
				name: "Work",
				cwd: null,
				revision: 1
			}
		]);
		var pair = MemoryTransport.pair(4096, 16);
		var client = new RpcConnection(pair.client, function() return 0.0, 1024, 8, 4096);
		var server = new RpcConnection(pair.server, function() return 0.0, 1024, 8, 4096);
		service.bind(server, [WorkspaceProtocol.READ]);
		var unknown = new RpcMethod<WorkspaceQuery, WorkspaceSnapshot>(999, WorkspaceProtocol.QUERY.encodeRequest, WorkspaceProtocol.QUERY.decodeRequest,
			WorkspaceProtocol.QUERY.encodeResponse, WorkspaceProtocol.QUERY.decodeResponse);
		var malformed = new RpcMethod<WorkspaceQuery, WorkspaceSnapshot>(100, function(_) return bytes("80"), WorkspaceProtocol.QUERY.decodeRequest,
			WorkspaceProtocol.QUERY.encodeResponse, WorkspaceProtocol.QUERY.decodeResponse);
		var errors:Array<String> = [];
		var failure = function(error:RpcError) {
			require(!error.ambiguous, "Validation error became ambiguous");
			errors.push(error.code);
		};
		client.call(unknown, {workspace: "w"}, 1000, function(_) {
			throw "Unknown method succeeded";
		}, failure);
		client.call(malformed, {workspace: "w"}, 1000, function(_) {
			throw "Malformed method succeeded";
		}, failure);
		client.call(WorkspaceProtocol.QUERY, {workspace: "absent"}, 1000, function(_) {
			throw "Unknown workspace succeeded";
		}, failure);
		client.call(WorkspaceProtocol.RENAME, {
			workspace: "w",
			epoch: "e",
			operation: "op",
			group: "g",
			expectedRevision: 1,
			name: "New"
		}, 1000, function(_) {
			throw "Denied rename succeeded";
		}, failure);
		server.poll();
		client.poll();
		require(errors.length == 4 && errors[0] == "unknown_method" && errors[1] == "invalid_request" && errors[2] == "unknown_workspace"
			&& errors[3] == "unauthorized",
			"Method error contract changed");
		var success = false;
		client.call(WorkspaceProtocol.QUERY, {workspace: "w"}, 1000, function(value) {
			success = value.cursor == 0 && value.groups[0].revision == 1;
		}, failure);
		server.poll();
		client.poll();
		require(success && client.isOpen() && server.isOpen(), "Method errors poisoned the connection or mutated state");
		client.close();
		server.close();
	}

	static function versionRefusal():Void {
		for (codec in [false, true]) {
			var pair = MemoryTransport.pair(4096, 16);
			var offered = [WorkspaceProtocol.READ];
			var a = RpcHandshake.client(pair.client, function() return 0.0,
				new RpcPeerOptions("new/1", offered, [], 100, 1024, 4, 4096, codec ? 1 : 2, codec ? 2 : 1), offered);
			var b = RpcHandshake.server(pair.server, function() return 0.0, new RpcPeerOptions("old/1", offered, [], 100, 1024, 4, 4096));
			for (_ in 0...8) {
				a.poll();
				b.poll();
			}
			require(a.isFinished()
				&& a.connection == null
				&& a.failure != null
				&& a.failure.code == (codec ? "unsupported_codec" : "unsupported_protocol"),
				"Version refusal changed");
			a.close();
			b.close();
		}
	}

	static function missingIdentity():Void {
		var service = new workspace.service.WorkspaceService("w", "e", [
			{
				id: "g",
				name: "Work",
				cwd: null,
				revision: 1
			}
		]);
		var pair = MemoryTransport.pair(4096, 16);
		var client = new RpcConnection(pair.client, function() return 0.0, 1024, 8, 4096);
		var server = new RpcConnection(pair.server, function() return 0.0, 1024, 8, 4096);
		service.bind(server, [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE]);
		var failures = 0;
		var failure = function(error:RpcError) {
			require(error.code == "invalid_request" && !error.ambiguous, "Incomplete identity was not rejected before dispatch");
			failures++;
		};
		for (hex in ["8501a17703a26f7004a167050106a34e6577", "8501a17702a16503a26f7004a16706a34e6577"]) {
			var incomplete = new RpcMethod<RenameGroup, RenameResult>(102, function(_) return bytes(hex), WorkspaceProtocol.RENAME.decodeRequest,
				WorkspaceProtocol.RENAME.encodeResponse, WorkspaceProtocol.RENAME.decodeResponse);
			client.call(incomplete, {
				workspace: "w",
				epoch: "e",
				operation: "op",
				group: "g",
				expectedRevision: 1,
				name: "New"
			}, 1000, function(_) {
				throw "Incomplete rename succeeded";
			}, failure);
		}
		var operation = new RpcMethod<OperationQuery, OperationResult>(103, function(_) return bytes("8201a17703a26f70"),
			WorkspaceProtocol.OPERATION.decodeRequest, WorkspaceProtocol.OPERATION.encodeResponse, WorkspaceProtocol.OPERATION.decodeResponse);
		client.call(operation, {workspace: "w", epoch: "e", operation: "op"}, 1000, function(_) {
			throw "Incomplete operation lookup succeeded";
		}, failure);
		server.poll();
		client.poll();
		require(failures == 3 && service.snapshot().cursor == 0 && service.snapshot().groups[0].revision == 1,
			"Incomplete identities changed state or did not retire calls");
		client.close();
		server.close();
	}
}
