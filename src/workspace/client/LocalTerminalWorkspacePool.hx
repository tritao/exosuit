package workspace.client;

import haxeon.platform.event.EventPump;
import process.ProcessManager;

/**
	Keeps terminal attachments independent of the currently selected project. A terminal's root is the folder its
	service started in; when `resolver` says that root belongs to a machine workspace (M19 Phase 4), the terminal
	attaches to the workspace's service, shared by all of its roots, else to the folder's.
**/
class LocalTerminalWorkspacePool {
    final clients:Map<String, LocalWorkspaceClient> = [];
    final events:EventPump;
    final processes:ProcessManager;
    final launcher:String;
    final clock:Void->Float;
    final resolver:Null<String->Null<WorkspaceServiceTarget>>;
    final waiting:Null<Void->Bool>;
    var disposed:Bool = false;

    /**
        `resolver` finds the workspace a root belongs to, or null for a folder's own service. While `waiting` says the
        machine's workspaces are not known yet, no root is attached: it could start a folder's service by mistake.
    **/
    public function new(events:EventPump, processes:ProcessManager, launcher:String, clock:Void->Float,
            ?resolver:String->Null<WorkspaceServiceTarget>, ?waiting:Void->Bool) {
        this.resolver = resolver;
        this.waiting = waiting;
        this.events = events;
        this.processes = processes;
        this.launcher = launcher;
        this.clock = clock;
    }

    public function endpoint(root:String):Null<WorkspaceRpcEndpoint> {
        if (disposed) return null;
        var check = waiting;
        if (check != null && check()) return null;
        var target = targetFor(root), key = target == null ? root : target.choiceKey();
        var client = clients.get(key);
        if (client == null) {
            client = new LocalWorkspaceClient(events, processes, launcher, clock);
            clients.set(key, client);
            if (target == null) client.select(root);
        }
        // The workspace's folders may have changed since the client attached.
        if (target != null) client.selectWorkspace(target);
        return client;
    }

    function targetFor(root:String):Null<WorkspaceServiceTarget> {
        var find = resolver;
        return find == null ? null : find(root);
    }

    public function poll():Void {
        if (!disposed) for (client in clients) client.poll();
    }

    public function retainRoots(roots:Array<String>):Void {
        var check = waiting;
        if (check != null && check()) return;
        var used:Map<String, Bool> = [];
        for (root in roots) {
            var target = targetFor(root);
            used.set(target == null ? root : target.choiceKey(), true);
        }
        var unused = [for (key in clients.keys()) if (!used.exists(key)) key];
        for (key in unused) {
            var client = clients.get(key);
            clients.remove(key);
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
