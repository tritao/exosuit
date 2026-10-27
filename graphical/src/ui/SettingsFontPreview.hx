package ui;

import haxeon.ui.*;
import haxeon.ui.core.*;
import haxeon.ui.widgets.text.Text;

/** A separate font collection previews a file without changing application fonts. */
class SettingsFontPreview implements View {
	final path:String;
	final size:Float;
	public function new(path:String, size:Float) { this.path = path; this.size = size; }
	public function build(context:BuildContext):RenderNode {
		if (path == "") return new Text("Font preview uses the application default when no file is selected.").build(context);
		var resource = context.resourceState(context.id("settings-font-preview"),
			function() return new PreviewFont(), function(font) font.dispose()).value;
		resource.update(path, size);
		if (resource.error != null) return new Text(resource.error).build(context);
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(size * 3.2 + 12);
		style.clipHorizontal = true; style.clipVertical = true;
		var node = new RenderNode(context.id("font-preview"), LayoutVisualKind.Custom, style);
		resource.setColor(context.theme.tokens.textPrimary);
		node.layout.intrinsicContent = resource.content;
		node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Text,
			"Font preview at " + size + " pixels: The quick brown fox. 0123456789 {} [] => !=");
		return node;
	}
}

private class PreviewFont {
	public var error:Null<String>;
	public var content:Null<LayoutRenderableContent>;
	var fonts:Null<FontCollection>;
	var layout:Null<TextLayout>;
	final measurement:LayoutMeasuredContent;
	var signature:String = "";
	var size:Float = 15;
	public function new() {
		measurement = new LayoutMeasuredContent(function(constraints) return new LayoutMeasureResult(
			Math.max(1, Math.min(constraints.maxWidth, 1000)), size * 3.2 + 12));
		content = new LayoutRenderableContent(measurement, function(canvas, _) {
			if (layout != null) canvas.drawText(layout, 0, 4);
		});
	}
	public function update(path:String, size:Float):Void {
		var next = path + ":" + size;
		if (signature == next) return;
		signature = next; this.size = size;
		content.invalidatePaint();
		releaseFont(); error = null;
		try {
			if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) throw "Font file does not exist";
			fonts = FontCollection.create();
			fonts.add(path, FontFamily.Monospace);
			layout = TextLayout.create(fonts, "The quick brown fox jumps over the lazy dog.\n0123456789  {} [] () => !=  Il1 O0", 100000,
				new TextStyle(size, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
		} catch (_:Dynamic) {
			error = "Cannot preview this font. Choose a readable font file.";
			releaseFont();
		}
		measurement.invalidate();
	}
	public function setColor(color:Color):Void {
		if (layout != null) layout.setColor(color);
		if (content != null) content.invalidatePaint();
	}
	function releaseFont():Void {
		if (layout != null) { layout.dispose(); layout = null; }
		if (fonts != null) { fonts.dispose(); fonts = null; }
	}
	public function dispose():Void {
		if (content != null) { content.dispose(); content = null; }
		releaseFont();
	}
}
