package ui;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.widgets.Icon;
import haxeon.ui.icons.IconName;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import editor.Document;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;

/** Project-relative file path, kept above the editor's scrolling content. */
class EditorBreadcrumbs implements View {
	final document:Document;
	final projectRoot:Null<String>;
	final foreground:Color;
	final background:Color;
	final dark:Bool;
	final onNavigate:(String, UiEvent)->Void;

	public function new(document:Document, projectRoot:Null<String>, foreground:Color, background:Color, dark:Bool, onNavigate:(String, UiEvent)->Void) {
		this.document = document;
		this.projectRoot = projectRoot;
		this.foreground = foreground;
		this.background = background;
		this.dark = dark;
		this.onNavigate = onNavigate;
	}

	public function build(context:BuildContext):RenderNode {
		var atlas = context.resourceState(context.id("breadcrumb-icons"), function() return new SetiIconAtlas(),
			function(value) value.dispose()).value;
		var row = new RetainedView("breadcrumb-path:" + document.id,
			function(_) return buildPath(atlas), function() {
				var path = document.path == null ? "" : document.path;
				var root = projectRoot == null ? "" : projectRoot;
				return path.length + ":" + path + root.length + ":" + root +
					document.title.length + ":" + document.title + ":" + dark + ":" +
					foreground.red + ":" + foreground.green + ":" + foreground.blue + ":" +
					foreground.alpha + ":" + context.animations.revision;
			});
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(28);
		style.background = background;
		var scroll = new ScrollView("editor-breadcrumbs:" + document.id, row, style, ScrollAxis.Horizontal);
		scroll.showScrollbar = false;
		return scroll.build(context);
	}

	function buildPath(atlas:SetiIconAtlas):View {
		var path = document.path == null ? document.title : StringTools.replace(document.path, "\\", "/");
		if (document.path != null && projectRoot != null) {
			var root = StringTools.replace(projectRoot, "\\", "/");
			while (root.length > 1 && StringTools.endsWith(root, "/")) root = root.substr(0, root.length - 1);
			var prefix = root == "/" ? root : root + "/";
			if (StringTools.startsWith(path, prefix)) path = path.substr(prefix.length);
		}
		var children:Array<View> = [];
		var fullPath = document.path == null ? "" : StringTools.replace(document.path, "\\", "/");
		var accumulated = fullPath.substr(0, fullPath.length - path.length);
		if (accumulated.length == 0 && StringTools.startsWith(fullPath, "/")) accumulated = "/";
		for (part in path.split("/")) {
			if (part.length == 0) continue;
			if (children.length > 0) children.push(new Icon("separator:" + children.length, IconName.ChevronRight, 14, foreground));
			accumulated += part;
			var target = accumulated;
			if (target == fullPath && document.path != null) children.push(new SetiFileIcon(atlas, document.title, dark));
			children.push(new BreadcrumbLabel(part, foreground, document.path == null ? null : function(event) onNavigate(target, event)));
			accumulated += "/";
		}
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.fit();
		rowStyle.height = LayoutAxis.fixed(28);
		rowStyle.padding = new Insets(12, 0, 12, 0);
		rowStyle.childGap = 5;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		return new Row("breadcrumb-path:" + document.id,
			[for (index in 0...children.length) new haxeon.ui.widgets.KeyedView("crumb:" + index, children[index])], rowStyle);
	}
}

private class BreadcrumbLabel implements View {
	final label:String;
	final color:Color;
	final onClick:Null<UiEvent->Void>;
	public function new(label:String, color:Color, onClick:Null<UiEvent->Void>) {
		this.label = label; this.color = color; this.onClick = onClick;
	}
	public function build(context:BuildContext):RenderNode {
		var node = new Text(label, null, color, new TextStyleOverride(null, 14, null, TextWrap.None)).build(context);
		var activate = onClick;
		if (activate != null) {
			node.on(UiEventKind.Click, function(event) { if (event.button == 0) activate(event); });
			node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Button, label);
			node.focusable = true;
			node.on(UiEventKind.KeyDown, function(event) {
				if (event.key == haxeon.ui.core.UiKey.Enter || event.key == haxeon.ui.core.UiKey.Space) { activate(event); event.preventDefault(); }
			});
		}
		return node;
	}
}
