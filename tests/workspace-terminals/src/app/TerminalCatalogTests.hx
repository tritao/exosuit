package app;

import haxeon.rpc.*;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;
import sqlitekit.Database;

private class FaultyTerminalStore implements workspace.service.WorkspaceTerminalPersistence {
  public final records:Array<TerminalRecord> = [];
  final failAt:Int;
  var writes:Int = 0;
  public function new(failAt:Int) this.failAt = failAt;
  public function loadTerminals():Array < TerminalRecord > return records;
  public function saveTerminal(r:TerminalRecord):Void {
    writes++;
    if (writes == failAt) throw "Injected metadata failure";
    if (records.length == 0) records.push(r);
    else records[0] = r;
  }
  public function removeTerminal(id:String):Void records.resize(0);
}
class TerminalCatalogTests {
  static function require(v:Bool, message:String):Void {
    if (!v) throw message;
  }
  static function failures(root:String):Void {
    for (failAt in[1, 2]) {
      var clock = function() return Sys.time() * 1000;
      var store = new FaultyTerminalStore(failAt);
      var manager = new WorkspaceTerminalManager("w", "fault", root, 65536, store);
      var pair = MemoryTransport.pair(), client = new RpcConnection(pair.client, clock), server = new RpcConnection(
        pair.server,
        clock
      );
      manager.bind(
        server,
        [
          WorkspaceTerminalProtocol.READ,
          WorkspaceTerminalProtocol.CONTROL,
          WorkspaceTerminalProtocol.CATALOG
        ]
      );
      var failed = false;
      client.call(WorkspaceTerminalProtocol.OPEN, {
        workspace: "w",
        instance: "fault",
        id: "fault-shell",
        create: true,
        columns: 80,
        rows: 24
      }, 1000, function(_) {
        throw "Uncommitted terminal published";
      }, function(e) {
        require(e.code == "storage_failed" && e.ambiguous, "Storage failure lost ambiguity");
        failed = true;
      }
      );
      client.poll();
      server.poll();
      client.poll();
      require(failed && manager.activeCount() == 0, "Metadata failure leaked active runtime");
      var error = "";
      client.call(WorkspaceTerminalProtocol.LIST, {workspace: "w", instance: "fault", after: null}, 1000, function(_) {
        throw "Failed metadata remained trusted";
      }, function(e) error = e.code);
      client.poll();
      server.poll();
      client.poll();
      require(error == "storage_unavailable", "Catalog not fenced after storage failure");
      client.close();
      server.close();
      manager.dispose();
    }
  }
  public static function run(root:String):Void {
    failures(root);
    var clock = function() return Sys.time() * 1000;
    var groups:Array<WorkspaceGroup> = [{id: "work", name: "Work", cwd: root, revision: 1}, {
      id: "other",
      name: "Other",
      cwd: root,
      revision: 1
    }
    ];
    var seed:WorkspaceSnapshot = {epoch: "catalog", cursor: 0, groups: groups};
    var path = root + "/terminal-catalog.sqlite";
    var store = new WorkspaceSqliteStore(path, "w", seed);
    // Exercise migration of an existing v1 catalog without modifying its group data.
    store.close();
    var admin = Database.open(path);
    admin.exec("DROP TABLE workspace_terminals");
    admin.exec("PRAGMA user_version=1");
    admin.close();
    store = new WorkspaceSqliteStore(path, "w", seed);
    var service = new WorkspaceService("w", "ignored", groups, 32, 256, 16, store);
    var manager = new WorkspaceTerminalManager(
      "w",
      "first",
      root,
      65536,
      store,
      function() return service.snapshot().groups
    );
    var pair = MemoryTransport.pair(), client = new RpcConnection(pair.client, clock), server = new RpcConnection(
      pair.server,
      clock
    );
    manager.bind(
      server,
      [
        WorkspaceTerminalProtocol.READ,
        WorkspaceTerminalProtocol.CONTROL,
        WorkspaceTerminalProtocol.CATALOG
      ]
    );
    var step = function() {
      client.poll();
      server.poll();
      manager.poll();
      client.poll();
    };
    var done = false;
    var open:TerminalOpen = {
      workspace: "w",
      instance: "first",
      id: "catalog-shell",
      create: true,
      columns: 80,
      rows: 24
    };
    client.call(WorkspaceTerminalProtocol.OPEN, open, 1000, function(_) done = true, function(e) {
      throw e.code;
    }
    );
    step();
    step();
    require(done, "Catalog shell did not open");
    var record = manager.snapshot().terminals[0];
    require(record.available && record.state == "running" && record.group == "work", "Runtime metadata missing");
    done = false;
    var rename:TerminalRename = {
      workspace: "w",
      instance: "first",
      id: record.id,
      name: "Build shell",
      group: "other",
      expectedRevision: record.revision
    };
    client.call(WorkspaceTerminalProtocol.RENAME, rename, 1000, function(r) {
      record = r;
      done = true;
    }, function(e) {
      throw e.code;
    }
    );
    step();
    step();
    require(done && record.name == "Build shell" && record.group == "other", "Session rename/group did not commit");
    var error = "";
    client.call(WorkspaceTerminalProtocol.RENAME, rename, 1000, function(_) {
      throw "Stale rename accepted";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "stale_revision", "Rename CAS ignored");
    client.call(WorkspaceTerminalProtocol.FORGET, {
      workspace: "w",
      instance: "first",
      id: record.id,
      resourceInstance: record.instance,
      expectedRevision: record.revision
    }, 1000, function(_) {
      throw "Running record removed";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "terminal_running", "Running session forgotten");
    // Drop the entire client connection: list is independent of attached tabs.
    client.close();
    server.close();
    pair = MemoryTransport.pair();
    client = new RpcConnection(pair.client, clock);
    server = new RpcConnection(pair.server, clock);
    manager.bind(server, [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG]);
    done = false;
    client.call(WorkspaceTerminalProtocol.LIST, {workspace: "w", instance: "first", after: null}, 1000, function(list) {
      require(
        list.terminals.length == 1 && list.terminals[0].available && list.terminals[0].name == "Build shell",
        "Detached runtime vanished"
      );
      done = true;
    }, function(e) {
      throw e.code;
    }
    );
    step();
    step();
    require(done, "Read-only discovery missing");
    client.call(WorkspaceTerminalProtocol.RENAME, rename, 1000, function(_) {
      throw "Read-only rename accepted";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "unauthorized", "Metadata mutation grant ignored");
    client.call(WorkspaceTerminalProtocol.FORGET, {
      workspace: "w",
      instance: "first",
      id: record.id,
      resourceInstance: record.instance,
      expectedRevision: record.revision
    }, 1000, function(_) {
      throw "Read-only forget accepted";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "unauthorized", "Forget grant ignored");
    client.close();
    server.close();
    manager.dispose();
    store.close();
    // A new daemon has metadata, not the old shell. Never silently recreate it.
    store = new WorkspaceSqliteStore(path, "w", seed);
    manager = new WorkspaceTerminalManager("w", "second", root, 65536, store, function() return groups);
    record = manager.snapshot().terminals[0];
    require(
      record.name == "Build shell" && record.group == "other" && record.state == "lost" && !record.available,
      "Restart falsely resurrected shell or lost metadata"
    );
    pair = MemoryTransport.pair();
    client = new RpcConnection(pair.client, clock);
    server = new RpcConnection(pair.server, clock);
    manager.bind(
      server,
      [
        WorkspaceTerminalProtocol.READ,
        WorkspaceTerminalProtocol.CONTROL,
        WorkspaceTerminalProtocol.CATALOG
      ]
    );
    open.instance = "second";
    error = "";
    client.call(WorkspaceTerminalProtocol.OPEN, open, 1000, function(_) {
      throw "Lost record silently restarted";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "terminal_unavailable", "Lost resource was recreated");
    done = false;
    client.call(WorkspaceTerminalProtocol.FORGET, {
      workspace: "w",
      instance: "second",
      id: record.id,
      resourceInstance: record.instance,
      expectedRevision: record.revision
    }, 1000, function(_) done = true, function(e) {
      throw e.code;
    }
    );
    step();
    step();
    require(
      done && manager.snapshot().terminals.length == 0 && store.loadTerminals().length == 0,
      "Forgotten metadata survived"
    );
    // Repeat removal after a lost acknowledgement is safe.
    done = false;
    client.call(WorkspaceTerminalProtocol.FORGET, {
      workspace: "w",
      instance: "second",
      id: record.id,
      resourceInstance: record.instance,
      expectedRevision: record.revision
    }, 1000, function(_) done = true, function(e) {
      throw e.code;
    }
    );
    step();
    step();
    require(done, "Forget not idempotent");
    client.close();
    server.close();
    manager.dispose();
    store.close();
    // Metadata can outnumber runtime slots; discovery stays bounded per message.
    store = new WorkspaceSqliteStore(path, "w", seed);
    for (index in 0...20) store.saveTerminal({
      id: "page-" + index,
      name: "Saved " + index,
      group: "work",
      cwd: root,
      instance: "old",
      state: "exited",
      exitCode: 0,
      available: false,
      revision: 1
    }
    );
    manager = new WorkspaceTerminalManager("w", "third", root, 65536, store, function() return groups);
    pair = MemoryTransport.pair();
    client = new RpcConnection(pair.client, clock);
    server = new RpcConnection(pair.server, clock);
    manager.bind(server, [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG]);
    var after:Null<String> = null, seen = 0, pages = 0;
    do {
      done = false;
      client.call(WorkspaceTerminalProtocol.LIST,
        {workspace: "w", instance: "third", after: after}, 1000, function(page) {
        require(page.terminals.length <= 8, "Catalog page exceeded budget");
        seen += page.terminals.length;
        pages++;
        after = page.next;
        done = true;
      }, function(e) {
        throw e.code;
      }
      );
      step();
      step();
      require(done, "Catalog page missing");
    } while (after != null);
    require(seen == 20 && pages == 3, "Catalog pagination lost or duplicated records");
    client.close();
    server.close();
    manager.dispose();
    store.close();
    Sys
      .println("PASS: terminal catalog discovery after detach, rename/group CAS, permissions, v1 migration, restart loss reconciliation and idempotent forget");
  }
}
