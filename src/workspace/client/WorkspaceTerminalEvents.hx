package workspace.client;

import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceTerminalProtocol.TerminalTarget;

/** One notification handler per connection, shared by all attached terminal panes. */
class WorkspaceTerminalEvents {
  public final connection:RpcConnection;
  /** Local confirmed creations invalidate discovery independently of output notifications. */
  public var catalogRevision(default, null):Int = 0;
  public function invalidateCatalog():Void catalogRevision++;
  final listeners:Map<String, Array<TerminalTarget->Void>> = [];
  public function new(connection:RpcConnection) {
    this.connection = connection;
    connection.onNotification(WorkspaceTerminalProtocol.CHANGED, WorkspaceTerminalProtocol.decodeChange, function(event) {
      var targets = listeners.get(event.id);
      if (targets != null) for (listener in targets.copy()) listener(event);
    });
  }
  public function hasListeners(id:String):Bool return listeners.exists(id);

  public function listen(id:String, listener:TerminalTarget->Void):Void->Bool {
    var targets = listeners.get(id);
    if (targets == null) { targets = []; listeners.set(id, targets); }
    targets.push(listener);
    return function() {
      targets.remove(listener);
      if (targets.length == 0) listeners.remove(id);
      return targets.length == 0;
    };
  }
}
