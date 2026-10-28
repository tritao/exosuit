package app;

import haxe.Int64;
import haxe.io.Bytes;
import scm.LocalScmSource;
import scm.NarrowedOperation;
import scm.ScmFolderScope;
import scm.git.GitConfigFile;
import scm.ScmChangeKind;
import scm.ScmOperation;
import scm.ScmGroup;
import scm.ScmGroupId;
import scm.ScmHead;
import scm.ScmHeadOperation;
import scm.ScmResource;
import scm.ScmSnapshot;
import ui.AgentScope;
import ui.AgentScopeTracker;
import ui.GroupContextActions;
import ui.GroupRemoval;
import ui.LayoutMode;
import ui.WorkbenchGroupLabel;
import ui.WorkbenchRowKey;
import ui.WorkbenchRowKind;
import ui.WorkbenchTreeModel;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

/** The Agents layout's right-panel scope rule and its folder-narrowed Changes. */
class AgentScopeTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function group(id:String, name:String, cwd:Null<String>, ?parent:String, order:Int = 0):WorkspaceGroup
		return {id: id, name: name, cwd: cwd, revision: 1, parent: parent, order: order};

	static function terminal(id:String, group:String):TerminalRecord
		return {id: id, name: id, group: group, cwd: "", instance: "i", state: "running", exitCode: 0, available: true,
			revision: Int64.make(0, 1), workspaceRoot: "C:/work"};

	static function model(groups:Array<WorkspaceGroup>):WorkbenchTreeModel {
		var catalog:TerminalCatalog = {instance: "i", groups: groups, terminals: [terminal("t1", "resume"), terminal("t2", "ui")], next: null,
			workspaceRoot: "C:/work"};
		var agents:AgentCatalog = {instance: "i", root: "C:/work", status: "ready", next: null, records: [
			{id: "a1", name: "Agent", group: "ui", cwd: "", thread: "", state: "idle", turn: null, workspaceRoot: "C:/work"}]};
		var result = new WorkbenchTreeModel();
		result.update(catalog, agents);
		return result;
	}

	static function scopeRule():Void {
		var groups = [group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("ui", "ui", "C:/work/exosuit/graphical", "resume", 1),
			group("notes", "notes", null, "resume", 2), group("loose", "loose", null, null, 3)];
		var tree = model(groups);
		// Nothing chosen yet: the first top-level group stands in instead of the editor's workspace folders.
		var first = AgentScope.resolve(tree, null, null);
		require(first != null && first.groupId == "resume" && first.directory == "C:/work/exosuit", "no selection did not fall back to the first group");
		// A group row uses its directory; a sub-group narrows to its sub-folder.
		var resume = AgentScope.resolve(tree, "g:resume", null);
		require(resume != null && resume.directory == "C:/work/exosuit" && resume.caption() == "resume-2026 \u2014 C:/work/exosuit", "group row scope or caption");
		var ui = AgentScope.resolve(tree, "g:ui", resume);
		require(ui != null && ui.groupId == "ui" && ui.directory == "C:/work/exosuit/graphical", "sub-group did not narrow to its folder");
		// A session or terminal row uses its group's directory.
		var agent = AgentScope.resolve(tree, "a:a1", resume);
		require(agent != null && agent.groupId == "ui" && agent.directory == "C:/work/exosuit/graphical", "agent session did not use its group");
		var term = AgentScope.resolve(tree, "t:t1", ui);
		require(term != null && term.groupId == "resume", "terminal did not use its group");
		// A group without its own folder inherits its parent's; a top-level one the workspace root.
		var notes = AgentScope.resolve(tree, "g:notes", ui);
		require(notes != null && notes.groupId == "notes" && notes.directory == "C:/work/exosuit", "sub-group without cwd did not inherit");
		var loose = AgentScope.resolve(tree, "g:loose", ui);
		require(loose != null && loose.directory == "C:/work", "top-level group without cwd did not use the workspace root");
		// Nothing selected, or a row that is gone: the last group's scope stays.
		var kept = AgentScope.resolve(tree, null, ui);
		require(kept != null && kept.equals(ui), "empty selection dropped the last group's scope");
		var stale = AgentScope.resolve(tree, "t:gone", ui);
		require(stale != null && stale.equals(ui), "a row without a group replaced the scope");
		// The kept scope follows its group's rename and new folder.
		var moved = model([group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("ui", "web", "C:/work/exosuit/web", "resume", 1)]);
		var followed = AgentScope.resolve(moved, null, ui);
		require(followed != null && followed.label == "web" && followed.directory == "C:/work/exosuit/web", "kept scope missed its group's change");
		// A deleted group's scope falls back to its nearest surviving parent group, then the first group, then nothing.
		var removed = model([group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("loose", "loose", null, null, 3)]);
		var parent = AgentScope.resolve(removed, null, ui);
		require(parent != null && parent.groupId == "resume" && parent.directory == "C:/work/exosuit", "a deleted group's scope did not fall back to its parent");
		var nested = model([group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("ui", "ui", "C:/work/exosuit/graphical", "resume", 1),
			group("deep", "deep", "C:/work/exosuit/graphical/src", "ui", 2)]);
		var deep = AgentScope.resolve(nested, "g:deep", ui);
		require(deep != null && deep.ancestors.join(",") == "ui,resume", "a scope did not record its parent groups");
		var grand = AgentScope.resolve(removed, null, deep);
		require(grand != null && grand.groupId == "resume", "a scope whose group and parent were deleted skipped the surviving grandparent");
		var unrelated = model([group("loose", "loose", null, null, 3), group("other", "other", "D:/other", null, 1)]);
		var remaining = AgentScope.resolve(unrelated, null, deep);
		require(remaining != null && remaining.groupId == "other", "with no surviving parent the scope did not move to the first group");
		require(AgentScope.resolve(new WorkbenchTreeModel(), null, deep) == null, "a scope survived every group being deleted");
		// A group folder may be any folder, inside the workspace or not; the scope takes it as given.
		var outside = model([group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("elsewhere", "elsewhere", "D:/scratch/other-repo", "resume", 1),
			group("under", "under", null, "elsewhere", 2)]);
		var far = AgentScope.resolve(outside, "g:elsewhere", resume);
		require(far != null && far.directory == "D:/scratch/other-repo", "a folder outside the workspace was not used");
		var inherited = AgentScope.resolve(outside, "g:under", far);
		require(inherited != null && inherited.directory == "D:/scratch/other-repo", "a sub-group did not inherit an outside folder");
		// No groups at all: no scope.
		require(AgentScope.resolve(new WorkbenchTreeModel(), null, null) == null, "empty Workbench produced a scope");
	}

	/** The tracker keeps the normalized spelling for the panel but resolves against the service's spelling. */
	static function tracker():Void {
		var groups = [group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("ui", "ui", "C:/work/exosuit/graphical", "resume", 1)];
		var calls = 0;
		var scopes = new AgentScopeTracker(function(path) { calls++; return StringTools.replace(path, "/", "\\"); });
		var tree = model(groups);
		var ui = scopes.resolve(tree, "g:ui");
		require(ui != null && ui.directory == "C:\\work\\exosuit\\graphical" && calls == 1, "tracker did not normalize the scope folder");
		var kept = scopes.resolve(tree, null);
		require(kept == ui && calls == 1, "an unchanged scope was normalized again or replaced");
		var fallback = scopes.resolve(model([groups[0]]), null);
		require(fallback != null && fallback.groupId == "resume" && fallback.directory == "C:\\work\\exosuit", "tracker lost the parent fallback");
		var failing = new AgentScopeTracker(function(path):String throw "gone");
		var gone = failing.resolve(tree, "g:ui");
		require(gone != null && gone.directory == "C:/work/exosuit/graphical", "a folder that cannot be normalized lost its scope");
		scopes.reset();
		require(scopes.resolve(new WorkbenchTreeModel(), null) == null, "reset kept the last scope");
	}

	static function rowKeys():Void {
		var tree = model([group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("ui", "ui", "C:/work/exosuit/graphical", "resume", 1)]);
		var row = WorkbenchRowKey.parse("a:a1");
		require(row != null && row.kind == WorkbenchRowKind.Agent && row.id == "a1" && row.toString() == "a:a1", "agent row key");
		require(WorkbenchRowKey.parse("x:1") == null && WorkbenchRowKey.parse("g:") == null && WorkbenchRowKey.parse(null) == null
			&& WorkbenchRowKey.parse("g1") == null, "malformed row keys parsed");
		var colon = WorkbenchRowKey.parse(WorkbenchRowKey.group("a:b"));
		require(colon != null && colon.id == "a:b", "ids keep their own colons");
		var terminalGroup = WorkbenchRowKey.groupOf(tree, "t:t2"), ownGroup = WorkbenchRowKey.groupOf(tree, "g:resume");
		require(terminalGroup != null && terminalGroup.id == "ui" && ownGroup != null && ownGroup.id == "resume"
			&& WorkbenchRowKey.groupOf(tree, "a:gone") == null, "row group");
		require(WorkbenchRowKey.parentGroupId(tree, "g:ui") == "resume" && WorkbenchRowKey.parentGroupId(tree, "g:resume") == null
			&& WorkbenchRowKey.parentGroupId(tree, "a:a1") == "ui", "row parent group");
		require(WorkbenchRowKey.idOf("t:t1", WorkbenchRowKind.Terminal) == "t1"
			&& WorkbenchRowKey.idOf("t:t1", WorkbenchRowKind.Agent) == null, "row id by kind");
	}

	/** Group rows show the folder relative to the workspace root in any case or separator, also below a drive root. */
	static function groupLabels():Void {
		require(WorkbenchGroupLabel.shortDirectory("C:\\Users\\Me\\work\\a\\b", "c:\\users\\me\\WORK") == "./a/b", "case-insensitive Windows root");
		require(WorkbenchGroupLabel.shortDirectory("C:\\work\\a", "C:/work/") == "./a", "root with a trailing separator");
		require(WorkbenchGroupLabel.shortDirectory("C:\\a\\b", "C:\\") == "./a/b", "drive root");
		require(WorkbenchGroupLabel.shortDirectory("C:\\Work", "c:\\work") == "Work", "the root itself");
		require(WorkbenchGroupLabel.shortDirectory("C:\\workshop\\x\\y", "C:\\work") == "…\\x\\y", "a sibling with a shared prefix");
		require(WorkbenchGroupLabel.shortDirectory("/Home/me/a", "/home/me") == "…/me/a", "POSIX paths compare case-sensitively");
		require(WorkbenchGroupLabel.shortDirectory("/home/me/a/b", "/home/me/") == "./a/b", "POSIX root with a trailing separator");
		require(WorkbenchGroupLabel.shortDirectory("/srv/x", null) == "/srv/x", "short path without a root");
		require(WorkbenchGroupLabel.shortDirectory("/home/me/a/b", "") == "…/a/b", "an empty root acted as the parent of every path");
	}

	/** Remove Group stays in the menu while the group has contents, disabled with the reason. */
	static function groupRemoval():Void {
		var groups = [group("resume", "resume-2026", "C:/work/exosuit", null, 0), group("ui", "ui", null, "resume", 1), group("empty", "empty", null, null, 2)];
		var catalog:TerminalCatalog = {instance: "i", groups: groups, terminals: [terminal("t1", "ui")], next: null, workspaceRoot: "C:/work"};
		var agents:AgentCatalog = {instance: "i", root: "C:/work", status: "ready", next: null, records: []};
		require(GroupContextActions.removalOf("empty", true, false, catalog, agents) == GroupRemoval.Allowed, "an empty group cannot be removed");
		var full = GroupContextActions.removalOf("ui", true, false, catalog, agents), parent = GroupContextActions.removalOf("resume", true, false, catalog, agents);
		require(full == GroupRemoval.NotEmpty && parent == GroupRemoval.NotEmpty, "a group with a terminal or a sub-group is removable");
		require(GroupContextActions.removeLabel(full) == "Remove Group (not empty)" && GroupContextActions.removeLabel(GroupRemoval.Allowed) == "Remove Group",
			"Remove Group label");
		require(GroupContextActions.removalOf("empty", false, false, catalog, agents) == GroupRemoval.NotPermitted, "removal without the grant");
		require(GroupContextActions.removalOf("empty", true, true, catalog, agents) == GroupRemoval.Busy
			&& GroupContextActions.removalOf("empty", true, false, catalog, null) == GroupRemoval.Busy, "removal while busy or loading");
	}

	static function resource(path:String, kind:ScmChangeKind, ?original:String):ScmResource
		return new ScmResource(Bytes.ofString(path), kind, original == null ? null : Bytes.ofString(original));

	static function narrowedChanges():Void {
		var head = new ScmHead("main", null, false, null, 0, 0, false, ScmHeadOperation.None);
		var snapshot = new ScmSnapshot(Int64.make(0, 7), head, [
			new ScmGroup(ScmGroupId.Index, [resource("graphical/src/A.hx", ScmChangeKind.Modified), resource("README.md", ScmChangeKind.Modified)]),
			new ScmGroup(ScmGroupId.WorkingTree, [resource("src/B.hx", ScmChangeKind.Modified),
				resource("graphical/src/Moved.hx", ScmChangeKind.Renamed, "src/Old.hx")]),
			new ScmGroup(ScmGroupId.Untracked, [resource("docs/new.md", ScmChangeKind.Untracked)])]);
		var narrowed = LocalScmSource.narrowSnapshot(snapshot, ["graphical/"]);
		require(Int64.compare(narrowed.revision, snapshot.revision) == 0 && narrowed.head == head, "narrowing changed the revision or head");
		require(narrowed.groups.length == 2, "groups without changes in the folder were kept");
		require(narrowed.groups[0].resources.length == 1 && narrowed.groups[0].resources[0].path == "graphical/src/A.hx", "index changes outside the folder were kept");
		require(narrowed.groups[1].resources.length == 1 && narrowed.groups[1].resources[0].path == "graphical/src/Moved.hx", "working-tree narrowing");
		var renamed = LocalScmSource.narrowSnapshot(snapshot, ["src/"]);
		var working = [for (group in renamed.groups) if (group.id == ScmGroupId.WorkingTree) group];
		require(working.length == 1 && working[0].resources.length == 2, "a rename out of the folder was dropped");
		require(LocalScmSource.narrowSnapshot(snapshot, ["web/"]).groups.length == 0, "an unchanged folder showed changes");
		require(LocalScmSource.identityFor(["C:/"], true) != LocalScmSource.identityFor(["C:/"]), "narrowed source shares the workspace source's identity");
	}

	static function operationText(operation:Null<ScmOperation>):String return operation == null ? "null" : Std.string(operation);

	static function allowed(narrowed:NarrowedOperation):Null<ScmOperation>
		return switch narrowed { case Allowed(operation): operation; case Refused(_): null; };

	static function refusal(narrowed:NarrowedOperation):Null<String>
		return switch narrowed { case Allowed(_): null; case Refused(reason): reason; };

	/** Writes from narrowed Changes act only inside the group's folder; a commit never takes staged files from outside it. */
	static function narrowedOperations():Void {
		var head = new ScmHead("main", null, false, null, 0, 0, false, ScmHeadOperation.None);
		var inside = new ScmSnapshot(Int64.make(0, 7), head, [
			new ScmGroup(ScmGroupId.Index, [resource("graphical/src/A.hx", ScmChangeKind.Modified)]),
			new ScmGroup(ScmGroupId.WorkingTree, [resource("README.md", ScmChangeKind.Modified)])]);
		var folders = ["graphical/"];
		var all = LocalScmSource.narrowOperation(ScmOperation.StageAll, folders, inside);
		require(operationText(allowed(all)) == operationText(ScmOperation.StagePaths(["graphical"])), "stage-all was not limited to the folder");
		var none = LocalScmSource.narrowOperation(ScmOperation.UnstageAll, folders, inside);
		require(operationText(allowed(none)) == operationText(ScmOperation.UnstagePaths(["graphical"])), "unstage-all was not limited to the folder");
		for (operation in [ScmOperation.Stage("README.md"), ScmOperation.Discard("src/B.hx"), ScmOperation.Unstage("graphicalish/x"),
			ScmOperation.StagePaths(["graphical/a", "README.md"]), ScmOperation.RevertPatch("docs/x.md", haxe.io.Bytes.alloc(0))]) {
			var reason = refusal(LocalScmSource.narrowOperation(operation, folders, inside));
			require(reason != null && reason.indexOf("outside graphical/") >= 0, "an operation outside the folder was allowed: " + operationText(operation));
		}
		// Paths that start inside the folder but are not plain could name files outside it.
		for (operation in [ScmOperation.Stage("graphical/../README.md"), ScmOperation.Discard("graphical/./../src/B.hx"),
			ScmOperation.StagePaths(["graphical/a", "graphical\\..\\README.md"]), ScmOperation.Unstage("/graphical/a"),
			ScmOperation.Stage("C:/repo/graphical/a"), ScmOperation.Stage("c:graphical/a"), ScmOperation.Stage(":(top)graphical/a"),
			ScmOperation.Stage("")]) {
			var reason = refusal(LocalScmSource.narrowOperation(operation, folders, inside));
			require(reason != null && reason.indexOf("not a plain path") >= 0, "a path that is not plain was allowed: " + operationText(operation));
		}
		var stage = LocalScmSource.narrowOperation(ScmOperation.Discard("graphical/src/A.hx"), folders, inside);
		require(operationText(allowed(stage)) == operationText(ScmOperation.Discard("graphical/src/A.hx")), "an operation inside the folder changed");
		var commit = LocalScmSource.narrowOperation(ScmOperation.Commit("m", false), folders, inside);
		require(operationText(allowed(commit)) == operationText(ScmOperation.ScopedCommit("m", false, folders)),
			"a commit of the folder's own staged changes was not passed on as a folder-scoped commit");
		var amend = LocalScmSource.narrowOperation(ScmOperation.Commit("m", true), folders, inside);
		require(operationText(allowed(amend)) == operationText(ScmOperation.ScopedCommit("m", true, folders)), "an amend was not scoped to the folder");
		var mixed = new ScmSnapshot(Int64.make(0, 8), head, [new ScmGroup(ScmGroupId.Index, [resource("graphical/src/A.hx", ScmChangeKind.Modified),
			resource("README.md", ScmChangeKind.Modified)])]);
		var outsideError = refusal(LocalScmSource.narrowOperation(ScmOperation.Commit("m", true), folders, mixed));
		require(outsideError != null && outsideError.indexOf("README.md") >= 0, "a commit took staged changes from outside the folder");
		var moved = new ScmSnapshot(Int64.make(0, 9), head, [new ScmGroup(ScmGroupId.Index, [resource("graphical/New.hx", ScmChangeKind.Renamed, "src/Old.hx")])]);
		require(allowed(LocalScmSource.narrowOperation(ScmOperation.Commit("m", false), folders, moved)) == null, "a commit took a rename from outside the folder");
		var truncated = new ScmSnapshot(Int64.make(0, 10), head, [], true);
		require(allowed(LocalScmSource.narrowOperation(ScmOperation.Commit("m", false), folders, truncated)) == null
			&& allowed(LocalScmSource.narrowOperation(ScmOperation.Commit("m", false), folders, null)) == null, "a commit went ahead without a complete snapshot");
		require(allowed(LocalScmSource.narrowOperation(ScmOperation.Push, folders, mixed)) != null, "a repository-wide operation was refused");
	}

	/** Folder matching follows the repository's core.ignorecase, not the machine's. */
	static function folderCase():Void {
		var head = new ScmHead("main", null, false, null, 0, 0, false, ScmHeadOperation.None);
		var index = new ScmSnapshot(Int64.make(0, 7), head, [new ScmGroup(ScmGroupId.Index, [resource("Sub/x.txt", ScmChangeKind.Modified)])]);
		require(refusal(LocalScmSource.narrowOperation(ScmOperation.Stage("Sub/x.txt"), ["sub/"], index, false)) != null,
			"a case-sensitive repository let Sub/ match its sibling sub/");
		require(allowed(LocalScmSource.narrowOperation(ScmOperation.Stage("Sub/x.txt"), ["sub/"], index, true)) != null,
			"a case-insensitive repository refused another spelling of its folder");
		require(refusal(LocalScmSource.narrowOperation(ScmOperation.Commit("m", false), ["sub/"], index, false)) != null,
			"a case-sensitive commit took Sub/ for sub/");
		require(LocalScmSource.narrowSnapshot(index, ["sub/"], false).groups.length == 0
			&& LocalScmSource.narrowSnapshot(index, ["sub/"], true).groups.length == 1, "snapshot narrowing ignored core.ignorecase");
		require(ScmFolderScope.outside(["sub/a", "Sub/b", "sub/../c"], ["sub/"], false).join(",") == "Sub/b,sub/../c", "folder scope outside list");
		require(GitConfigFile.boolean("[core]\n\tignorecase = true\n", "core", "ignorecase") == true, "config true");
		require(GitConfigFile.boolean("[Core]\n\tIgnoreCase = false ; comment\n", "core", "ignorecase") == false, "config false with a comment");
		require(GitConfigFile.boolean("[core]\n\tignorecase\n[core]\nignorecase=no\n", "core", "ignorecase") == false, "the last value wins");
		require(GitConfigFile.boolean("[core \"x\"]\nignorecase=true\n[user]\nignorecase=true\n", "core", "ignorecase") == null, "a subsection or another section counted");
	}

	static function modeHiding():Void {
		require(LayoutMode.Agents.hides("files") && LayoutMode.Agents.hides("search") && LayoutMode.Agents.hides("scm"), "Agents shows an editor destination");
		require(!LayoutMode.Agents.hides("workbench") && !LayoutMode.Agents.hides(null), "Agents hides its own destination");
		require(LayoutMode.Editor.hiddenDestinations.length == 0, "Editor hides a destination");
	}

	static function main():Int {
		scopeRule();
		tracker();
		rowKeys();
		groupLabels();
		groupRemoval();
		narrowedChanges();
		narrowedOperations();
		folderCase();
		modeHiding();
		trace("PASS: Agents scope from group, sub-group, session and terminal rows; last-group and deleted-group fallback; row keys; group labels; Remove Group; folder-narrowed changes and writes; mode-hidden rail destinations");
		return 0;
	}
}
