package view;

import style.Theme;
import workspace.ProjectNode;
import workspace.Workspace;

class Sidebar {
	public static inline final WIDTH = 220;
	public static inline final HEADER_HEIGHT = 42;
	public static inline final ROW_HEIGHT = 22;
	public final workspace:Workspace;
	public var width:Int;
	public var selected(default, null):Int = 0;

	public function new(workspace:Workspace, width:Int = WIDTH) {
		this.workspace = workspace;
		this.width = width;
	}

	public function nodes():Array<ProjectNode> {
		var project = workspace.activeProject;
		return project == null ? [] : project.visibleNodes();
	}

	public function selectBy(delta:Int):Bool {
		var visible = nodes();
		if (visible.length == 0) return false;
		selected += delta;
		if (selected < 0) selected = 0;
		if (selected >= visible.length) selected = visible.length - 1;
		return true;
	}

	public function activate():Null<String> {
		var visible = nodes();
		if (selected < 0 || selected >= visible.length) return null;
		var node = visible[selected], project = workspace.activeProject;
		if (node.directory) {
			if (project != null) project.toggle(node);
			return null;
		}
		return node.path;
	}

	public function activeNode():Null<ProjectNode> {
		var visible = nodes();
		return selected < 0 || selected >= visible.length ? null : visible[selected];
	}

	public function selectPath(path:String):Bool {
		var visible = nodes();
		for (index in 0...visible.length)
			if (visible[index].path == path) {
				selected = index;
				return true;
			}
		return false;
	}

	public function mouseDown(x:Int, y:Int):Null<String> {
		if (!selectAt(x, y)) return null;
		return activate();
	}

	public function selectAt(x:Int, y:Int):Bool {
		if (x < 0 || x >= width || y < HEADER_HEIGHT) return false;
		var index = Std.int((y - HEADER_HEIGHT) / ROW_HEIGHT), visible = nodes();
		if (index < 0 || index >= visible.length) return false;
		selected = index;
		return true;
	}

	public function draw(renderer:renderer.Renderer, theme:Theme, height:Int):Void {
		renderer.clip(0, 0, width, height);
		renderer.rect(0, 0, width, height, theme.surface);
		renderer.text(16, 13, "EXPLORER", theme.foregroundMuted);
		var visible = nodes(), maxRows = Std.int((height - HEADER_HEIGHT) / ROW_HEIGHT);
		if (maxRows > visible.length) maxRows = visible.length;
		for (index in 0...maxRows) {
			var node = visible[index], y = HEADER_HEIGHT + index * ROW_HEIGHT;
			if (index == selected) renderer.rect(0, y, width, ROW_HEIGHT, theme.surfaceActive);
			var marker = node.directory ? (node.expanded ? "v " : "> ") : "  ", indent = node.depth * 14;
			renderer.text(10 + indent, y + 3, marker + node.name, node.directory ? theme.foregroundMuted : theme.editorForeground);
		}
		renderer.clip(0, 0, width, height);
	}
}
