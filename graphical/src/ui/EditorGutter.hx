package ui;

import haxeon.ui.FontFamily;

import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
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
import haxeon.ui.core.UiEventKind;
import editor.TextBuffer;
import plugin.PluginGutterMarker;
import plugin.PluginGutterMarkerKind;
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
	final activeLine:Int;
	final activeForeground:Color;
	final markers:Array<PluginGutterMarker>;
	final markerRevision:Int;
	final onMarkerClick:Null<PluginGutterMarker->Void>;
	var labels:Null<GutterLabels>;
	var markerLane:Null<GutterMarkerLane>;
	var node:Null<RenderNode>;
	var context:Null<BuildContext>;

	public function resolveTextLayout(layout:TextEditorLayout, geometry:ResolvedLayoutItem):Void {
		if (labels == null || markerLane == null || node == null || node.resolved == null || context == null) return;
		// ScrollView translates its content through the resolved transform;
		// layout y alone stays unchanged while the document scrolls.
		var originY = editor.GutterGeometry.sourceOriginY(geometry, node.resolved);
		var labelsChanged = labels.resolve(layout, originY);
		var markersChanged = markerLane.resolve(layout, originY);
		if (labelsChanged || markersChanged) context.requestLayoutFeedback();
	}

	public function new(key:String, buffer:TextBuffer, foreground:Color, ?background:Color, fontSize:Float = 15.0,
			activeLine:Int = -1, ?activeForeground:Color, ?markers:Array<PluginGutterMarker>, markerRevision:Int = 0,
			?onMarkerClick:PluginGutterMarker->Void) {
		this.key = key;
		this.buffer = buffer;
		this.foreground = foreground;
		this.background = background;
		this.fontSize = fontSize;
		this.activeLine = activeLine;
		this.activeForeground = activeForeground == null ? foreground : activeForeground;
		this.markers = markers == null ? [] : markers.copy();
		this.markerRevision = markerRevision;
		this.onMarkerClick = onMarkerClick;
	}

	public function build(context:BuildContext):RenderNode {
		this.context = context;
		var fonts = context.fonts;
		if (fonts == null || fonts.isDisposed()) throw "Editor gutters require fonts";
		var id = context.id(key);
		var retained = context.resourceState(id, function() return new GutterLabels(fonts),
			function(value) { value.dispose(); }).value;
		labels = retained;
		retained.update(buffer.lineCount(), foreground, fontSize, activeLine, activeForeground);
		var markerState = context.resourceState(context.id("gutter-marker-lane:" + key),
			function() return new GutterMarkerLane(), function(value) { value.dispose(); }).value;
		markerLane = markerState;
		markerState.update(markers, markerRevision, context.theme.tokens.success,
			context.theme.tokens.accent, context.theme.tokens.danger);
		var style = new LayoutStyle();
		style.width = LayoutAxis.fit();
		style.height = LayoutAxis.grow();
		style.direction = LayoutDirection.LeftToRight;
		style.clipVertical = true;
		if (background != null) style.background = background;
		var built = new RenderNode(id, LayoutVisualKind.Box, style);
		built.styleKey = key + ":markers:" + markerRevision;
		node = built;
		built.hitTestSelf = false;
		var laneStyle = new LayoutStyle();
		laneStyle.width = LayoutAxis.fixed(5.0);
		laneStyle.height = LayoutAxis.grow();
		laneStyle.clipVertical = true;
		var laneNode = new RenderNode(context.id("gutter-marker-strip:" + key), LayoutVisualKind.Custom, laneStyle);
		laneNode.styleKey = key + ":marker-strip:" + markerRevision;
		laneNode.hitTestSelf = markers.length > 0;
		laneNode.layout.intrinsicContent = markerState.content;
		laneNode.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || onMarkerClick == null) return;
			var marker = markerState.markerAt(event.localY);
			if (marker == null) return;
			onMarkerClick(marker);
			event.preventDefault();
			event.stopPropagation();
		});
		var labelsNode = new RenderNode(context.id("gutter-line-numbers:" + key), LayoutVisualKind.Custom, new LayoutStyle());
		labelsNode.styleKey = key + ":line-numbers";
		labelsNode.hitTestSelf = false;
		labelsNode.layout.style.width = LayoutAxis.fit();
		labelsNode.layout.style.height = LayoutAxis.grow();
		labelsNode.layout.intrinsicContent = retained.content;
		built.add(laneNode);
		built.add(labelsNode);
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

	var count:Int = -1;
	var digits:Int = 1;
	var width:Float = 0.0;
	var color:Null<Color> = null;
	var activeColor:Null<Color> = null;
	var activeLine:Int = -1;
	var fontSize:Float = 15.0;

	public function new(fonts:FontCollection) {
		this.fonts = fonts;
		layout = TextLayout.create(fonts, "", 1.0, new TextStyle(fontSize, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
		measurement = new LayoutMeasuredContent(function(_) {
			return new LayoutMeasureResult(width + 7.0, 1.0);
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
				var highlighted = index == activeLine;
				if (label.highlighted != highlighted) {
					label.layout.setColor(highlighted ? activeColor : color);
					label.highlighted = highlighted;
				}
				canvas.drawText(label.layout, 1.0, originY + label.y - label.baseline);
			}
		});
	}

	public function resolve(editor:TextEditorLayout, nextOriginY:Float):Bool {
		editorLayout = editor;
		originY = nextOriginY;
		content.invalidatePaint();
		return false;
	}

	public function update(nextCount:Int, nextColor:Color, nextFontSize:Float, nextActiveLine:Int, nextActiveColor:Color):Void {
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
		if (activeLine != nextActiveLine) { activeLine = nextActiveLine; content.invalidatePaint(); }
		var activeColorChanged = activeColor == null || activeColor.red != nextActiveColor.red ||
			activeColor.green != nextActiveColor.green || activeColor.blue != nextActiveColor.blue || activeColor.alpha != nextActiveColor.alpha;
		activeColor = nextActiveColor;
		if (activeColorChanged || color == null || color.red != nextColor.red || color.green != nextColor.green ||
			color.blue != nextColor.blue || color.alpha != nextColor.alpha) {
			layout.setColor(nextColor);
			color = nextColor;
			for (label in visibleLabels) { label.layout.setColor(nextColor); label.highlighted = false; }
			content.invalidatePaint();
		}
	}

	public function dispose():Void {
		content.dispose();
		layout.dispose();
		for (label in visibleLabels) label.layout.dispose();
	}
}

/** Narrow, separately hit-tested marker lane retained with the line-number rail. */
private class GutterMarkerLane {
	public final content:LayoutRenderableContent;
	final measurement:LayoutMeasuredContent;
	var editorLayout:Null<TextEditorLayout>;
	var originY:Float = 0.0;
	var markers:Array<PluginGutterMarker> = [];
	var revision:Int = -1;
	var addedColor:Null<Color>;
	var modifiedColor:Null<Color>;
	var deletedColor:Null<Color>;

	public function new() {
		measurement = new LayoutMeasuredContent(function(_) return new LayoutMeasureResult(5.0, 1.0));
		content = new LayoutRenderableContent(measurement, function(canvas, geometry) {
			var editor = editorLayout;
			if (editor == null || markers.length == 0) return;
			var visible = geometry.visibleLocalBounds();
			var first = Std.int(Math.max(0, editor.paragraphIndexAtY(visible.y - originY) - 1));
			var end = Std.int(Math.min(editor.paragraphCount,
				editor.paragraphIndexAtY(visible.y + visible.height - originY) + 2));
			if (end <= first) return;
			for (marker in markers) {
				if (marker.endLine < first || marker.startLine >= end) continue;
				var color = switch marker.kind {
					case Added: addedColor;
					case Modified: modifiedColor;
					case DeletedAbove | DeletedBelow: deletedColor;
				};
				if (color == null) continue;
				for (line in marker.startLine...(marker.endLine + 1)) {
					if (line < first || line >= end || line >= editor.paragraphCount) continue;
					var caret = editor.paragraphCaret(line);
					var top = originY + caret.y + Math.min(caret.ascender, caret.descender);
					var height = Math.max(1.0, Math.abs(caret.descender - caret.ascender));
					switch marker.kind {
						case Added | Modified:
							canvas.fillRectIfPositive(new haxeon.ui.Rect(1.0, top, 3.0, height), color);
						case DeletedAbove:
							canvas.fillRectIfPositive(new haxeon.ui.Rect(0.0, top - 2.0, 5.0, 2.0), color);
						case DeletedBelow:
							canvas.fillRectIfPositive(new haxeon.ui.Rect(0.0, top + height, 5.0, 2.0), color);
					}
				}
			}
		});
	}

	public function update(next:Array<PluginGutterMarker>, nextRevision:Int, nextAdded:Color,
			nextModified:Color, nextDeleted:Color):Void {
		var colorChanged = addedColor == null || modifiedColor == null || deletedColor == null ||
			!sameColor(addedColor, nextAdded) || !sameColor(modifiedColor, nextModified) || !sameColor(deletedColor, nextDeleted);
		if (revision == nextRevision && !colorChanged) return;
		markers = next == null ? [] : next.copy();
		revision = nextRevision;
		addedColor = nextAdded;
		modifiedColor = nextModified;
		deletedColor = nextDeleted;
		content.invalidatePaint();
	}

	public function resolve(editor:TextEditorLayout, nextOriginY:Float):Bool {
		var changed = editorLayout != editor || originY != nextOriginY;
		editorLayout = editor;
		originY = nextOriginY;
		if (changed) content.invalidatePaint();
		return false;
	}

	public function markerAt(localY:Float):Null<PluginGutterMarker> {
		var editor = editorLayout;
		if (editor == null || markers.length == 0) return null;
		var line = editor.paragraphIndexAtY(localY - originY);
		for (marker in markers) if (line >= marker.startLine && line <= marker.endLine) return marker;
		return null;
	}

	public function dispose():Void content.dispose();

	static function sameColor(a:Color, b:Color):Bool
		return a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha;
}

/** Geometry belongs to a particular editor layout and its current revision. */
private class GutterLabel {
	public final layout:TextLayout;
	public var highlighted:Bool = false;
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
