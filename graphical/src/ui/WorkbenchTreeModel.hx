package ui;

import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.text.Text;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** Projection only: grouping/status belong to the service, expansion/selection to TreeView. */
class WorkbenchTreeModel implements TreeViewModel {
	public final groups:Map<String, WorkspaceGroup> = [];
	public final agents:Map<String, workspace.service.WorkspaceAgentProtocol.AgentRecord> = [];
	public final terminals:Map<String, TerminalRecord> = [];

	final children:Map<String, Array<String>> = [];
	final roots:Array<String> = [];
	var version:Int = 0;
	public var groupEditor:Null<String->Null<View>>;
	var workspaceRoot:Null<String>;

	public function new() {}

	public function update(catalog:Null<TerminalCatalog>, ?agentCatalog:workspace.service.WorkspaceAgentProtocol.AgentCatalog, ?draft:WorkspaceGroup):Void {
		agents.clear();
		groups.clear();
		terminals.clear();
		children.clear();
		roots.resize(0);
		version++;
		workspaceRoot = catalog == null ? null : catalog.workspaceRoot;
		if (catalog == null)
			return;
		var ordered = catalog.groups.copy();
        if (draft != null && !Lambda.exists(ordered, function(g) return g.id == draft.id)) ordered.push(draft);
		ordered.sort(function(a, b) {
			var order = WorkspaceProtocol.order(a.order) - WorkspaceProtocol.order(b.order);
			return order == 0 ? Reflect.compare(a.id, b.id) : order;
		});
		for (g in ordered) {
			groups.set(g.id, g);
			children.set("g:" + g.id, []);
		}
		for (g in ordered) {
			var siblings = g.parent == null ? roots : children.get("g:" + g.parent);
			if (siblings != null)
				siblings.push("g:" + g.id);
		}
		for (t in catalog.terminals) {
			terminals.set(t.id, t);
			var siblings = children.get("g:" + t.group);
			if (siblings != null)
				siblings.push("t:" + t.id);
		}
		if (agentCatalog != null)
			for (a in agentCatalog.records) {
				agents.set(a.id, a);
				var siblings = children.get("g:" + a.group);
				if (siblings != null)
					siblings.push("a:" + a.id);
			}
	}

	public function rootCount():Int
		return roots.length;

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return [
			for (index in start...Std.int(Math.min(roots.length, start + count)))
				new TreeRootMetadata(roots[index], true)
		];

	public function rootKeyAt(index:Int):String
		return roots[index];

	public function childCount(key:String):Int {
		var items = children.get(key);
		return items == null ? 0 : items.length;
	}

	public function childKeyAt(key:String, index:Int):String {
		var items = children.get(key);
		if (items == null)
			throw "Unknown tree branch";
		return items[index];
	}

	public function initiallyExpanded(key:String):Bool
		return roots.indexOf(key) >= 0;

	public function estimatedExtent():Float
		return 30;

	public function extentIsUniform():Bool
		return true;

	public function extentAt(key:String):Float
		return 30;

	public function revision():Int
		return version;

	static function agentStateLabel(state:String):String {
		return switch (state) {
			case "reconnecting": "Reconnecting…";
			case "reconnect-failed": "Session unavailable";
			case "disconnected": "Disconnected";
			default: state;
		};
	}

	public function buildItem(key:String):View {
		if (StringTools.startsWith(key, "g:")) {
            var editing = groupEditor == null ? null : groupEditor(key.substring(2));
            if (editing != null) return editing;
			var group = groups.get(key.substring(2));
			if (group == null)
				return new Text("");
			var running = 0;
			for (t in terminals) {
				var parent:Null<String> = t.group;
				while (parent != null) {
					if (parent == group.id) {
						if (t.state == "running")
							running++;
						break;
					}
					var ancestor = groups.get(parent);
					parent = ancestor == null ? null : ancestor.parent;
				}
			}
			return new WorkbenchGroupLabel(group.name, directory(group), workspaceRoot, running);
		}
		if (StringTools.startsWith(key, "a:")) {
			var a = agents.get(key.substring(2));
			return new Text(a == null ? "" : a.name + " · " + agentStateLabel(a.state));
		}
		var terminal = terminals.get(key.substring(2));
		return new Text(terminal == null ? "" : terminal.name + " · " + terminal.state);
	}

	public function directory(group:WorkspaceGroup):Null<String> {
		var current:Null<WorkspaceGroup> = group;
		while (current != null) {
			if (current.cwd != null)
				return current.cwd;
			current = current.parent == null ? null : groups.get(current.parent);
		}
		return workspaceRoot;
	}

	public function nextOrder(parent:Null<String>):Int {
		var next = 0;
		for (g in groups)
			if (g.parent == parent)
				next = Std.int(Math.max(next, WorkspaceProtocol.order(g.order) + 1));
		return Std.int(Math.min(1000000, next));
	}
}
