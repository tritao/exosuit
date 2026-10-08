package ui;

import haxeon.ui.Rect;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.widgets.overlays.TooltipPlacement;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;

/** A delayed tooltip that appears after a deliberate hover. */
class TabTooltip implements View {
	final key:String;
	final anchor:View;
	final content:View;
	final delaySeconds:Float;
	final placement:TooltipPlacement;
	final hoverGroup:Null<TooltipHoverGroup>;
	final groupVisible:Bool;
	final boundsProvider:Void->Rect;
	static inline final PADDING = 10.0;
	static inline final EDGE = 6.0;
	public function new(key:String, anchor:View, content:View, boundsProvider:Void->Rect, delaySeconds:Float = 0.8, placement:TooltipPlacement = Below,
			?hoverGroup:TooltipHoverGroup, groupVisible:Bool = false) {
		this.hoverGroup = hoverGroup;
		this.groupVisible = groupVisible;
		this.placement = placement;
		this.boundsProvider = boundsProvider; this.delaySeconds = delaySeconds;
		this.key = key; this.anchor = anchor; this.content = content;
	}
	/** Content width excludes the tooltip's own padding. */
	public static function place(anchorX:Float, anchorHeight:Float, railX:Float, railWidth:Float):{x:Float, y:Float, width:Float} {
		var width = Math.max(1, Math.min(300, railWidth - 2 * (EDGE + PADDING)));
		var x = Math.max(railX + EDGE - anchorX, Math.min(0, railX + railWidth - EDGE - anchorX - width - 2 * PADDING));
		return {x: x, y: anchorHeight + 4, width: width};
	}
	/** Returns anchor-relative coordinates, preferring right and keeping the box in the viewport. */
	public static function placeRight(anchor:Rect, width:Float, height:Float, viewport:Rect):{x:Float, y:Float, width:Float} {
		var limit = Math.max(1, Math.min(300, viewport.width - 2 * (EDGE + PADDING)));
		var boxWidth = Math.min(width, limit + 2 * PADDING);
		var x = anchor.x + anchor.width + 8;
		if (x + boxWidth > viewport.x + viewport.width - EDGE)
			x = anchor.x - boxWidth - 8;
		x = Math.max(viewport.x + EDGE, Math.min(x, viewport.x + viewport.width - EDGE - boxWidth));
		var y = Math.max(viewport.y + EDGE, Math.min(anchor.y + (anchor.height - height) / 2,
			viewport.y + viewport.height - EDGE - height));
		return {x: x - anchor.x, y: y - anchor.y, width: limit};
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var state = context.resourceState(context.id("visible"), function() return false, function(_) {});
			var delay = context.resourceState(context.id("hover-delay"),
				function() return new TabHoverDelay(context.animations, function(value) { state.update(value); }, delaySeconds),
				function(value) value.dispose()).value;
			delay.delaySeconds = delaySeconds;
			var style = new LayoutStyle();
			style.clipToParent = false;
			var root = new RenderNode(context.id("layers"), LayoutVisualKind.Box, style);
			root.hitTestSelf = false;
			var header = anchor.build(context);
			root.add(header);
			var tipStyle = new LayoutStyle();
			tipStyle.positioning = LayoutPositioning.Absolute;
			tipStyle.positionY = 44;
			tipStyle.zIndex = 10;
			tipStyle.clipToParent = false;
			tipStyle.visible = hoverGroup == null ? state.value : groupVisible;
			tipStyle.padding = new Insets(PADDING, 7, PADDING, 7);
			var tipId = context.id("tooltip");
			var computed = context.resolveStyle(new StyleTarget("tooltip", key, key, null, ["tooltip"],
				context.interactionStates.get(tipId)), tipStyle);
			var tip = new RenderNode(tipId, LayoutVisualKind.Box, computed.toLayoutStyle());
			tip.computedStyle = computed;
			tip.setStyleIdentity("tooltip", key, key, null, ["tooltip"]);
			var label = context.withStyleParent(computed, function() return
				context.withScope(new Key("content"), function() return content.build(context)));
			tip.add(label);
			root.onResolved(function(_) {
				if (root.resolved == null || header.resolved == null) return;
				var rail = boundsProvider();
				var anchorBounds = root.globalBounds();
				var placement = place(anchorBounds.x, header.globalBounds().height, rail.x, rail.width);
				var tipBounds = tip.resolved == null ? null : tip.globalBounds();
				if (tipBounds != null) placement.x = Math.max(rail.x + EDGE - anchorBounds.x,
					Math.min(0, rail.x + rail.width - EDGE - anchorBounds.x - tipBounds.width));
				if (this.placement == Above && tipBounds != null) placement.y = -tipBounds.height - 4;
				if (this.placement == Right) {
					var side = placeRight(anchorBounds, tipBounds == null ? 0 : tipBounds.width,
						tipBounds == null ? 0 : tipBounds.height, rail);
					placement.x = side.x;
					placement.y = side.y;
					placement.width = side.width;
				}

				if (tip.layout.style.positionX != placement.x || tip.layout.style.positionY != placement.y || label.layout.style.width.max != placement.width) {
					tip.layout.style.positionX = placement.x;
					tip.layout.style.positionY = placement.y;
					label.layout.style.width = LayoutAxis.fit(0, placement.width);
					context.requestLayoutFeedback();
				}
			});
			// The overlay must never extend the tab's hover area into the editor.
			tip.walk(function(node) { node.hitTestSelf = false; });
			root.add(tip);
			header.on(UiEventKind.HoverEnter, function(_) {
				if (hoverGroup != null) hoverGroup.enter(key); else delay.start();
			});
			header.on(UiEventKind.HoverLeave, function(_) {
				if (hoverGroup != null) hoverGroup.leave(key); else delay.cancel();
			});
			header.on(UiEventKind.PointerDown, function(_) {
				if (hoverGroup != null) hoverGroup.cancel(); else delay.cancel();
			}, "capture");
			return root;
		});
	}
}
