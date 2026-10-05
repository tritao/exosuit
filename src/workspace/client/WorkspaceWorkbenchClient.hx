package workspace.client;

import workspace.client.WorkspaceTerminalCatalogClient;
import workspace.client.WorkspaceAgentClient;

/** Workbench composes independent terminal and conversation services. */
interface WorkspaceWorkbenchClient extends WorkspaceTerminalCatalogClient {
	public function agentService():WorkspaceAgentClient;
}
