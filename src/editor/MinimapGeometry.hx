package editor;

/** Shared forward/inverse mapping for a scrolling preview and its viewport thumb. */
class MinimapGeometry {
	public final scrollRange:Float;
	public final thumbHeight:Float;
	public final thumbTravel:Float;
	public final previewTravel:Float;
	final lineMap:Null<MinimapLineMap>;
	final scale:Float;
	final viewportHeight:Float;
	final height:Float;
	final mappedMaximum:Float;

	public function new(height:Float, contentHeight:Float, viewportHeight:Float, scale:Float, ?lineMap:MinimapLineMap) {
		this.lineMap = lineMap; this.scale = scale; this.viewportHeight = viewportHeight;
		this.height = Math.max(0, height);
		height = Math.max(0, height);
		scrollRange = Math.max(0, contentHeight - viewportHeight);
		mappedMaximum = previewAt(scrollRange);
		thumbHeight = thumbHeightAt(0);
		// Short previews occupy only their natural height; long previews scroll.
		thumbTravel = scrollRange <= 0 ? 0 : Math.max(0, Math.min(height, previewAt(contentHeight)) - thumbHeight);
		previewTravel = Math.min(mappedMaximum, Math.max(0, previewAt(contentHeight) - height));
	}

	public function thumbTop(offset:Float):Float {
		return lineMap == null ? (scrollRange <= 0 ? 0 : clamp(offset / scrollRange) * thumbTravel) : previewAt(Math.max(0, Math.min(scrollRange, offset))) - previewOffset(offset);
	}

	public function previewOffset(offset:Float):Float {
		return mappedMaximum <= 0 ? 0 : clamp(previewAt(Math.max(0, Math.min(scrollRange, offset))) / mappedMaximum) * previewTravel;
	}

	public function scrollAt(top:Float):Float {
		if (lineMap == null) return thumbTravel <= 0 ? 0 : clamp(top / thumbTravel) * scrollRange;
		var travel = mappedMaximum - previewTravel;
		return travel <= 0 ? 0 : Math.max(0, Math.min(scrollRange, lineMap.sourceAt(clamp(top / travel) * mappedMaximum, scale)));
	}

	function previewAt(y:Float):Float return lineMap == null ? y * scale : lineMap.previewAt(y, scale);

	public function thumbHeightAt(offset:Float):Float
		return Math.min(height, Math.max(2, previewAt(offset + viewportHeight) - previewAt(offset)));

	static function clamp(value:Float):Float return Math.max(0, Math.min(1, value));
}
