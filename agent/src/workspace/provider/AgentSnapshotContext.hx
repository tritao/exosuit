package workspace.provider;

import haxeon.rpc.RpcContext;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceAgentProtocol.AgentView;

/** Adapts provider completion without changing its side effects or cancellation. */
class AgentSnapshotContext extends RpcContext<AgentView> {
 final source:RpcContext<Dynamic>;
 final onValue:AgentView->Bool;
 var finished:Bool = false;
 public function new(source:RpcContext<Dynamic>,onValue:AgentView->Bool) {
  super(null,null,null);this.source=source;this.onValue=onValue;
 }
 override public function deadline():Float return source.deadline();
 override public function isCancelled():Bool return source.isCancelled();
 override public function respond(value:AgentView):Bool {
  if (finished || source.isCancelled()) return false;
  finished=true; return onValue(value);
 }
 override public function fail(error:RpcError):Bool {
  if (finished || source.isCancelled()) return false;
  finished=true; return source.fail(error);
 }
}
