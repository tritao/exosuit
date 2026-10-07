package workspace.client;

import haxeon.platform.NativeKitEvents;
import process.ProcessManager;

/** Keeps terminal attachments independent of the currently selected project. */
class LocalTerminalWorkspacePool {
    final clients:Map<String, LocalWorkspaceClient> = [];
    final events:NativeKitEvents;
    final processes:ProcessManager;
    final launcher:String;
    final clock:Void->Float;
    var disposed:Bool = false;

    public function new(events:NativeKitEvents, processes:ProcessManager, launcher:String, clock:Void->Float) {
        this.events = events;
        this.processes = processes;
        this.launcher = launcher;
        this.clock = clock;
    }

    public function endpoint(root:String):Null<WorkspaceRpcEndpoint> {
        if (disposed) return null;
        var client = clients.get(root);
        if (client == null) {
            client = new LocalWorkspaceClient(events, processes, launcher, clock);
            clients.set(root, client);
            client.select(root);
        }
        return client;
    }

    public function poll():Void {
        if (!disposed) for (client in clients) client.poll();
    }

    public function retainRoots(roots:Array<String>):Void {
        var unused = [for (root in clients.keys()) if (roots.indexOf(root) < 0) root];
        for (root in unused) {
            var client = clients.get(root);
            clients.remove(root);
            client.dispose();
        }
    }

    public function dispose():Void {
        if (disposed) return;
        disposed = true;
        for (client in clients) client.dispose();
        clients.clear();
    }
}
