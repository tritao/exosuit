package ui;

import Color;
import Rect;
import LayoutAxis;
import LayoutStyle;
import LayoutVisualKind;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.View;
import nativekit.ui.widgets.scroll.ScrollController;
import nativekit.ui.widgets.text.TextEditorLayout;
import editor.Document;
import editor.MinimapModel;

/** Fixed right-hand preview sharing the editor's resolved paragraph positions. */
class EditorMinimap implements View {
	final document:Document;
	final scroll:ScrollController;
	final theme:style.Theme;
	final model:MinimapModel;
	var rowPositions:Array<Float> = [];
	var positionRevision:Int = 0;
	var resolvedLayout:Null<TextEditorLayout>;
	var resolvedRevision:Int = -1;
	var resolvedGeneration:Int = -1;
	var dragging:Bool = false;
	var dragOffset:Float = 0;
	public var node(default, null):Null<RenderNode>;

	public function new(document:Document, scroll:ScrollController, theme:style.Theme, model:MinimapModel) {
		this.document = document;
		this.scroll = scroll;
		this.theme = theme;
		this.model = model;
	}

	public function resolveTextLayout(layout:TextEditorLayout):Void {
		if (resolvedLayout == layout && resolvedRevision == layout.geometryRevision && resolvedGeneration == model.generation) return;
		resolvedLayout = layout;
		resolvedRevision = layout.geometryRevision;
		resolvedGeneration = model.generation;
		var previous = rowPositions;
		rowPositions = [];
		if (layout.paragraphCount == 0) { positionRevision++; return; }
		var origin = layout.paragraphCaret(0).y;
		for (row in model.rows)
			rowPositions.push(row.line < layout.paragraphCount ? Math.max(0, layout.paragraphCaret(row.line).y - origin) : 0);
		var changed = previous.length != rowPositions.length;
		if (!changed) for (index in 0...previous.length) if (previous[index] != rowPositions[index]) changed = true;
		if (changed) positionRevision++;
	}

	static function color(value:Int, alpha:Float = 1):Color
		return Color.fromBytes((value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, Std.int((value & 255) * alpha));

	function mapHeight(height:Float):Float {
		var count = document.buffer.lineCount();
		return Math.max(1, Math.min(height, count * 2.0));
	}

	public function build(context:BuildContext):RenderNode {
		model.update(document);
		var layoutStyle = new LayoutStyle();
		layoutStyle.width = LayoutAxis.fixed(88);
		layoutStyle.height = LayoutAxis.grow();
		layoutStyle.background = color(theme.editorBackground);
		layoutStyle.clipHorizontal = true;
		layoutStyle.clipVertical = true;
		var built = new RenderNode(context.id("editor-minimap:" + document.id), LayoutVisualKind.Custom, layoutStyle);
		built.setStyleIdentity("editor-minimap", "editor-minimap:" + document.id);
		node = built;
		var painting = context.resourceState(built.id, function() return new MinimapPainting(), function(value) value.dispose()).value;
		built.onPaint(function(canvas, geometry) {
			if (geometry.width <= 0 || geometry.height <= 0) return;
			var height = mapHeight(geometry.height);
			var contentHeight = Math.max(1, scroll.contentHeight);
			var unit = Math.max(0, geometry.width - 8) / MinimapModel.MAX_COLUMNS;
			if (unit <= 0) return;
			var colors = [for (kind in 0...8) theme.tokenColor(kind)];
			var key = model.generation + ":" + positionRevision + ":" + geometry.width + ":" + height + ":" + contentHeight + ":" + colors.join(",");
			if (painting.key != key) {
				painting.dispose();
				var paths = [for (_ in 0...8) new PathBuilder()];
				var used = [for (_ in 0...8) false];
				for (index in 0...model.rows.length) {
					var row = model.rows[index];
					var y = index < rowPositions.length ?
						rowPositions[index] / contentHeight * height :
						row.line / Math.max(1, document.buffer.lineCount()) * height;
					for (span in row.spans) {
						var x = 4 + span.start * unit, right = x + span.length * unit;
						paths[span.kind].moveTo(x, y).lineTo(right, y).lineTo(right, y + 1).lineTo(x, y + 1).close();
						used[span.kind] = true;
					}
				}
				for (kind in 0...8)
					if (used[kind]) {
						painting.paths.push(paths[kind].build());
						painting.paints.push(Paint.SolidPaint.create(color(colors[kind], 0.7)));
					}
				painting.key = key;
			}
			for (index in 0...painting.paths.length) canvas.fill(painting.paths[index], painting.paints[index]);
			var top = scroll.offsetY / contentHeight * height;
			var visible = Math.min(height, scroll.viewportHeight / contentHeight * height);
			canvas.fillRectIfPositive(new Rect(0, top, geometry.width, Math.max(2, visible)), color(theme.scrollbar, 0.25));
			canvas.fillRectIfPositive(new Rect(0, top, 2, Math.max(2, visible)), color(theme.scrollbar, 0.8));
		});
		var navigate = function(event:UiEvent) {
			if (built.resolved == null) return;
			var height = mapHeight(built.resolved.height);
			var target = dragging ? (event.localY - dragOffset) / height * scroll.contentHeight :
				MinimapModel.scrollTarget(event.localY, height, scroll.contentHeight, scroll.viewportHeight);
			scroll.jumpTo(scroll.offsetX, target);
			context.commands.refresh();
			event.preventDefault();
			event.stopPropagation();
		};
		built.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || built.resolved == null) return;
			var height = mapHeight(built.resolved.height);
			var top = scroll.offsetY / Math.max(1, scroll.contentHeight) * height;
			var visible = scroll.viewportHeight / Math.max(1, scroll.contentHeight) * height;
			if (event.localY >= top && event.localY <= top + visible) dragOffset = event.localY - top;
			else {
				navigate(event);
				dragOffset = event.localY - scroll.offsetY / Math.max(1, scroll.contentHeight) * height;
			}
			dragging = true;
			event.capturePointer();
			event.preventDefault();
			event.stopPropagation();
		});
		built.on(UiEventKind.PointerMove, function(event) { if (dragging) navigate(event); });
		built.on(UiEventKind.PointerUp, function(event) { dragging = false; event.releasePointer(); });
		built.on(UiEventKind.PointerCancel, function(_) dragging = false);
		built.on(UiEventKind.Scroll, function(event) {
			scroll.scrollBy(0, event.deltaY);
			context.commands.refresh();
			event.preventDefault();
			event.stopPropagation();
		});
		return built;
	}
}

/** Owns at most eight batched paths; viewport scrolling only repaints the overlay. */
private class MinimapPainting {
	public var key:String = "";
	public final paths:Array<Path> = [];
	public final paints:Array<Paint> = [];
	public function new() {}
	public function dispose():Void {
		for (path in paths) path.dispose();
		for (paint in paints) paint.dispose();
		paths.resize(0);
		paints.resize(0);
		key = "";
	}
}
