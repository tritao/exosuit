package app;

import haxeon.platform.Runtime;
import nativekit.ffi.NativeKit;
import testing.DirectService;
import workspace.client.WorkspaceLink;
import workspace.client.WorkspaceServiceTarget;

/**
	WorkspaceLink against a real workspace service, started the way exohost starts it (testing.DirectService):

	  link ROOT LAUNCHER      two links to one workspace share its one service and both verify it; a link whose
	                          opener names the wrong service fails closed; closing a link leaves the other connected
	  restart ROOT LAUNCHER   the service is killed: a link the window needs (`revive`) connects to the next service,
	                          a link kept only for rows ends
	  hold ROOT LAUNCHER      a linked client keeps a service with a short idle time running past it
**/
class AttachmentTestMain {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }

  static var runtime:Runtime;
  static function clock():Float return NativeKit.nk_time_seconds() * 1000;

  static function step(links:Array<WorkspaceLink>):Void {
    runtime.events.wait(0.01);
    for (_ in 0...128) if (!runtime.events.poll()) break;
    for (link in links) link.poll();
  }

  static function until(links:Array<WorkspaceLink>, done:Void->Bool, milliseconds:Float, what:String, ?detail:Void->String):Void {
    var deadline = clock() + milliseconds;
    while (!done()) {
      require(clock() < deadline, "timed out: " + what + (detail == null ? "" : " (" + detail() + ")"));
      step(links);
    }
  }

  static function main():Void {
    var args = Sys.args(), mode = args[0];
    var root = args[1], launcher = args[2];
    runtime = Runtime.start();
    var direct = new DirectService(launcher);
    var target = direct.forRoot(root);
    switch mode {
      case "link": link(direct, target);
      case "restart": restart(direct, target);
      case "hold": hold(direct, target);
      default: throw "unknown mode " + mode;
    }
    runtime.dispose();
  }

  static function link(direct:DirectService, target:WorkspaceServiceTarget):Void {
    var a = new WorkspaceLink(runtime.events, clock, direct.open, target);
    var b = new WorkspaceLink(runtime.events, clock, direct.open, target);
    until([a, b], function() {
      require(a.error == null && b.error == null, "a link failed: " + a.error + " / " + b.error);
      return a.ready && b.ready && a.catalogMirror() != null;
    }, 90000, "two links ready");
    require(a.instance == b.instance && a.instance.length == 32, "two links did not share one verified service");
    require(a.servedWorkspace() == target.workspace && a.statusLabel() == "Workspace connected", "the link does not name its workspace");
    require(a.workspace == target.workspace && a.servesRoot(target.folders[0]), "the link does not serve its folder");
    // An opener that names the right pipe for another service (another root): IDENTITY does not match; nothing is accepted.
    var instance = a.instance, endpoint:Null<String> = null;
    direct.open(target.workspace, function(service, _) endpoint = service == null ? null : service.endpoint);
    require(endpoint != null, "the running service was not found again");
    var named:String = endpoint;
    var forged = new WorkspaceLink(runtime.events, clock, function(_, done) done({endpoint: named, generation: instance, root: "/elsewhere"}, null), target);
    until([a, b, forged], function() {
      require(!forged.ready, "a link accepted a service that is not the one named");
      return forged.failure() != null;
    }, 15000, "the forged link to fail");
    forged.dispose();
    a.dispose();
    for (_ in 0...20) step([b]);
    require(b.ready && b.instance == instance, "closing one link disturbed the other");
    b.dispose();
    Sys.println("PASS: links share one verified service, refuse one that does not match, and close independently");
  }

  static function restart(direct:DirectService, target:WorkspaceServiceTarget):Void {
    var needed = new WorkspaceLink(runtime.events, clock, direct.open, target);
    var rows = new WorkspaceLink(runtime.events, clock, direct.open, target);
    rows.revive = function() return false;
    until([needed, rows], function() return needed.ready && rows.ready, 90000, "links ready");
    var before = needed.instance;
    var log = sys.io.File.getContent(haxe.io.Path.join([DirectService.stateOf(target.workspace), "service.log"]));
    var pid = Std.parseInt(log.substr(log.lastIndexOf(", pid ") + 6));
    require(pid != null && pid > 0, "no service pid in its log");
    if (Sys.systemName() == "Windows") Sys.command("taskkill", ["/F", "/PID", Std.string(pid)]);
    else Sys.command("kill", ["-9", Std.string(pid)]);
    until([needed, rows], function() return rows.ended && needed.ready && needed.instance != before, 90000,
      "the needed link on a new service, the rows link ended", function() return "rows: ended " + rows.ended + " ready " + rows.ready
        + " error " + rows.error + "; needed: ready " + needed.ready + " same " + (needed.instance == before) + " error " + needed.error
        + " status " + needed.statusLabel());
    needed.dispose();
    rows.dispose();
    Sys.println("PASS: a needed link connects to the next service, a link kept for rows ends with its service");
  }

  static function hold(direct:DirectService, target:WorkspaceServiceTarget):Void {
    var a = new WorkspaceLink(runtime.events, clock, direct.open, target);
    var b = new WorkspaceLink(runtime.events, clock, direct.open, target);
    until([a, b], function() return a.ready && b.ready, 90000, "links ready");
    var holdUntil = clock() + 12000;
    var closed = false;
    while (clock() < holdUntil) {
      if (!closed && clock() >= holdUntil - 6000) { a.dispose(); closed = true; }
      step(closed ? [b] : [a, b]);
      require(b.ready && b.error == null, "a linked client lost its service during the idle time");
    }
    b.dispose();
    Sys.println("PASS: a linked client keeps its service running past its idle time");
  }
}
