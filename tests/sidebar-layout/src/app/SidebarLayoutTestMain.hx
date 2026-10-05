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

		checkNarrowLayout();
		trace("PASS: shared sidebar width, legacy migration, deferred registration, atomic persistence, narrow clipping and selected-tab reveal through resize");
		return 0;
	}
 static function checkNarrowLayout():Void {
  var fonts = haxeon.ui.FontCollection.create();
  fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var session = haxeon.ui.LayoutSession.create();
  var context = new haxeon.ui.core.UiContext(session, fonts);
  var model = new haxeon.ui.widgets.sidebar.SidebarModel();
  for (name in ["Files", "Search", "Workbench"])
   model.register(name, function() return new haxeon.ui.widgets.text.Text("Long content extending well beyond this narrow sidebar"), new haxeon.ui.widgets.sidebar.SidebarModeOptions(name));
  var host = new haxeon.ui.widgets.sidebar.SidebarHost("narrow-sidebar", model, function(id) model.select(id));
  for (width in [124.0, 240.0, 90.0]) {
   for (name in ["Files", "Search", "Workbench"]) {
    model.select(name);
    var root:haxeon.ui.core.RenderNode = null;
    for (_ in 0...3) root = context.submit(host, new haxeon.ui.LayoutFrame(width, 180));
    require(root.layout.style.clipHorizontal && root.layout.style.clipVertical, "sidebar missing pane clipping");
    var found = false;
    function visit(node:haxeon.ui.core.RenderNode):Void {
     if (node.resolved != null) {
      var clip = node.resolved.clipBounds;
      require(!node.containsGlobalPoint(new haxeon.ui.Point(width + 1, 60)), "sidebar hit testing escaped pane");
      require(clip.x >= -0.1 && clip.x + clip.width <= width + 0.1, "sidebar descendant clip escaped pane");
     }
     if (node.semantics != null && node.semantics.label == name) {
      var bounds = node.globalBounds();
      require(bounds.x >= -0.1 && bounds.x + Math.min(bounds.width, width) <= width + 0.1, "selected sidebar tab not revealed: " + name + " width=" + width + " bounds=" + bounds.x + "," + bounds.width);
      found = true;
     }
     for (child in node.children) visit(child);
    }
    visit(root);
    require(found, "selected sidebar header missing");
   }
  }
  context.dispose(); session.dispose(); fonts.dispose();
 }

}
