package ui;

import Insets;
import LayoutAxis;
import LayoutPositioning;
import LayoutStyle;
import LayoutVisualKind;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.View;

/** A tab-only tooltip that appears after a deliberate hover. */
class TabTooltip implements View {
	final key:String;
	final anchor:View;
	final content:View;
	final delaySeconds:Float;
	final beside:Bool;
	final boundsProvider:Void->Rect;
	static inline final PADDING = 10.0;
	static inline final EDGE = 6.0;
	public function new(key:String, anchor:View, content:View, boundsProvider:Void->Rect, delaySeconds:Float = 0.8, beside:Bool = false) {
		this.beside = beside;
		this.boundsProvider = boundsProvider; this.delaySeconds = delaySeconds;
		this.key = key; this.anchor = anchor; this.content = content;
	}
	/** Content width excludes the tooltip's own padding. */
	public static function place(anchorX:Float, anchorHeight:Float, railX:Float, railWidth:Float):{x:Float, y:Float, width:Float} {
		var width = Math.max(1, Math.min(300, railWidth - 2 * (EDGE + PADDING)));
		var x = Math.max(railX + EDGE - anchorX, Math.min(0, railX + railWidth - EDGE - anchorX - width - 2 * PADDING));
		return {x: x, y: anchorHeight + 4, width: width};
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
			tipStyle.visible = state.value;
			tipStyle.background = context.theme.tokens.surfaceRaised;
			tipStyle.padding = new Insets(PADDING, 7, PADDING, 7);
			tipStyle.radiusTopLeft = tipStyle.radiusTopRight = 5;
			tipStyle.radiusBottomLeft = tipStyle.radiusBottomRight = 5;
			var tip = new RenderNode(context.id("tooltip"), LayoutVisualKind.Box, tipStyle);
			var label = context.withScope(new Key("content"), function() return content.build(context));
			tip.add(label);
			root.onResolved(function(_) {
				if (root.resolved == null || header.resolved == null) return;
				var rail = boundsProvider();
				var anchorBounds = root.globalBounds();
				var placement = place(anchorBounds.x, header.globalBounds().height, rail.x, rail.width);
				if (beside) {
					placement.width = Math.max(1, Math.min(140, rail.width - anchorBounds.x - anchorBounds.width - 2 * PADDING - EDGE - 4));
					placement.x = anchorBounds.width + 4;
					placement.y = 0;
				}
				if (tip.layout.style.positionX != placement.x || tip.layout.style.positionY != placement.y || label.layout.style.width.value != placement.width) {
					tip.layout.style.positionX = placement.x;
					tip.layout.style.positionY = placement.y;
					label.layout.style.width = LayoutAxis.fixed(placement.width);
					context.requestLayoutFeedback();
				}
			});
			// The overlay must never extend the tab's hover area into the editor.
			tip.walk(function(node) { node.hitTestSelf = false; });
			root.add(tip);
			header.on(UiEventKind.HoverEnter, function(_) delay.start());
			header.on(UiEventKind.HoverLeave, function(_) delay.cancel());
			header.on(UiEventKind.PointerDown, function(_) delay.cancel(), "capture");
			return root;
		});
	}
}
