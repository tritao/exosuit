package app;

import suit.MachineCatalog.MachineWorkspace;
import workspace.client.WorkspaceWorkbenchClient;

/**
	The Workbench's row actions without an app: a fixed machine view whose open workspace's rows are `client`'s lists,
	and the workspaces opened or gone to, in order. Only the open workspace has a link.
**/
class FakeWorkbenchActions extends ui.WorkbenchActions {
 final machineView:ui.WorkbenchMachineView;
 final client:WorkspaceWorkbenchClient;
 public final opened:Array<String>=[];
 public function new(machineView:ui.WorkbenchMachineView,client:WorkspaceWorkbenchClient) {super(null);this.machineView=machineView;this.client=client;}
 override public function view():ui.WorkbenchMachineView {
  var open=machineView.openWorkspace;
  if(open!=null) {
   var agents=client.agentService().agents();
   machineView.rows=[open=>{terminals:client.terminalCatalog(),agents:agents,snapshot:null,
    revision:client.terminalCatalogRevision()*7919+client.agentService().agentRevision()}];
  }
  return machineView;
 }
 override public function busy():Bool return false;
 override public function manages():Bool return true;
 override public function workspaceById(id:Null<String>):Null<MachineWorkspace> {
  var state=machineView.machine;
  if(state!=null) for(entry in state.workspaces) if(entry.id==id) return entry;
  return null;
 }
 override public function linked(id:String):Null<WorkspaceWorkbenchClient> return id==machineView.openWorkspace ? client : null;
 override public function open(entry:MachineWorkspace):Void opened.push(entry.id);
 override public function goTo(entry:MachineWorkspace,action:Void->Void,agents:Bool=false):Void opened.push(entry.id);
 override public function inWorkspace(entry:MachineWorkspace,action:WorkspaceWorkbenchClient->Void,agents:Bool=false):Void {
  if(entry.id==machineView.openWorkspace) action(client);
 }
 override public function create():Void {}
}
