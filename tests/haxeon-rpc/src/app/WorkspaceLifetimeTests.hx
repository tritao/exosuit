package app;

import workspace.service.WorkspaceLifetime;

class WorkspaceLifetimeTests {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }

  public static function run():Void {
    var lifetime = new WorkspaceLifetime();
    require(!lifetime.shouldStop(100, 0, 0), "Startup grace missing");
    require(!lifetime.shouldStop(60099, 0, 0), "Stopped before idle deadline");
    require(!lifetime.shouldStop(60100, 1, 0), "Connected client lost at deadline");
    require(!lifetime.shouldStop(80000, 0, 0), "Disconnect must start a fresh grace period");
    require(!lifetime.shouldStop(140000, 0, 1), "Owned session lost without clients");
    require(!lifetime.shouldStop(200000, 0, 0), "Session completion must start fresh grace");
    require(lifetime.shouldStop(260000, 0, 0), "Idle service failed to stop");
    var available = new WorkspaceLifetime(0);
    require(
      !available.shouldStop(0, 0, 0) && !available.shouldStop(1000000000, 0, 0),
      "Always-available service stopped"
    );
    Sys.println("PASS: workspace idle grace, connected clients, owned sessions and always-available policy");
  }
}
