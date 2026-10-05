package app;

class SidebarLayoutTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var sidebar = new haxeon.ui.widgets.sidebar.SidebarModel();
		sidebar.register("files", function() return new haxeon.ui.widgets.text.Text("Files"), new haxeon.ui.widgets.sidebar.SidebarModeOptions("Files"));
		sidebar.register("search", function() return new haxeon.ui.widgets.text.Text("Search"), new haxeon.ui.widgets.sidebar.SidebarModeOptions("Search"));
		require(sidebar.restore("1|search|0|files,240,1;search,370,1"), "legacy layout rejected");
		require(sidebar.width == 370 && !sidebar.visible, "migration lost active width or visibility");
		sidebar.select("files"); require(sidebar.width == 370, "switch restored a destination width");
		sidebar.rememberWidth(410); sidebar.select("search");
		require(sidebar.width == 410, "resize did not carry across destinations");
		var restored = new haxeon.ui.widgets.sidebar.SidebarModel();
		require(restored.restore(sidebar.encode()) && restored.width == 410, "shared width did not round trip");
		var before = restored.encode();
		for (invalid in ["2|search|1|NaN|", "2|search|1|20|", "2|search|1|410|files,1;files,0", "1|search|1|search,320oops,1"])
			require(!restored.restore(invalid) && restored.encode() == before, "invalid layout changed saved state");
		require(restored.restore("1|agents|1|agents,480,1;files,220,1"), "deferred destination migration failed");
		restored.register("agents", function() return new haxeon.ui.widgets.text.Text("Agents"), new haxeon.ui.widgets.sidebar.SidebarModeOptions("Agents"));
		require(restored.width == 480 && restored.activeId == "agents", "late destination registration changed migrated width");

		trace("PASS: shared sidebar width, legacy migration, deferred registration, atomic persistence");
		return 0;
	}
}
