package ui;

import Color;
import FontCollection;
import LayoutAxis;
import LayoutStyle;
import LayoutVisualKind;
import LayoutMeasuredContent;
import LayoutMeasureResult;
import LayoutRenderableContent;
import TextLayout;
import TextStyle;
import ParagraphStyle;
import TextWrap;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import editor.TextBuffer;
import nativekit.ui.widgets.text.TextEditorLayout;
import ResolvedLayoutItem;
import TextPosition;

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
	final visibleLabels:Array<TextLayout> = [];
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
		layout = TextLayout.create(fonts, "", 1.0, new TextStyle(fontSize), new ParagraphStyle(TextWrap.None));
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
			for (index in first...end) {
				var slot = index - first;
				if (slot == visibleLabels.length)
					visibleLabels.push(TextLayout.create(fonts, "", 1.0,
						new TextStyle(fontSize), new ParagraphStyle(TextWrap.None)));
				var label = Std.string(index + 1);
				while (label.length < digits) label = " " + label;
				var number = visibleLabels[slot];
				number.setText(label);
				if (color != null) number.setColor(color);
				var baseline = number.caret(new TextPosition(0, 0)).y;
				canvas.drawText(number, 6.0, originY + editor.paragraphCaret(index).y - baseline);
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
			var style = new TextStyle(fontSize);
			layout.update(layout.text, 1.0, style, layout.paragraphStyle);
			for (label in visibleLabels) label.update(label.text, 1.0, style, label.paragraphStyle);
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
			content.invalidatePaint();
		}
	}

	public function dispose():Void {
		content.dispose();
		layout.dispose();
		for (label in visibleLabels) label.dispose();
	}
}
