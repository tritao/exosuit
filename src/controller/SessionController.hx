package controller;

import command.CommandRegistry;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import config.ConfigurationPaths;
import core.Application;
import recovery.RecoveryStore;
import session.SessionPersistence;
import session.WorkspaceSession;
import view.RootView;
import workspace.Workspace;

class SessionController {
	public final recovery:RecoveryStore;

	final application:Application;
	final workspace:Workspace;
	final root:RootView;
	final reportError:(String, String)->Void;
	var persistence:Null<SessionPersistence>;
	var lastRecoverySave:Float = 0.0;
	var lastFileSystemCheck:Float = 0.0;
	var started:Bool = false;

	public function new(application:Application, workspace:Workspace, root:RootView, commands:CommandRegistry,
		reportError:(String, String)->Void) {
		this.application = application;
		this.workspace = workspace;
		this.root = root;
		this.reportError = reportError;
		recovery = new RecoveryStore(ConfigurationPaths.recovery());
		commands.add("recovery:open", context -> openRecoveryCommandView());
	}

	public function start():Void {
		if (started) return;
		var sessionPath = ConfigurationPaths.session();
		var saved = WorkspaceSession.load(sessionPath);
		if (saved != null) saved.restore(application, recovery);
		for (diagnostic in recovery.diagnostics) reportError("recovery", diagnostic);
		persistence = new SessionPersistence(sessionPath);
		persistence.begin(application);
		lastRecoverySave = Sys.time();
		started = true;
	}

	public function update(now:Float):Void {
		if (now - lastFileSystemCheck >= 1.0) {
			lastFileSystemCheck = now;
			application.documents.checkExternalChanges();
			workspace.refreshProjects();
		}
		if (!started) return;
		var activePersistence = persistence;
		if (activePersistence != null) activePersistence.update(application, now);
		if (now - lastRecoverySave >= 2.0) {
			recovery.save(application);
			lastRecoverySave = now;
		}
	}

	public function openRecoveryCommandView():Bool {
		var snapshots = recovery.load(), entries:Array<CommandViewEntry> = [];
		for (index in 0...snapshots.length)
			entries.push(new CommandViewEntry(snapshots[index].title, "Recovered unsaved buffer", Std.string(index)));
		for (diagnostic in recovery.diagnostics) reportError("recovery", diagnostic);
		if (entries.length == 0) return false;
		root.commandView.open(new CommandViewProvider("Recover: ", entries, function(query) {}, function(entry, query, backwards) {
			if (entry != null) {
				var selected = Std.parseInt(entry.value);
				if (selected >= 0 && selected < snapshots.length && recovery.restore(application, snapshots[selected])) {
					recovery.forgetSnapshot(snapshots[selected]);
					recovery.save(application);
				}
			}
			root.commandView.close();
		}));
		return true;
	}

	public function shutdown():Void {
		if (!started) return;
		recovery.save(application);
		var activePersistence = persistence;
		if (activePersistence != null) activePersistence.flush(application);
		started = false;
	}
}
