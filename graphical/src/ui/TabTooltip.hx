package ui;

import haxeon.ui.widgets.overlays.TooltipHoverGroup;

import haxeon.ui.Rect;
import haxeon.ui.core.View;
import haxeon.ui.widgets.overlays.Tooltip;
import haxeon.ui.widgets.overlays.TooltipPlacement;

/** Editor defaults for UIKit's positioned tooltip. */
class TabTooltip extends Tooltip {
	public function new(key:String, anchor:View, content:View, boundsProvider:Void->Rect,
			delaySeconds:Float = config.Settings.DEFAULT_TOOLTIP_DELAY, placement:TooltipPlacement = Below,
			?hoverGroup:TooltipHoverGroup, groupVisible:Bool = false) {
		super(key, anchor, content);
		this.boundsProvider = boundsProvider;
		this.delaySeconds = delaySeconds;
		this.placement = placement;
		this.hoverGroup = hoverGroup;
		this.groupVisible = groupVisible;
	}
	public static function place(anchorX:Float, anchorHeight:Float, railX:Float, railWidth:Float,
			preferredOffset:Float = 0, ?boxWidth:Float):{x:Float, y:Float, width:Float}
		return Tooltip.place(anchorX, anchorHeight, railX, railWidth, preferredOffset, boxWidth);
	public static function placeRight(anchor:Rect, width:Float, height:Float, viewport:Rect):{x:Float, y:Float, width:Float}
		return Tooltip.placeRight(anchor, width, height, viewport);
}
