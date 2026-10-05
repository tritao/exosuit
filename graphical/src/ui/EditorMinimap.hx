package ui;

import haxeon.ui.Image;
import haxeon.ui.ImageFilter;
import haxeon.ui.ImageFormat;

import haxeon.ui.Color;
import haxeon.ui.Rect;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.TextEditorLayout;
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

	var dragMapOffset:Float = 0;

	function mapScale():Float {
		var layout = resolvedLayout;
		return 2.0 / Math.max(1, layout == null ? 20 : layout.textStyle.fontSize * 1.4);
	}

	function mapOffset(height:Float):Float {
		var scale = mapScale();
		var travel = Math.max(0, scroll.contentHeight * scale - height);
		var scrollTravel = Math.max(1, scroll.contentHeight - scroll.viewportHeight);
		return travel * scroll.offsetY / scrollTravel;
	}

	public function build(context:BuildContext):RenderNode {
		if (resolvedLayout == null) model.update(document);
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
			var height = geometry.height;
			var scale = mapScale();
			var offset = mapOffset(height);
			// Cache a page with a scroll margin, rather than compressing the whole file.
			var tileTop = Math.floor(offset / 256) * 256;
			var tileHeight = Math.ceil(height + 256);
			var layout = resolvedLayout;
			if (layout != null && layout.paragraphCount > 0) {
				var origin = layout.paragraphCaret(0).y;
				model.update(document, layout.paragraphIndexAtY(tileTop / scale + origin),
					layout.paragraphIndexAtY((tileTop + tileHeight) / scale + origin));
				resolveTextLayout(layout);
			}
			var colors = [for (kind in 0...8) theme.tokenColor(kind)];
			var key = model.generation + ":" + positionRevision + ":" + tileTop + ":" + tileHeight + ":" + scale + ":" + colors.join(",");
			if (painting.key != key) {
				painting.dispose();
				var positions = [for (position in rowPositions) position * scale - tileTop];
				var bitmap = model.rasterize(colors, positions, tileHeight, tileHeight);
				painting.image = Image.create(bitmap.width, bitmap.height, ImageFormat.RGBA8,
					bitmap.pixels, ImageFilter.Nearest);
				painting.key = key;
			}
			var previewImage = painting.image;
			if (previewImage != null) canvas.drawImage(previewImage, new Rect(4, tileTop - offset, geometry.width - 8, tileHeight));
			var top = scroll.offsetY * scale - offset;
			var visible = Math.min(height, scroll.viewportHeight * scale);
			canvas.fillRectIfPositive(new Rect(0, top, geometry.width, Math.max(2, visible)), color(theme.scrollbar, 0.25));
			canvas.fillRectIfPositive(new Rect(0, top, 2, Math.max(2, visible)), color(theme.scrollbar, 0.8));
		});
		var navigate = function(event:UiEvent) {
			if (built.resolved == null) return;
			var offset = dragging ? dragMapOffset : mapOffset(built.resolved.height);
			var target = (event.localY + offset - (dragging ? dragOffset : scroll.viewportHeight * mapScale() / 2)) / mapScale();
			scroll.jumpTo(scroll.offsetX, target);
			context.commands.refresh();
			event.preventDefault();
			event.stopPropagation();
		};
		built.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || built.resolved == null) return;
			var offset = mapOffset(built.resolved.height);
			var top = scroll.offsetY * mapScale() - offset;
			var visible = scroll.viewportHeight * mapScale();
			if (event.localY >= top && event.localY <= top + visible) dragOffset = event.localY - top;
			else {
				navigate(event);
				dragOffset = event.localY + offset - scroll.offsetY * mapScale();
			}
			dragMapOffset = offset;
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

/** One bounded bitmap; scrolling only repaints the viewport overlay. */
private class MinimapPainting {
	public var key:String = "";
	public var image:Null<Image>;
	public function new() {}
	public function dispose():Void {
		var retainedImage = image;
		if (retainedImage != null) retainedImage.dispose();
		image = null;
		key = "";
	}
}
