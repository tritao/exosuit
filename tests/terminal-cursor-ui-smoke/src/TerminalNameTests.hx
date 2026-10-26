import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import ui.TerminalPanel;
import ui.UiTerminalTab;

private class NamedPanel implements TerminalPanel {
	public var name:Null<String>;
	public function new() {}
	public function poll():Void {}
	public function workspaceName():Null<String> return name;
	public function terminate(force:Bool):Void {}
	public function close():Void {}
	public function status():String return "running";
	public function columns():Int return 80;
	public function rows():Int return 24;
	public function build(context:BuildContext):RenderNode throw "Not rendered";
}

class TerminalNameTests {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	public static function run():Void {
		var panel = new NamedPanel();
		var created = new UiTerminalTab("view-1", "Terminal", "/one", panel, true, "resource", "/one");
		require(!created.poll() && created.title == "Terminal", "Pending creation invented a numbered name");
		panel.name = "Terminal 1";
		require(created.poll() && created.title == panel.name, "Creation did not adopt the attachment name");
		require(!created.poll(), "Unchanged name invalidated the UI");
		created.updateWorkspaceName("Renamed shell");
		created.poll();
		require(created.title == "Renamed shell", "Stale attachment metadata overwrote a catalog rename");
		var restored = new UiTerminalTab("view-2", "Terminal 3", "/two", panel, true, "resource", "/two");
		require(restored.poll() && restored.title == "Terminal 1", "Restored stale title was not reconciled");
		created.updateWorkspaceName("Terminal 1");
		require(created.title == restored.title, "Different workspaces must retain duplicate service names");
		require(!restored.updateWorkspaceName(null) && !restored.updateWorkspaceName(" ")
			&& restored.title == "Terminal 1", "Missing legacy metadata erased a known name");
		var local = new UiTerminalTab("local", "Terminal 2", "/one", panel);
		require(!local.poll() && local.title == "Terminal 2", "Workspace metadata renamed a local terminal");
	}
}
