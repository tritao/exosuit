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
	/** Activity Rail destinations this mode leaves out; separate from the user's own shown/hidden choices. */
	public final hiddenDestinations:Array<String>;
	public function new(id:String, label:String, order:Array<String>, selected:String, left:Bool, bottom:Bool, right:Bool,
			?hidden:Array<String>) {
		this.id = id; this.label = label; sidebarOrder = order; selectedSidebar = selected;
		this.left = left; this.bottom = bottom; this.right = right;
		hiddenDestinations = hidden == null ? [] : hidden.copy();
	}
	public function hides(destination:Null<String>):Bool return destination != null && hiddenDestinations.indexOf(destination) >= 0;
	public static final Editor:LayoutMode = new LayoutMode("editor", "Editor", ["files", "search", "scm", "workbench"], "files", true, false, false);
	/** The right panel's Files, Search and Changes follow the selected group, so the rail drops the editor workspace's. */
	public static final Agents:LayoutMode = new LayoutMode("agents", "Agents", ["workbench", "files", "search", "scm"], "workbench", true, false, true,
		["files", "search", "scm"]);
	public static function find(id:String):Null<LayoutMode> return id == "editor" ? Editor : id == "agents" ? Agents : null;
}
