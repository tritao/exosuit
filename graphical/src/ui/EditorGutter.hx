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

/** Retained visible line-number labels, sharing the editor scroll transform. */
class EditorGutter implements View {
	final key:String;
	final buffer:TextBuffer;
	final foreground:Color;
	final background:Null<Color>;

	public function new(key:String, buffer:TextBuffer, foreground:Color, ?background:Color) {
		this.key = key;
		this.buffer = buffer;
		this.foreground = foreground;
		this.background = background;
	}

	public function build(context:BuildContext):RenderNode {
		var fonts = context.fonts;
		if (fonts == null || fonts.isDisposed()) throw "Editor gutters require fonts";
		var id = context.id(key);
		var labels = context.resourceState(id, function() return new GutterLabels(fonts),
			function(value) { value.dispose(); }).value;
		labels.update(buffer.lineCount(), foreground);
		var style = new LayoutStyle();
		style.width = LayoutAxis.fit();
		style.height = LayoutAxis.fit();
		if (background != null) style.background = background;
		var node = new RenderNode(id, LayoutVisualKind.Custom, style);
		node.hitTestSelf = false;
		node.layout.intrinsicContent = labels.content;
		return node;
	}
}

/** Measures the rail once and shapes only labels intersecting the viewport. */
private class GutterLabels {
	public final content:LayoutRenderableContent;
	final layout:TextLayout;
	final measurement:LayoutMeasuredContent;
	var count:Int = -1;
	var digits:Int = 1;
	var width:Float = 0.0;
	var rowHeight:Float = 1.0;
	var visibleFirst:Int = -1;
	var visibleEnd:Int = -1;
	var color:Null<Color> = null;

	public function new(fonts:FontCollection) {
		layout = TextLayout.create(fonts, "", 1.0, new TextStyle(13.0), new ParagraphStyle(TextWrap.None));
		measurement = new LayoutMeasuredContent(function(_) {
			return new LayoutMeasureResult(width + 12.0, rowHeight * count + 4.0);
		});
		content = new LayoutRenderableContent(measurement, function(canvas, geometry) {
			var visible = geometry.visibleLocalBounds();
			var first = Std.int(Math.max(0, Math.floor((visible.y - 4.0) / rowHeight) - 1));
			var end = Std.int(Math.min(count, Math.ceil((visible.y + visible.height - 4.0) / rowHeight) + 1));
			if (end <= first) return;
			if (first != visibleFirst || end != visibleEnd) {
				var labels:Array<String> = [];
				for (index in first...end) {
					var label = Std.string(index + 1);
					while (label.length < digits) label = " " + label;
					labels.push(label);
				}
				layout.setText(labels.join("\n"));
				visibleFirst = first;
				visibleEnd = end;
			}
			canvas.drawText(layout, 6.0, 4.0 + first * rowHeight);
		});
	}

	public function update(nextCount:Int, nextColor:Color):Void {
		if (count != nextCount) {
			digits = Std.string(nextCount == 0 ? 1 : nextCount).length;
			layout.setText(Std.string(nextCount == 0 ? 1 : nextCount));
			var metrics = layout.measure();
			width = metrics.width;
			rowHeight = Math.max(1.0, metrics.height);
			count = nextCount;
			visibleFirst = -1;
			visibleEnd = -1;
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
	}
}
