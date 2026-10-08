package ui;

import haxeon.ui.FontFamily;

import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LayoutMeasuredContent;
import haxeon.ui.LayoutMeasureResult;
import haxeon.ui.LayoutRenderableContent;
import haxeon.ui.TextLayout;
import haxeon.ui.TextStyle;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import editor.TextBuffer;
import haxeon.ui.widgets.text.TextEditorLayout;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.TextLayout.TextPosition;

/** Retained visible line-number labels, sharing the editor scroll transform. */
class EditorGutter implements View {
	final key:String;
	final buffer:TextBuffer;
	final foreground:Color;
	final background:Null<Color>;
	final fontSize:Float;
	var labels:Null<GutterLabels>;
	var node:Null<RenderNode>;
	var context:Null<BuildContext>;

	public function resolveTextLayout(layout:TextEditorLayout, geometry:ResolvedLayoutItem):Void {
		if (labels == null || node == null || node.resolved == null || context == null) return;
		if (labels.resolve(layout, geometry.y - node.resolved.y)) context.requestLayoutFeedback();
	}

	public function new(key:String, buffer:TextBuffer, foreground:Color, ?background:Color, fontSize:Float = 15.0) {
		this.key = key;
		this.buffer = buffer;
		this.foreground = foreground;
		this.background = background;
		this.fontSize = fontSize;
	}

	public function build(context:BuildContext):RenderNode {
		this.context = context;
		var fonts = context.fonts;
		if (fonts == null || fonts.isDisposed()) throw "Editor gutters require fonts";
		var id = context.id(key);
		var retained = context.resourceState(id, function() return new GutterLabels(fonts),
			function(value) { value.dispose(); }).value;
		labels = retained;
		retained.update(buffer.lineCount(), foreground, fontSize);
		var style = new LayoutStyle();
		style.width = LayoutAxis.fit();
		style.height = LayoutAxis.fit();
		if (background != null) style.background = background;
		var built = new RenderNode(id, LayoutVisualKind.Custom, style);
		built.styleKey = key;
		node = built;
		built.hitTestSelf = false;
		built.layout.intrinsicContent = retained.content;
		return built;
	}
}

/** Measures the rail once and shapes only labels intersecting the viewport. */
private class GutterLabels {
	public final content:LayoutRenderableContent;
	final layout:TextLayout;
	final measurement:LayoutMeasuredContent;
	final fonts:FontCollection;
	final visibleLabels:Array<GutterLabel> = [];
	var editorLayout:Null<TextEditorLayout>;
	var originY:Float = 0.0;
	var height:Float = 4.0;
	var count:Int = -1;
	var digits:Int = 1;
	var width:Float = 0.0;
	var color:Null<Color> = null;
	var fontSize:Float = 15.0;

	public function new(fonts:FontCollection) {
		this.fonts = fonts;
		layout = TextLayout.create(fonts, "", 1.0, new TextStyle(fontSize, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
		measurement = new LayoutMeasuredContent(function(_) {
			return new LayoutMeasureResult(width + 12.0, height);
		});
		content = new LayoutRenderableContent(measurement, function(canvas, geometry) {
			var editor = editorLayout;
			if (editor == null || editor.paragraphCount == 0) return;
			var visible = geometry.visibleLocalBounds();
			var first = Std.int(Math.max(0, editor.paragraphIndexAtY(visible.y - originY) - 1));
			var end = Std.int(Math.min(editor.paragraphCount,
				editor.paragraphIndexAtY(visible.y + visible.height - originY) + 2));
			if (end <= first) return;
			// Stable line-to-slot mapping retains overlapping labels during scrolling.
			// Grow before choosing slots so every visible line has a distinct slot.
			while (visibleLabels.length < end - first) {
				var number = TextLayout.create(fonts, "", 1.0,
					new TextStyle(fontSize, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
				if (color != null) number.setColor(color);
				visibleLabels.push(new GutterLabel(number));
			}
			for (index in first...end) {
				var slot = index % visibleLabels.length;
				var label = visibleLabels[slot];
				if (label.index != index || label.digits != digits) {
					var text = Std.string(index + 1);
					while (text.length < digits) text = " " + text;
					label.layout.setText(text);
					label.baseline = label.layout.caret(new TextPosition(0, 0)).y;
					label.index = index;
					label.digits = digits;
					label.editor = null;
				}
				if (label.editor != editor || label.revision != editor.geometryRevision) {
					label.y = editor.paragraphCaret(index).y;
					label.editor = editor;
					label.revision = editor.geometryRevision;
				}
				canvas.drawText(label.layout, 6.0, originY + label.y - label.baseline);
			}
		});
	}

	public function resolve(editor:TextEditorLayout, nextOriginY:Float):Bool {
		editorLayout = editor;
		originY = nextOriginY;
		var nextHeight = Math.max(0.0, originY + editor.measure().height);
		var changed = height != nextHeight;
		if (changed) {
			height = nextHeight;
			measurement.invalidate();
		}
		content.invalidatePaint();
		return changed;
	}

	public function update(nextCount:Int, nextColor:Color, nextFontSize:Float):Void {
		if (fontSize != nextFontSize) {
			fontSize = nextFontSize;
			var style = new TextStyle(fontSize, FontFamily.Monospace);
			layout.update(layout.text, 1.0, style, layout.paragraphStyle);
			for (label in visibleLabels) {
				label.layout.update(label.layout.text, 1.0, style, label.layout.paragraphStyle);
				label.index = -1;
			}
			count = -1;
			content.invalidatePaint();
		}
		if (count != nextCount) {
			digits = Std.string(nextCount == 0 ? 1 : nextCount).length;
			layout.setText(Std.string(nextCount == 0 ? 1 : nextCount));
			var metrics = layout.measure();
			width = metrics.width;
			count = nextCount;
			measurement.invalidate();
		}
		if (color == null || color.red != nextColor.red || color.green != nextColor.green ||
			color.blue != nextColor.blue || color.alpha != nextColor.alpha) {
			layout.setColor(nextColor);
			color = nextColor;
			for (label in visibleLabels) label.layout.setColor(nextColor);
			content.invalidatePaint();
		}
	}

	public function dispose():Void {
		content.dispose();
		layout.dispose();
		for (label in visibleLabels) label.layout.dispose();
	}
}

/** Geometry belongs to a particular editor layout and its current revision. */
private class GutterLabel {
	public final layout:TextLayout;
	public var index:Int = -1;
	public var digits:Int = -1;
	public var baseline:Float = 0.0;
	public var y:Float = 0.0;
	public var editor:Null<TextEditorLayout>;
	public var revision:Int = -1;

	public function new(layout:TextLayout) {
		this.layout = layout;
	}
}
