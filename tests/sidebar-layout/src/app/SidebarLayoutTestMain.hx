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
		trace("PASS: shared sidebar width, legacy migration, deferred registration, atomic persistence, aligned shared header metrics, narrow clipping and selected-tab reveal through resize");
		return 0;
	}
 static function checkHeaderAlignment(fonts:haxeon.ui.FontCollection):Void {
  for (dark in [false, true]) for (width in [180.0, 300.0]) for (height in [36.0, 44.0]) {
   var theme = ui.ExosuitPalette.theme(dark);
   theme.tokens.tabHeaderHeight = height;
   theme.tokens.tabHeaderFontSize = height == 36 ? 14 : 18;
   var context = new haxeon.ui.core.UiContext(null, fonts, theme);
   var fixture = new AlignedHeadersFixture(width);
   var frame = new haxeon.ui.LayoutFrame(width * 3, 240);
   var root:haxeon.ui.core.RenderNode = null;
   for (_ in 0...4) root = context.submit(fixture, frame);
   var panes = 0;
   root.walk(function(node) {
    if (node.semantics == null || node.semantics.role != haxeon.ui.semantics.AccessibilityRole.TabList) return;
    panes++;
    var bounds = node.globalBounds(), header = node.children[0].globalBounds(), panel = node.children[1].globalBounds();
    require(Math.abs(header.height - height) < 0.01, "tab header height differs between sidebar, editor and bottom panel");
    require(Math.abs(panel.y - bounds.y - height) < 0.01, "tab content has a gap below its header");
    node.walk(function(tab) {
     if (tab.semantics == null || tab.semantics.role != haxeon.ui.semantics.AccessibilityRole.Tab) return;
     var button = tab.globalBounds();
     require(Math.abs(button.height - height) < 0.01 && Math.abs(button.y - bounds.y) < 0.01,
      "tab background does not fill its header");
     tab.walk(function(label) {
      if (label.layout.text == null || label.layout.text.length == 0) return;
      require(label.layout.textStyle.fontSize == theme.tokens.tabHeaderFontSize, "tab font diverged from shared metrics");
      var text = label.globalBounds();
      require(Math.abs(text.y + text.height / 2 - button.y - button.height / 2) < 0.1, "tab text is not vertically centered");
     });
    });
   });
   require(panes == 3, "missing header alignment coverage");
   var selected:haxeon.ui.core.RenderNode = null;
   root.walk(function(node) { if (node.styleKey == "editor-Terminal 9") selected = node; });
   var selectedBounds = selected.globalBounds();
   context.pointerMove(selectedBounds.x + selectedBounds.width / 2, selectedBounds.y + selectedBounds.height / 2);
   for (_ in 0...2) root = context.submit(fixture, frame);
   var close:haxeon.ui.core.RenderNode = null;
   root.walk(function(node) { if (node.styleKey == "tab-close:editor-Terminal 9") close = node; });
   var closeGeometry = close == null ? null : close.resolved;
   require(closeGeometry != null && closeGeometry.visible, "tab close target did not appear on hover");
   var closeBounds = close.globalBounds();
   require(Math.abs(closeBounds.y + closeBounds.height / 2 - height / 2) < 0.1,
    "close target is not centered beside the tab label");
   context.pointerDown(closeBounds.x + closeBounds.width / 2, closeBounds.y + closeBounds.height / 2, 0);
   context.pointerUp(closeBounds.x + closeBounds.width / 2, closeBounds.y + closeBounds.height / 2, 0);
   require(fixture.closes == 1, "compact tab close target stopped responding");
   context.dispose();
  }
 }

 static function checkNarrowLayout():Void {
  var fonts = haxeon.ui.FontCollection.create();
  fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  checkHeaderAlignment(fonts);
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
    require(root.layout.style.clipHorizontal, "sidebar missing pane clipping");
    var found = false;
    function visit(node:haxeon.ui.core.RenderNode):Void {
     if (node.resolved != null) {
      var clip = node.resolved.clipBounds;
      require(!node.containsGlobalPoint(new haxeon.ui.Point(width + 1, 60)), "sidebar hit testing escaped pane");
      // Fully clipped floating accents may retain an offscreen origin with no area.
     if (clip.width > 0 && clip.height > 0)
      require(clip.x >= -0.1 && clip.x + clip.width <= width + 0.1, "sidebar descendant clip escaped pane: " + node.styleKey);
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

private class AlignedHeadersFixture implements haxeon.ui.core.View {
 final width:Float;
 public var closes = 0;
 final sidebar = new haxeon.ui.widgets.sidebar.SidebarModel();
 public function new(width:Float) {
  this.width = width;
  for (name in ["Files", "Search"]) sidebar.register(name,
   function() return new haxeon.ui.widgets.text.Text("Sidebar content"),
   new haxeon.ui.widgets.sidebar.SidebarModeOptions(name));
 }
 function items(prefix:String):Array<haxeon.ui.widgets.controls.TabItem> {
  var result = [for (name in ["One", "Two", "Terminal 9"])
   new haxeon.ui.widgets.controls.TabItem(prefix + name, name, new haxeon.ui.widgets.text.Text("Panel content"))];
  result[2].onClose = function() closes++;
  return result;
 }
 function action(key:String):haxeon.ui.core.View {
  var style = new haxeon.ui.LayoutStyle();
  style.width = haxeon.ui.LayoutAxis.fixed(24); style.height = haxeon.ui.LayoutAxis.fixed(24);
  return new haxeon.ui.widgets.controls.IconButton(key, haxeon.ui.icons.IconName.Plus, "Header action", null, style);
 }
 public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
  var sidebarView = new haxeon.ui.widgets.sidebar.SidebarHost("aligned-sidebar", sidebar, function(id) sidebar.select(id));
  sidebarView.headerActions = function(_) return action("sidebar-action");
  var editor = new haxeon.ui.widgets.controls.Tabs("aligned-editor", items("editor-"), "editor-Terminal 9");
  var editorView = new ui.EditorTabsView(editor, new Map<String, String>(), false);
  var bottom = new haxeon.ui.widgets.controls.Tabs("aligned-bottom", items("bottom-"), "bottom-Terminal 9");
  bottom.headerTrailing = action("bottom-action");
  var views:Array<haxeon.ui.core.View> = [sidebarView, editorView, bottom];
  var style = new haxeon.ui.LayoutStyle();
  style.width = haxeon.ui.LayoutAxis.grow(); style.height = haxeon.ui.LayoutAxis.grow();
  return new haxeon.ui.widgets.layout.Row("aligned-headers", [for (i in 0...views.length)
   new haxeon.ui.widgets.KeyedView("pane-" + i, new haxeon.ui.widgets.layout.SizedBox("pane", views[i],
    haxeon.ui.LayoutAxis.fixed(width), haxeon.ui.LayoutAxis.grow()))], style).build(context);
 }
}
