package app;

import haxe.Int64;
import haxe.io.Bytes;
import scm.LocalScmSource;
import scm.ScmChangeKind;
import scm.ScmGroup;
import scm.ScmGroupId;
import scm.ScmHead;
import scm.ScmHeadOperation;
import scm.ScmResource;
import scm.ScmSnapshot;
import ui.AgentScope;
import ui.LayoutMode;
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
		// A deleted group keeps its last scope rather than jumping elsewhere.
		var removed = model([group("resume", "resume-2026", "C:/work/exosuit", null, 0)]);
		var orphan = AgentScope.resolve(removed, null, ui);
		require(orphan != null && orphan.equals(ui), "deleting the scoped group changed the scope");
		// No groups at all: no scope.
		require(AgentScope.resolve(new WorkbenchTreeModel(), null, null) == null, "empty Workbench produced a scope");
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

	static function modeHiding():Void {
		require(LayoutMode.Agents.hides("files") && LayoutMode.Agents.hides("search") && LayoutMode.Agents.hides("scm"), "Agents shows an editor destination");
		require(!LayoutMode.Agents.hides("workbench") && !LayoutMode.Agents.hides(null), "Agents hides its own destination");
		require(LayoutMode.Editor.hiddenDestinations.length == 0, "Editor hides a destination");
	}

	static function main():Int {
		scopeRule();
		narrowedChanges();
		modeHiding();
		trace("PASS: Agents scope from group, sub-group, session and terminal rows; last-group fallback; folder-narrowed changes; mode-hidden rail destinations");
		return 0;
	}
}
