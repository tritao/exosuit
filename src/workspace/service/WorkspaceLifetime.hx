package workspace.service;

/** Daemon lifetime follows authenticated clients and owned sessions, never UI windows. */
class WorkspaceLifetime {
  /** The longest a service waits with no client while idle chat processes run (see `shouldStop`). */
  public static inline final LIVE_IDLE_CAP_MILLISECONDS:Int = 600000;
  final idleMilliseconds:Int;
  var idleSince:Null<Float>;

  public function new(idleMilliseconds:Int) {
    if (idleMilliseconds <= 0) throw "Invalid workspace idle timeout";
    this.idleMilliseconds = idleMilliseconds;
  }

  /**
   * `liveSessions` counts chat processes that are running but idle (a stop ends them). They do not keep the service up
   * for good, since every one of them resumes with its whole conversation when a message arrives, but they lengthen the
   * wait to ten times the idle limit, at most ten minutes: closing the editor for a rebuild or switching to another
   * workspace and back keeps the processes as they are.
   */
  /**
   * `activeSessions` counts what must not be cut off: busy agent turns and remote connections. Terminals are not among
   * them: their hosts keep them while no service runs.
   */
  public function shouldStop(now:Float, clients:Int, activeSessions:Int, liveSessions:Int = 0):Bool {
    if (clients < 0 || activeSessions < 0 || liveSessions < 0) throw "Invalid workspace activity count";
    if (clients > 0 || activeSessions > 0) {
      idleSince = null;
      return false;
    }
    if (idleSince == null) idleSince = now;
    var limit = liveSessions > 0 ? Math.max(idleMilliseconds, Math.min(idleMilliseconds * 10.0, LIVE_IDLE_CAP_MILLISECONDS))
      : idleMilliseconds;
    return now - idleSince >= limit;
  }
}
