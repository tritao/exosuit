package workspace.client;

import workspace.service.WorkspaceAgentProtocol;

interface WorkspaceAgentClient {
	public function canReadAgents():Bool;
 public function canControlAgents():Bool;
 /** Session mutation state; session creation has its own operation below. */
 public function agentBusy():Bool;
 public function agentCreation():Null<workspace.client.WorkspaceAgentCreation.AgentCreationStatus>;
 public function agentRevision():Int;
	public function agents():Null<AgentCatalog>;
	public function agentError():Null<String>;
	public function refreshAgents():Void;
	public function createAgent(group:String, thread:Null<String>, ?created:AgentRecord->Void,
		?defaults:AgentSessionDefaults):Void;
	public function deleteAgent(id:String, ?deleted:Void->Void):Void;
	public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String, ?accepted:Void->Void, ?expectedNativeName:String, ?imageIds:Array<String>):Void;
	public function uploadAgentImage(id:String, bytes:haxe.io.Bytes, done:(Null<String>, Null<String>)->Void):Void;
	public function removeAgentImage(id:String, upload:String):Void;
	public function loadAgentContent(id:String, turn:String, item:String, token:String, done:(Null<String>, Bool, Null<String>)->Void):Void;
	public function loadAgentImage(id:String, turn:String, item:String, imageId:String, done:(Null<haxe.io.Bytes>, Null<String>)->Void):Void;
	public function discoverAgents(group:String, cursor:Null<String>):Void;
	public function discoveredAgents():Null<AgentDiscovery>;
	public function agentView(id:String):Null<AgentView>;
	public function agentHistory(id:String):AgentHistoryState;
	public function loadOlderAgentItems(id:String, done:Null<String>->Void):Void;
	public function resetAgentHistory(id:String):Void;
	public function listModels(cursor:Null<String>, done:Null<AgentModelsPage>->Null<String>->Void):Void;
}
