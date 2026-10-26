package ui;

/** A presentation preset; it never changes workspace/context identity or behavior. */
class LayoutMode {
	public final id:String;
	public final label:String;
	public final sidebarOrder:Array<String>;
	public final selectedSidebar:String;
	public final left:Bool;
	public final bottom:Bool;
	public final right:Bool;
	public function new(id:String, label:String, order:Array<String>, selected:String, left:Bool, bottom:Bool, right:Bool) {
		this.id = id; this.label = label; sidebarOrder = order; selectedSidebar = selected;
		this.left = left; this.bottom = bottom; this.right = right;
	}
	public static final Editor = new LayoutMode("editor", "Editor", ["files", "search", "scm", "workbench"], "files", true, false, false);
	public static final Agents = new LayoutMode("agents", "Agents", ["workbench", "files", "search", "scm"], "workbench", true, false, true);
	public static function find(id:String):Null<LayoutMode> return id == "editor" ? Editor : id == "agents" ? Agents : null;
}
