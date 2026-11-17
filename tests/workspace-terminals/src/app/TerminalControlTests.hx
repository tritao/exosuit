package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;

/** Who holds a terminal's control lease when attachments are replaced, leaked or dropped. */
class TerminalControlTests {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }

  public static function run(root:String):Void {
    var clock = function() return Sys.time() * 1000;
    var manager = TestTerminals.manager("w", "instance", root, 65536);
    var grants = [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL];
    var peers:Array<{client:RpcConnection, server:RpcConnection}> = [];
    var pump = function() {
      for (_ in 0...3) {
        for (p in peers) p.client.poll();
        for (p in peers) p.server.poll();
        manager.poll();
      }
    };
    var connect = function(scope:String) {
      var pair = MemoryTransport.pair();
      var peer = {client: new RpcConnection(pair.client, clock), server: new RpcConnection(pair.server, clock)};
      manager.bind(peer.server, grants, scope);
      peers.push(peer);
      return peer.client;
    };
    var open = function(client:RpcConnection, create:Bool, key:Null<String>):TerminalInfo {
      var result:Null<TerminalInfo> = null;
      client.call(WorkspaceTerminalProtocol.OPEN, {workspace: "w", instance: "instance", id: "lease", create: create,
        columns: 80, rows: 24, clientKey: key}, 2000, function(info) result = info, function(e) throw e.code);
      var deadline = clock() + 5000;
      while (result == null) {
        require(clock() < deadline, "OPEN timed out");
        pump();
      }
      return result;
    };
    var claim = function(client:RpcConnection, takeover:Bool, key:Null<String>):TerminalInfo {
      var result:Null<TerminalInfo> = null;
      client.call(WorkspaceTerminalProtocol.SET_CONTROL, {workspace: "w", instance: "instance", id: "lease", claim: true,
        takeover: takeover, clientKey: key}, 2000, function(info) result = info, function(e) throw e.code);
      var deadline = clock() + 5000;
      while (result == null) {
        require(clock() < deadline, "SET_CONTROL timed out");
        pump();
      }
      return result;
    };
    var write = function(client:RpcConnection):String {
      var refusal = "";
      var done = false;
      client.call(WorkspaceTerminalProtocol.INPUT, {workspace: "w", instance: "instance", id: "lease", sequence: 1,
        data: haxe.io.Bytes.ofString("\n")}, 2000, function(_) done = true, function(e) { refusal = e.code; done = true; });
      var deadline = clock() + 5000;
      while (!done) {
        require(clock() < deadline, "INPUT timed out");
        pump();
      }
      return refusal;
    };

    // The first attachment creates the terminal and holds control.
    var first = connect("local");
    require(open(first, true, "pid1").controller == true, "Creating attachment did not receive control");

    // The editor rebuilt its panes: a new connection from the same process replaces the old, still open, attachment.
    var replacement = connect("local");
    var info = open(replacement, false, "pid1");
    require(info.controller == true, "A pane replacing a leaked attachment of the same client stayed read-only");
    require(write(first) == "terminal_controlled", "The replaced attachment kept input access");
    require(write(replacement) == "", "The replacement attachment could not send input");

    // The same applies to an auto-claim on SET_CONTROL without takeover.
    var third = connect("local");
    require(open(third, false, null).controller == false, "An attachment without a client key took control");
    require(claim(third, false, null).controller == false, "A plain claim without a key took control from a live client");
    require(claim(third, false, "pid1").controller == true, "A claim from the controller's own client was refused");

    // Two windows of one editor process share a key, so they move control between each other without Take control
    // (the same client). A window started by NewWindow gets its own key, so it does not.
    // A different live client keeps its lease: no silent takeover, however it asks.
    var phone = connect("remote");
    require(open(phone, false, "pid1").controller == false, "A remote client with a colliding key took control");
    require(claim(phone, false, "pid1").controller == false, "A remote client with a colliding key claimed control");
    var otherWindow = connect("local");
    info = open(otherWindow, false, "pid2");
    require(info.controller == false && info.controlled == true, "Another live client was silently taken over");
    require(write(third) == "", "The other client's attach disturbed the controller");
    // An explicit Take control still works.
    require(claim(otherWindow, true, "pid2").controller == true, "Explicit Take control was refused");
    require(write(third) == "terminal_controlled", "Take control left the old controller writable");

    // A controller that went away releases the lease; the next attachment becomes controller.
    otherWindow.close();
    pump();
    var later = connect("remote");
    require(open(later, false, "pid3").controller == true, "A disconnected controller kept the lease");

    for (p in peers) { p.client.close(); p.server.close(); }
    var closer = connect("local");
    var terminated = false;
    closer.call(WorkspaceTerminalProtocol.TERMINATE, {workspace: "w", instance: "instance", id: "lease"}, 2000,
      function(_) terminated = true, function(e) throw e.code);
    var deadline = clock() + 5000;
    while (!terminated || manager.activeCount() != 0) {
      require(clock() < deadline, "Terminal did not end");
      pump();
      Sys.sleep(0.005);
    }
    manager.dispose();
    Sys.println("PASS: control lease: same-client replacement, no silent takeover of other clients, explicit takeover, release on disconnect");
  }
}
