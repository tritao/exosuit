package app;

import feedback.Problem;
import feedback.ProblemRegistry;
import feedback.ProblemScope;
import feedback.ProblemAction;

class ProblemTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var registry = new ProblemRegistry();
		var file = new Problem("language", "one", "/project/Main.hx", 2, 3, 5, "Unused symbol", 2);
		var project = Problem.scoped("build", "start", Project("/project"), "Missing compiler", 1, "Build", [new ProblemAction("Show output", "build:show-output")]);
		var workspace = Problem.scoped("agents", "service", Workspace, "Service unavailable", 1, "Agents");
		registry.replaceOwner("language", [file]); registry.replaceOwner("build", [project]); registry.add(workspace);
		require(registry.values().length == 3 && file.location != null && project.location == null && workspace.location == null, "scope/location modeling failed");
		require(file.scopeKey() != project.scopeKey() && project.scopeKey() != workspace.scopeKey(), "scopes collided");
		var revision = registry.revision;
		registry.replaceOwner("language", [new Problem("language", "one", "/project/Main.hx", 3, 3, 5, "Updated", 2)]);
		require(registry.revision == revision + 1 && registry.values().length == 3, "producer snapshot was not atomic");
		var before = registry.values();
		registry.replaceOwner("language", [new Problem("language", "one", "/project/Main.hx", 3, 3, 5, "Updated", 2)]);
		require(registry.revision == revision + 1, "identical refresh caused registry churn");
		var failed = false;
		try registry.replaceOwner("language", [workspace]) catch (_:Dynamic) failed = true;
		require(failed && registry.values().length == before.length && registry.revision == revision + 1, "invalid snapshot changed registry");
		failed = false;
		try registry.replaceOwner("language", [file, file]) catch (_:Dynamic) failed = true;
		require(failed && registry.revision == revision + 1, "duplicate IDs changed registry");
		registry.add(workspace); require(registry.values().length == 3, "upsert duplicated stable ID");
		registry.replaceOwner("language", []); require(registry.values().length == 2, "producer clear removed another producer");
		require(project.forAction(project.actions[0]).location == null && project.forAction(project.actions[0]).actions[0].command == "build:show-output", "action request lost command");
		require(file.key() != new Problem("other", "one", "/project/Main.hx", 0, 0, 0, "Other", 1).key(), "producer identities collided");
		var dock = new nativekit.ui.docking.DockWorkspaceModel();
		dock.register(new nativekit.ui.docking.DockPanelDescriptor("problems", "Problems"));
		require(dock.setPanelBadge("problems", 3), "badge update rejected");
		var badgeRevision = dock.revision;
		require(!dock.setPanelBadge("problems", 3) && dock.revision == badgeRevision, "identical badge invalidated layout");
		require(dock.setPanelBadge("problems", 0) && !dock.setPanelBadge("problems", -1), "badge clearing/validation failed");

		trace("PASS: scoped diagnostics, stable identities, producer isolation, atomic replacement, actions");
		return 0;
	}
}
