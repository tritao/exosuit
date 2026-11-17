package app;
import workspace.client.WorkspaceLink;
import workspace.service.WorkspaceTerminalProtocol;
import haxeon.platform.Runtime;
import nativekit.ffi.NativeKit;

/** Real native client aggregation and metadata actions across multiple RPC pages. */
class TerminalCatalogClientTests {
  static function require(v:Bool, message:String):Void {
    if (!v) throw message;
  }
  public static function run(client:WorkspaceLink, runtime:Runtime):Void {
    var deadline = Sys.time() + 20;
    var step = function() {
      require(Sys.time() < deadline, "Native terminal catalog timed out");
      runtime.events.wait(0.005);
      for (_ in 0...128) if (!runtime.events.poll()) break;
      client.poll();
      require(client.error == null, "Workspace failed: " + client.error);
      require(client.terminalCatalogError() == null, "Catalog failed: " + client.terminalCatalogError());
    };
    while (!client.ready) step();
    var connection = client.rpc();
    if (connection == null) throw "Native connection missing";
    for (index in 0...9) {
      var done = false;
      connection.call(WorkspaceTerminalProtocol.OPEN, {
        workspace: "workspace",
        instance: client.instance,
        id: "probe-" + index,
        create: true,
        columns: 80,
        rows: 24
      }, 2000, function(_) done = true, function(e) {
        throw e.code;
      }
      );
      while (!done) step();
      done = false;
      connection.call(WorkspaceTerminalProtocol.TERMINATE, {
        workspace: "workspace",
        instance: client.instance,
        id: "probe-" + index
      }, 2000, function(_) done = true, function(e) {
        throw e.code;
      }
      );
      while (!done) step();
    }
    client.refreshTerminals(true);
    // The list may already hold a read from before the last probes (the catalog watch reads on every change): wait for
    // the read that follows them, which the deadline in `step` bounds.
    var seen = function() {
      var read = client.terminalCatalog();
      return read == null ? 0 : read.terminals.length;
    };
    while (seen() < 9) step();
    var catalog = client.terminalCatalog();
    if (catalog == null) throw "Catalog missing";
    require(catalog.terminals.length == 9, "Native client did not aggregate all pages");
    // A new catalog has no groups: terminals opened without one sit in the workspace itself.
    require(catalog.groups.length == 0, "A new workspace catalog has groups");
    for (terminal in catalog.terminals) require(terminal.group == workspace.service.WorkspaceProtocol.ROOT_GROUP, "A terminal is not in the workspace root");
    var first = catalog.terminals[0];
    while (first.state != "exited") {
      client.refreshTerminals(false);
      step();
      catalog = client.terminalCatalog();
      if (catalog != null) first = catalog.terminals[0];
    }
    client.renameTerminal(first, "Discovery probe", workspace.service.WorkspaceProtocol.ROOT_GROUP);
    while (client.terminalCatalogBusy()) step();
    while (true) {
      step();
      catalog = client.terminalCatalog();
      if (catalog != null && catalog.terminals[0].name == "Discovery probe") {
        first = catalog.terminals[0];
        break;
      }
    }
    client.forgetTerminal(first);
    while (client.terminalCatalogBusy()) step();
    while (true) {
      step();
      catalog = client.terminalCatalog();
      if (catalog != null && catalog.terminals.length == 8) break;
    }
    Sys.println("PASS: native terminal catalog aggregates pages, renames metadata and forgets an exited resource");
  }
}
