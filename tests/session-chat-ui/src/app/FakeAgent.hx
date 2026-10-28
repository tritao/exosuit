package app;

import workspace.client.WorkspaceAgentClient;
import workspace.client.AgentSessionDefaults;
import workspace.service.WorkspaceAgentProtocol;

class FakeAgent implements WorkspaceAgentClient {
	public var record:AgentRecord = {id:"session", name:"Session", group:"group", cwd:"/repo", thread:"thread", state:"idle", turn:null, workspaceRoot:"/repo", provider:"codex"};
	public var view:AgentView;
	public var actions:Array<String> = [];
	public var chosenModel:Null<String>;
	public var control:Bool = true;
	public var acceptActions:Bool = true;
	public var deferAcceptance:Bool = false;
	public var pendingAcceptance:Null<Void->Void>;
	public var uploadEnabled:Bool = false;
	public var lastImageIds:Null<Array<String>>;
	public var removedImages:Array<String> = [];
	public var history:workspace.client.AgentHistoryState = {loading:false,error:null,hasOlder:false,detached:false,resetRequired:false};
	public var historyDone:Null<Null<String>->Void>;
	public var historyResets:Int = 0;
 public var messageContent:Null<String>;
 public var contentRequests:Int = 0;
 public var deferContent:Bool = false;
 public var pendingContent:Null<(Null<String>, Bool, Null<String>)->Void>;
 public var imageRequests=0;
 public var imageRequestIdentity:Null<String>;
 public var pendingImage:Null<(Null<haxe.io.Bytes>,Null<String>)->Void>;
	public function new() {
		view = {record:record, activity:"", requests:[], error:null, connectionState:"connected", items:[
			{id:"user", turn:"turn", kind:"userMessage", title:"", text:"Please inspect this project.", detail:"", state:"completed", truncated:false},
			{id:"assistant", turn:"turn", kind:"agentMessage", title:"", text:"I found a [useful result](src/Main.hx:12).", detail:"", state:"completed", truncated:false}
		], models:[{model:"test-model", name:"Test model", supportedEfforts:["low", "high"]}]};
	}
	public function canReadAgents():Bool return true;
	public function canControlAgents():Bool return control;
	public function agentBusy():Bool return false;
	public function agentCreation():Null<workspace.client.WorkspaceAgentCreation.AgentCreationStatus> return null;
	public function agentRevision():Int return 0;
	public function agents():Null<AgentCatalog> return {instance:"fixture", root:"/repo", records:[record], status:"ready"};
	public function agentError():Null<String> return null;
	public function refreshAgents():Void {}
	public function createAgent(group:String, thread:Null<String>, ?created:AgentRecord->Void, ?defaults:AgentSessionDefaults):Void {}
	public function deleteAgent(id:String, ?deleted:Void->Void):Void {}
	public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String, ?accepted:Void->Void, ?expectedNativeName:String, ?imageIds:Array<String>):Void {
		actions.push(action + ":" + text + ":" + request);
		if (action == "model-settings") chosenModel = model;
		if (action == "prompt") lastImageIds = imageIds;
		if (accepted != null && acceptActions) {
			if (deferAcceptance) pendingAcceptance = accepted; else accepted();
		}
	}
	public function uploadAgentImage(id:String, bytes:haxe.io.Bytes, done:(Null<String>, Null<String>)->Void):Void {
		if (uploadEnabled) done("opaque-image", null); else done(null, "Unavailable");
	}
	public function removeAgentImage(id:String, upload:String):Void removedImages.push(upload);
	public function loadAgentImage(id:String,turn:String,item:String,imageId:String,done:(Null<haxe.io.Bytes>,Null<String>)->Void):Void {
  imageRequests++;imageRequestIdentity=id+":"+turn+":"+item+":"+imageId;pendingImage=done;
 }
	public function loadAgentContent(id:String, turn:String, item:String, token:String, done:(Null<String>, Bool, Null<String>)->Void):Void {
  contentRequests++; if (deferContent) pendingContent=done;
  else done(messageContent,false,messageContent == null ? "Message content unavailable" : null);
 }
	public function discoverAgents(group:String, cursor:Null<String>):Void {}
	public function discoveredAgents():Null<AgentDiscovery> return null;
	public function agentView(id:String):Null<AgentView> return id == record.id ? view : null;
	public function agentHistory(id:String):workspace.client.AgentHistoryState return history;
	public function loadOlderAgentItems(id:String, done:Null<String>->Void):Void { history.loading = true; historyDone = done; }
	public function resetAgentHistory(id:String):Void { historyResets++; history.detached = false; history.resetRequired = false; }
	public function listModels(cursor:Null<String>, done:Null<AgentModelsPage>->Null<String>->Void):Void done(null, null);
}

