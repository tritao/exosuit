package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.widgets.text.TextSelection;

/** One inline editing session; the controller owns the filesystem operation. */
class ExplorerRename implements View {
	public final path:String;
	public final directory:Bool;
	final fontSize:Float;
	public var revision(default, null):Int = 0;
	var name:String;
	var focusPending:Bool = true;
	var selectName:Bool = true;
	final selectionEnd:Int;
	final rename:String->Bool;
	final done:Null<String>->Void;
	final changed:Void->Void;
	final report:String->Void;

	public function new(path:String, directory:Bool, rename:String->Bool, done:Null<String>->Void,
		changed:Void->Void, report:String->Void, fontSize:Float = 15) {
		this.path = path;
		this.directory = directory;
		this.fontSize = fontSize;
		name = haxe.io.Path.withoutDirectory(path);
		var dot = name.lastIndexOf(".");
		selectionEnd = new haxeon.editor.TextDocument(directory || dot <= 0 ? name : name.substring(0, dot)).codepointCount;
		this.rename = rename;
		this.done = done;
		this.changed = changed;
		this.report = report;
	}

	function submit():Void {
		if (StringTools.trim(name).length == 0 || name == "." || name == ".." || name.indexOf("/") >= 0 || name.indexOf("\\") >= 0) {
			report("Enter a valid file or folder name without path separators.");
			return;
		}
		var destination = haxe.io.Path.join([haxe.io.Path.directory(path), name]);
		if (destination == path) { done(null); return; }
		if (rename(destination)) done(destination);
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("explorer-rename:" + path), function() {
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.height = LayoutAxis.fixed(Math.max(24, Math.ceil(fontSize * 1.4 + 2)));
			style.padding = new Insets(3, 0, 3, 0);
			style.background = context.theme.tokens.selectionField;
			var field = new TextField("name", name, function(value) {
				name = value; selectName = false; revision++; changed();
			}, style, "Rename file or folder", new TextStyle(fontSize), context.theme.tokens.textPrimary);
			if (selectName) field.selectionProvider = function() return new TextSelection(0, selectionEnd);
			field.onSelectionChange = function(_) selectName = false;
			field.onSubmit = function(_) submit();
			var node = field.build(context);
			if (focusPending) { context.requestFocusAfterLayout(node.id); focusPending = false; }
			node.on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape) {
					done(null); event.preventDefault();
					var row = node.parent;
					while (row != null && !row.focusable) row = row.parent;
					if (row != null) context.requestFocusAfterLayout(row.id);
				}
				event.stopPropagation();
			});
			node.on(UiEventKind.KeyRepeat, function(event) event.stopPropagation());
			node.on(UiEventKind.Click, function(event) event.stopPropagation());
			node.on(UiEventKind.PointerDown, function(event) event.stopPropagation());
			node.on(UiEventKind.Blur, function(_) done(null));
			node.on(UiEventKind.FocusLost, function(_) done(null));
			return node;
		});
	}
}
