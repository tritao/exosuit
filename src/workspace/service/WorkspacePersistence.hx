package workspace.service;

import workspace.service.WorkspaceProtocol;

typedef WorkspaceStoredOperation = {var request:RenameGroup; var outcome:RenameResult;}
typedef WorkspaceStoredState = {var snapshot:WorkspaceSnapshot; var operations:Array<WorkspaceStoredOperation>; var events:Array<WorkspaceEvent>;}

/** The service publishes only after commit returns. Failure fences further access
 * until the owner reopens storage and resolves any ambiguous commit. */
interface WorkspacePersistence {
	public function load():WorkspaceStoredState;
	public function commit(request:RenameGroup, outcome:RenameResult, event:WorkspaceEvent):Void;
}
