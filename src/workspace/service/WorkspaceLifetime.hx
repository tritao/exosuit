package workspace.service;

/** Daemon lifetime follows authenticated clients and owned sessions, never UI windows. */
class WorkspaceLifetime {
  final idleMilliseconds:Int;
  var idleSince:Null<Float>;

  /** Zero explicitly opts into always-available mode. */
  public function new(idleMilliseconds:Int = 60000) {
    if (idleMilliseconds < 0) throw "Invalid workspace idle timeout";
    this.idleMilliseconds = idleMilliseconds;
  }

  public function shouldStop(now:Float, clients:Int, activeSessions:Int):Bool {
    if (clients < 0 || activeSessions < 0) throw "Invalid workspace activity count";
    if (idleMilliseconds == 0 || clients > 0 || activeSessions > 0) {
      idleSince = null;
      return false;
    }
    if (idleSince == null) idleSince = now;
    return now - idleSince >= idleMilliseconds;
  }
}
