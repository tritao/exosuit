package app;

import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import platform.Platform;
import process.ProcessManager;
import workspace.client.LocalWorkspaceClient;

class AttachmentTestMain {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }

  static function main():Void {
    var args = Sys.args(), mode = args[0], root = args[1], launcher = args[2];
    if (mode == "cleanup-relay") {
      var cleanupRuntime = NativeKitRuntime.start();
      for (account in ["relay:" + launcher + "/machine/" + root, "noise-static:" + root]) {
        var value:haxe.io.Bytes = haxeon.credentials.Credentials.get("com.exosuit.workspace-relay", account);
        if (value != null) {
          for (index in 0...value.length) value.set(index, 0);
          haxeon.credentials.Credentials.delete("com.exosuit.workspace-relay", account);
        }
      }
      cleanupRuntime.dispose();
      return;
    }

    var runtime = NativeKitRuntime.start(), processes = new ProcessManager();
    var clock = function() return NativeKit.nk_time_seconds() * 1000;
    if (mode == "terminal-legacy-inspect") {
      var legacy = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
      legacy.select(root);
      var backend = new workspace.client.RpcTerminalBackend(function() return legacy, args[3], root, false, null, null, true);
      var deadline = clock() + 30000;
      while (clock() < deadline) {
        runtime.events.wait(0.005);
        for (_ in 0...128) if (!runtime.events.poll()) break;
        legacy.poll(); backend.pollEvents(function(_) {});
        if (backend.controlStatus().indexOf("update the workspace daemon") >= 0) break;
      }
      require(backend.isAttached(), "Legacy control RPC disconnected terminal output");
      require(backend.controlStatus().indexOf("update the workspace daemon") >= 0, "Expected legacy daemon compatibility status");
      require(backend.controlAction() == "", "Unsupported control action remains enabled");
      backend.close(); legacy.dispose(); processes.shutdown(); runtime.dispose();
      Sys.println("PASS: legacy daemon keeps terminal attached with an actionable update status");
      return;
    }
    if (mode == "terminal-pool") {
      var other = root + "/other";
      sys.FileSystem.createDirectory(other);
      var pool = new workspace.client.LocalTerminalWorkspacePool(runtime.events, processes, launcher, clock);
      var first = pool.endpoint(root), second = pool.endpoint(other);
      require(first != second && pool.endpoint(root) == first, "Terminal roots share or replace an endpoint");
      var one = new workspace.client.RpcTerminalBackend(function() return pool.endpoint(root), "pool-first", root, true);
      var two = new workspace.client.RpcTerminalBackend(function() return pool.endpoint(other), "pool-second", other, true);
      var deadline = clock() + 90000;
      while ((!one.isAttached() || !two.isAttached()) && clock() < deadline) {
        runtime.events.wait(0.005);
        for (_ in 0...128) if (!runtime.events.poll()) break;
        pool.poll();
        one.pollEvents(function(_) {}); two.pollEvents(function(_) {});
      }
      require(one.isAttached() && two.isAttached(), "Terminals did not attach to both workspace daemons");
      require(first.rootPath() == root && second.rootPath() == other, "Workspace identity changed across terminal roots");
      require(pool.endpoint(other) == second && pool.endpoint(root) == first, "Switching roots replaced a terminal connection");
      var peer = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
      peer.select(root);
      var restored = new workspace.client.RpcTerminalBackend(function() return peer, "pool-first", root, false, null, null, true);
      var tick = function() {
        runtime.events.wait(0.005);
        for (_ in 0...128) if (!runtime.events.poll()) break;
        pool.poll(); peer.poll();
        one.pollEvents(function(_) {}); restored.pollEvents(function(_) {});
      };
      deadline = clock() + 10000;
      while (!restored.isAttached() && clock() < deadline) tick();
      require(restored.isAttached() && one.canControl() && !restored.canControl(), "Restoring stole another client's control");
      one.activateControl();
      deadline = clock() + 5000;
      while (!restored.canControl() && clock() < deadline) tick();
      require(restored.canControl(), "Restored desktop did not claim an unowned terminal");
      restored.activateControl();
      deadline = clock() + 5000;
      while (restored.controlStatus() != "Read only · no client is controlling this terminal" && clock() < deadline) tick();
      require(!restored.canControl(), "Explicit release failed");
      deadline = clock() + 300;
      while (clock() < deadline) tick();
      require(!restored.canControl(), "Automatic claim overrode an explicit release");
      restored.close(); peer.dispose();
      var mismatched = new workspace.client.RpcTerminalBackend(function() return pool.endpoint(root), "missing", other, false);
      require(mismatched.controlStatus().indexOf(other) >= 0, "Workspace mismatch still shows an indefinite connecting status");
      mismatched.close();
      var missing = new workspace.client.RpcTerminalBackend(function() return pool.endpoint(root), "missing-restored-session", root, false);
      deadline = clock() + 5000;
      while (missing.controlStatus().indexOf("Terminal unavailable:") != 0 && clock() < deadline) {
        runtime.events.wait(0.005);
        for (_ in 0...128) if (!runtime.events.poll()) break;
        pool.poll();
        try missing.pollEvents(function(_) {}) catch (_:Dynamic) {}
      }
      require(missing.controlStatus().indexOf("Terminal unavailable:") == 0, "Missing restored terminal still shows connecting");
      missing.close();
      pool.retainRoots([other]);
      require(first.rpcConnection() == null && second.rpcConnection() != null, "Closing one root disconnected another or retained its unused client");
      one.close(); two.close(); pool.dispose(); processes.shutdown(); runtime.dispose();
      Sys.println("PASS: terminals attach to independent workspace daemons and retain endpoints across root switches");
      return;
    }
    var a = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
    var b = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
    var step = function() {
      runtime.events.wait(0.005);
      for (_ in 0...128) if (!runtime.events.poll()) break;
      a.poll();
      b.poll();
    };
    a.select(root);
    b.select(root);
    var deadline = clock() + 115000;
    if (mode == "relay-persist-inspect") {
      while ((!a.ready || !b.ready) && clock() < deadline) {
        require(a.error == null && b.error == null, "Attachment failed after relay restart: " + a.error + " / " + b.error);
        step();
      }
      deadline = clock() + 10000;
      while (a.remoteAccessStatus() == null && clock() < deadline) { a.refreshPairings(false); step(); }
      var status = a.remoteAccessStatus();
      require(a.ready && status != null && status.configured && status.origin == args[3],
        "Persisted relay configuration was not restored after manager restart: " + (status == null ? "no status" : status.origin));
      a.dispose(); b.dispose(); processes.shutdown(); runtime.dispose();
      Sys.println("PASS: workspace relay settings persist across manager restart");
      return;
    }
    if (mode == "reject") {
      while (a.error == null && clock() < deadline) {
        require(!a.ready, "Unverified workspace accepted");
        step();
      }
      require(a.error != null && !a.ready, "Mismatched discovery/daemon identity accepted");
      Sys.println("PASS: invalid workspace discovery/identity fails closed");
    } else {
      while ((!a.ready || !b.ready) && clock() < deadline) {
        require(a.error == null && b.error == null, "Attachment failed: " + a.error + " / " + b.error);
        step();
      }
      require(
        a.ready && b.ready && a.instance == b.instance && a.view()[0].cwd == sys.FileSystem.fullPath(root),
        "Concurrent clients did not attach to one validated daemon"
      );
      if (mode == "update-idle" || mode == "update-busy" || mode == "update-now" || mode == "update-legacy") {
        var previous = a.instance;
        var busy = mode != "update-idle";
        if (busy) {
          var opened = false;
          a.rpc().call(workspace.service.WorkspaceTerminalProtocol.OPEN,
            {workspace: "workspace", instance: previous, id: "update-test", create: true, columns: 80, rows: 24},
            3000, function(_) opened = true, function(error) { throw error.message; });
          deadline = clock() + 5000;
          while (!opened && clock() < deadline) step();
          require(opened, "Could not open test terminal");
        }
        sys.io.File.saveContent(args[3], "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        a.select(null); a.select(root);
        deadline = clock() + 110000;
        if (busy) {
          while ((!a.ready || !a.serviceUpdateAvailable() || mode != "update-legacy" && a.serviceStatus() == null) && clock() < deadline) step();
          require(a.serviceUpdateAvailable(), "Changed build was not detected");
          var until = clock() + 2000;
          while (clock() < until) { step(); require(b.ready && b.instance == previous, "Busy service restarted automatically"); }
          if (mode == "update-now" || mode == "update-legacy") {
            a.requestServiceUpdate("now");
          } else {
          a.requestServiceUpdate("idle");
          while (clock() < deadline) {
            step(); require(b.ready && b.instance == previous, "Queued update interrupted a running terminal");
            var currentStatus = a.serviceStatus();
            if (currentStatus != null && currentStatus.updatePending) break;
            require(a.serviceUpdateError() == null, "Update preparation failed: " + a.serviceUpdateError());
          }
          var queued = a.serviceStatus();
          require(queued != null && queued.updatePending && queued.terminals == 1, "Update did not wait for active terminal");
          a.requestServiceUpdate("cancel");
          var canceled = false;
          var cancelDeadline = clock() + 5000;
          while (clock() < cancelDeadline) {
            step(); var currentStatus = a.serviceStatus();
            if (currentStatus != null && !currentStatus.updatePending && !a.serviceUpdateBusy()) { canceled = true; break; }
          }
          require(canceled && b.instance == previous, "Could not cancel queued update");
          a.requestServiceUpdate("idle");
          a.rpc().call(workspace.service.WorkspaceTerminalProtocol.TERMINATE,
            {workspace: "workspace", instance: previous, id: "update-test"}, 3000,
            function(_) {}, function(error) { throw error.message; });
          }
        }
        while (clock() < deadline) {
          step();
          require(a.error == null && b.error == null, "Reconnect failed: " + a.error + " / " + b.error);
          require(a.serviceUpdateError() == null, "Update failed: " + a.serviceUpdateError());
          var currentStatus = a.serviceStatus();
          if (a.ready && b.ready && a.instance != previous && a.instance == b.instance && currentStatus != null
            && currentStatus.build == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") break;
        }
        require(a.ready && b.ready && a.instance != previous && a.instance == b.instance, "Clients did not reconnect to replacement daemon");
        a.dispose(); b.dispose(); processes.shutdown(); runtime.dispose();
        Sys.println("PASS: " + mode + " replaces daemon safely and reconnects sibling editors");
        return;
      }
      if (mode == "update-existing-idle") {
        if (a.serviceUpdateAvailable() && !a.serviceUpdateBusy()) a.requestServiceUpdate("idle");
        deadline = clock() + 115000;
        while (a.serviceUpdateBusy() && clock() < deadline) step();
        require(!a.serviceUpdateBusy() && a.serviceUpdateError() == null,
          "Could not schedule idle update: " + a.serviceUpdateError());
        a.dispose(); b.dispose(); processes.shutdown(); runtime.dispose();
        Sys.println("PASS: workspace update prepared and requested for idle without terminating sessions");
        return;
      }
      if (mode == "relay-live" || mode == "relay-inspect" || mode == "relay-browser") {
        var original = a.instance;
        deadline = clock() + 5000;
        while (a.remoteAccessStatus() == null && clock() < deadline) { a.refreshPairings(false); step(); }
        if (mode != "relay-inspect") a.configureRelay(args[3]);
        deadline = clock() + 30000;
        var connected = false;
        while (clock() < deadline) {
          step(); a.refreshPairings(false);
          require(a.error == null && b.error == null && b.ready && b.instance == original,
            "Relay setup interrupted the workspace: " + a.error + " / " + b.error);
          var status = a.remoteAccessStatus();
          if (status != null && status.connected && a.canManagePairings()) { connected = true; break; }
        }
        var status = a.remoteAccessStatus();
        require(connected, "Native hosted relay connection failed: " + (status == null ? "no status" : status.error));
        if (mode == "relay-inspect") {
          deadline = clock() + 90000;
          while ((!a.ready || a.serviceUpdateAvailable() || a.serviceUpdateBusy()) && clock() < deadline) {
            var service = a.serviceStatus();
            if (service != null && (service.terminals > 0 || service.agents > 0)) break;
            step();
          }
          require(a.serviceUpdateError() == null, "Service update failed: " + a.serviceUpdateError());
          Sys.println("SERVICE: " + haxe.Json.stringify(a.serviceStatus()));
          Sys.println("UPDATE AVAILABLE: " + a.serviceUpdateAvailable());
          a.refreshPairings(true);
          deadline = clock() + 5000;
          while (a.pairingList() == null && a.pairingError() == null && clock() < deadline) step();
          require(a.pairingList() != null && a.pairingError() == null, "Current workspace pairing RPC failed: " + a.pairingError());
          a.dispose(); b.dispose(); processes.shutdown(); runtime.dispose();
          Sys.println("PASS: current workspace relay connected and pairing administration responds without errors");
          return;
        }
        var invited = false, invitationError:Null<String> = null;
        a.createPairing(60, function(value, error) {
          invitationError = error;
          invited = value != null && value.pairingSocketUrl.indexOf("wss://") == 0;
          if (invited && mode == "relay-browser") sys.io.File.saveContent(args[4], value.pairingSocketUrl);
        });
        deadline = clock() + 10000;
        while (!invited && invitationError == null && clock() < deadline) step();
        require(invited && invitationError == null, "Native live pairing invitation failed: " + invitationError);
        if (mode == "relay-browser") {
          Sys.println("READY: browser pairing fixture");
          deadline = clock() + 90000;
          var pending = false;
          var approvalStarted = false;
          while (clock() < deadline) {
            step(); a.refreshPairings(false);
            if (sys.FileSystem.exists(args[4] + ".done")) break;
            var pairings = a.pairingList();
            if (pairings != null && pairings.pending.length > 0) {
              sys.io.File.saveContent(args[4] + ".code", pairings.pending[0].authenticationCode);
              pending = true;
              if (!approvalStarted && sys.FileSystem.exists(args[4] + ".approve")) {
                approvalStarted = true;
                a.approvePairing(pairings.pending[0].deviceId,
                  [workspace.service.WorkspaceProtocol.IDENTITY_CAPABILITY, workspace.service.WorkspaceProtocol.READ,
                   workspace.service.WorkspaceProtocol.TREE, workspace.service.WorkspaceFileProtocol.READ], function(error) {
                    sys.io.File.saveContent(args[4] + ".approval-result", error == null ? "ok" : error);
                  });
              }
              if (sys.FileSystem.exists(args[4] + ".done")) break;
            }
          }
          require(pending, "Browser did not reach native Noise pairing confirmation");
          Sys.println("PASS: browser reached native Noise pairing confirmation");
        }
        a.dispose(); b.dispose(); processes.shutdown(); runtime.dispose();
        Sys.println("PASS: native HTTPS/WSS hosted relay connection and pairing invitation preserve sibling editor sessions");
        return;
      }
      if (mode == "remote-setup") {
        var instance = a.instance;
        deadline = clock() + 5000;
        while (a.remoteAccessStatus() == null && clock() < deadline) { a.refreshPairings(false); step(); }
        var initialStatus = a.remoteAccessStatus();
        require(initialStatus != null && !initialStatus.configured && a.canConfigureRelay(),
          "Connected local daemon did not expose unconfigured remote access");
        a.configureRelay("https://relay.example/path?token=secret");
        require(a.pairingError() != null && a.ready && b.ready, "Invalid relay address disturbed the workspace");
        a.configureRelay("https://127.0.0.1:1");
        deadline = clock() + 15000;
        while (clock() < deadline) {
          step(); a.refreshPairings(false);
          require(b.ready && b.instance == instance, "Enabling remote access interrupted a sibling workspace client");
          var status = a.remoteAccessStatus();
          if (status != null && status.configured && status.error != null) break;
        }
        var status = a.remoteAccessStatus();
        require(a.ready && a.instance == instance && status != null && status.configured && !status.connected
          && status.origin == "https://127.0.0.1:1" && status.error != null && !a.canManagePairings(),
          "Runtime relay configuration did not report offline status without replacing the daemon: " + a.error);
        a.dispose(); b.dispose(); processes.shutdown(); runtime.dispose();
        Sys.println("PASS: relay setup preserves the daemon and sibling clients, reports connection errors, and gates invitations");
        return;
      }
      if (mode == "hold") {
        var holdUntil = clock() + 12000;
        while (clock() < holdUntil) {
          if (clock() >= holdUntil - 6000) a.dispose();
          step();
          require(b.ready && b.error == null, "Connected sibling lost during idle grace");
        }
        Sys.println("PASS: authenticated clients keep daemon alive beyond its idle timeout");
        a.dispose();
        b.dispose();
        processes.shutdown();
        runtime.dispose();

        return;
      }
      var previousInstance = a.instance, previousEpoch = a.epoch();
      a.dispose();
      for (_ in 0...8) step();
      require(b.ready, "Closing a client stopped its sibling's daemon");
      // Switching cancels the old attachment and resumes the same persistent workspace on return.
      b.select(root + "/other");
      deadline = clock() + 115000;
      while (!b.ready && clock() < deadline) {
        require(b.error == null, "Folder switch failed: " + b.error);
        step();
      }
      require(
        b.ready && b.instance != previousInstance && b.view()[0].cwd == sys.FileSystem.fullPath(root + "/other"),
        "Folder switch kept the old catalog"
      );
      b.select(root);
      deadline = clock() + 15000;
      while (!b.ready && clock() < deadline) {
        require(b.error == null, "Reuse failed: " + b.error);
        step();
      }
      require(
        b.ready && b.instance == previousInstance && b.epoch() == previousEpoch,
        "Returning to a folder spawned a replacement daemon"
      );
      Sys
        .println("PASS: concurrent discovery/spawn, typed identity, shared reuse, folder switching and client-independent daemon lifetime");
    }
    a.dispose();
    b.dispose();
    processes.shutdown();
    require(processes.activeCount() == 0, "Attachment helper leaked");
    runtime.dispose();

  }
}
