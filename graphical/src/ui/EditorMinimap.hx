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
import haxeon.ui.widgets.scroll.ScrollbarVisibilityController;
import haxeon.ui.widgets.scroll.ScrollbarVisibility;
import haxeon.ui.core.UiKey;
import haxeon.ui.widgets.text.TextEditorLayout;
import editor.Document;
import editor.MinimapModel;
import editor.MinimapGeometry;
import editor.MinimapDensity;

/** Fixed right-hand preview sharing the editor's resolved paragraph positions. */
class EditorMinimap implements View {
	final document:Document;
	final scroll:ScrollController;
	final theme:style.Theme;
	final model:MinimapModel;
	final viewportGeometry:Null<editor.EditorViewportGeometry>;
	/** Workbench zoom factor, separate from the editor font size and layout coordinates. */
	public var applicationZoom:Float = 1.0;
	var rowPositions:Array<Float> = [];
	var positionRevision:Int = 0;
	var resolvedLayout:Null<TextEditorLayout>;
	var resolvedRevision:Int = -1;
	var resolvedGeneration:Int = -1;
	var dragging:Bool = false;
	var dragOffset:Float = 0;
	public var node(default, null):Null<RenderNode>;

	public function new(document:Document, scroll:ScrollController, theme:style.Theme, model:MinimapModel, ?viewportGeometry:editor.EditorViewportGeometry) {
		this.document = document;
		this.scroll = scroll;
		this.theme = theme;
		this.model = model;
		this.viewportGeometry = viewportGeometry;
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

	function viewportGeometryLineHeight():Float return viewportGeometry == null ? 21 : viewportGeometry.lineHeight;

	function density():MinimapDensity {
		return MinimapDensity.resolve(applicationZoom);
	}

	function mapScale():Float {
		if (viewportGeometry != null) return viewportGeometry.minimapScale(applicationZoom);
		var layout = resolvedLayout;
		var lineHeight = 21.0;
		if (layout != null && layout.paragraphCount > 0) {
			var caret = layout.paragraphCaret(0);
			lineHeight = layout.paragraphStyle.lineHeight == null ?
				Math.abs(caret.descender - caret.ascender) : layout.paragraphStyle.lineHeight;
		}
		return density().rowPitch / Math.max(1, lineHeight);
	}

	function mapGeometry(height:Float):MinimapGeometry {
		return viewportGeometry == null ? new MinimapGeometry(height, scroll.contentHeight, scroll.viewportHeight, mapScale()) : viewportGeometry.minimapGeometry(height, applicationZoom);
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
		built.focusable = true;
		var visibility = context.resourceState(context.id("minimap-viewport-visibility:" + document.id),
			function() return new ScrollbarVisibilityController(), function(value) value.dispose()).value;
		visibility.attach(context.animations, function() context.commands.refresh());
		visibility.configure(ScrollbarVisibility.Auto, context.environment.reducedMotion);
		visibility.setAvailable(true);
		built.on(UiEventKind.HoverEnter, function(_) visibility.setHovered(true));
		built.on(UiEventKind.HoverLeave, function(_) visibility.setHovered(false));
		built.on(UiEventKind.Focus, function(_) visibility.setFocused(true));
		built.on(UiEventKind.Blur, function(_) visibility.setFocused(false));
		built.on(UiEventKind.FocusLost, function(_) visibility.setFocused(false));
		built.on(UiEventKind.KeyDown, function(event) {
			var target = switch (event.key) {
				case UiKey.Up: scroll.offsetY - viewportGeometryLineHeight();
				case UiKey.Down: scroll.offsetY + viewportGeometryLineHeight();
				case UiKey.PageUp: scroll.offsetY - scroll.viewportHeight;
				case UiKey.PageDown: scroll.offsetY + scroll.viewportHeight;
				case UiKey.Home: 0.0;
				case UiKey.End: scroll.maxScrollY;
				default: return;
			};
			scroll.jumpTo(scroll.offsetX, target);
			context.commands.refresh();
			event.preventDefault(); event.stopPropagation();
		});
		var painting = context.resourceState(built.id, function() return new MinimapPainting(), function(value) value.dispose()).value;
		built.onPaint(function(canvas, geometry) {
			if (geometry.width <= 0 || geometry.height <= 0) return;
			var height = geometry.height;
			var scale = mapScale();
			var mapping = mapGeometry(height);
			var offset = mapping.previewOffset(scroll.offsetY);
			// Cache a page with a scroll margin, rather than compressing the whole file.
			var previewDensity = density();
			var tileStep = 256.0 / previewDensity.rasterScale;
			var tileTop = Math.floor(offset / tileStep) * tileStep;
			var tileHeight = Math.ceil((height + tileStep) * previewDensity.rasterScale) / previewDensity.rasterScale;
			var layout = resolvedLayout;
			if (layout != null && layout.paragraphCount > 0) {
				var origin = layout.paragraphCaret(0).y;
				model.update(document, layout.paragraphIndexAtY(tileTop / scale + origin),
					layout.paragraphIndexAtY((tileTop + tileHeight) / scale + origin));
				resolveTextLayout(layout);
			}
			var colors = [for (kind in 0...8) theme.tokenColor(kind)];
			var markHeight = previewDensity.markHeight;
			var key = model.generation + ":" + positionRevision + ":" + tileTop + ":" + tileHeight + ":" + scale + ":" + markHeight + ":" + previewDensity.rasterScale + ":" + colors.join(",");
			if (painting.key != key) {
				painting.dispose();
				var positions = [for (position in rowPositions) position * scale - tileTop];
				var bitmap = model.rasterize(colors, positions, tileHeight, tileHeight, markHeight, previewDensity.rasterScale);
				painting.image = Image.create(bitmap.width, bitmap.height, ImageFormat.RGBA8,
					bitmap.pixels, ImageFilter.Nearest);
				painting.key = key;
			}
			var previewImage = painting.image;
			if (previewImage != null) canvas.drawImage(previewImage, new Rect(4, tileTop - offset, geometry.width - 8, tileHeight));
			var top = mapping.thumbTop(scroll.offsetY);
			var visible = mapping.thumbHeight;
			canvas.fillRectIfPositive(new Rect(0, top, geometry.width, Math.max(2, visible)), color(theme.scrollbar, 0.25 * visibility.opacity));
			canvas.fillRectIfPositive(new Rect(0, top, 2, Math.max(2, visible)), color(theme.scrollbar, 0.8 * visibility.opacity));
		});
		var navigate = function(event:UiEvent) {
			if (built.resolved == null) return;
			var mapping = mapGeometry(built.resolved.height);
			var target = mapping.scrollAt(event.localY - dragOffset);
			scroll.jumpTo(scroll.offsetX, target);
			context.commands.refresh();
			event.preventDefault();
			event.stopPropagation();
		};
		built.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || built.resolved == null) return;
			var mapping = mapGeometry(built.resolved.height);
			var top = mapping.thumbTop(scroll.offsetY);
			if (event.localY >= top && event.localY <= top + mapping.thumbHeight)
				dragOffset = event.localY - top;
			else {
				dragOffset = mapping.thumbHeight / 2;
				navigate(event);
			}
			dragging = true;
			visibility.setDragging(true);
			event.capturePointer();
			event.preventDefault();
			event.stopPropagation();
		});
		built.on(UiEventKind.PointerMove, function(event) { if (dragging) navigate(event); });
		built.on(UiEventKind.PointerUp, function(event) { dragging = false; visibility.setDragging(false); event.releasePointer(); });
		built.on(UiEventKind.PointerCancel, function(_) { dragging = false; visibility.setDragging(false); });
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
