package workspace.service;

import workspace.service.WorkspaceAgentProtocol;

interface WorkspaceAgentPersistence {
	public function loadAgents():Array<AgentRecord>;
	public function saveAgent(record:AgentRecord):Void;
	public function removeAgent(id:String):Void;
}
