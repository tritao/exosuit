package editor;

/** Shared forward/inverse mapping for a scrolling preview and its viewport thumb. */
class MinimapGeometry {
	public final scrollRange:Float;
	public final thumbHeight:Float;
	public final thumbTravel:Float;
	public final previewTravel:Float;

	public function new(height:Float, contentHeight:Float, viewportHeight:Float, scale:Float) {
		height = Math.max(0, height);
		scrollRange = Math.max(0, contentHeight - viewportHeight);
		thumbHeight = Math.min(height, Math.max(2, viewportHeight * scale));
		// Short previews occupy only their natural height; long previews scroll.
		thumbTravel = scrollRange <= 0 ? 0 : Math.max(0, Math.min(height, contentHeight * scale) - thumbHeight);
		previewTravel = Math.max(0, contentHeight * scale - height);
	}

	public function thumbTop(offset:Float):Float {
		return scrollRange <= 0 ? 0 : clamp(offset / scrollRange) * thumbTravel;
	}

	public function previewOffset(offset:Float):Float {
		return scrollRange <= 0 ? 0 : clamp(offset / scrollRange) * previewTravel;
	}

	public function scrollAt(top:Float):Float {
		return thumbTravel <= 0 ? 0 : clamp(top / thumbTravel) * scrollRange;
	}

	static function clamp(value:Float):Float return Math.max(0, Math.min(1, value));
}
