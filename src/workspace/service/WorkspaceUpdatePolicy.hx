package workspace.service;

/** Session activity is rechecked by the daemon, never inferred from an editor snapshot. */
class WorkspaceUpdatePolicy {
 public var pending(default, null):Bool = false;
 public var force(default, null):Bool = false;
 public function new() {}
 public function request(mode:String):Bool {
  if (mode == "cancel") { pending = false; force = false; return true; }
  if (mode != "idle" && mode != "now") return false;
  pending = true; force = mode == "now";
  return true;
 }
 public function shouldRestart(terminals:Int, agents:Int):Bool {
  if (terminals < 0 || agents < 0) throw "Invalid update activity counts";
  return pending && (force || terminals == 0 && agents == 0);
 }
}
