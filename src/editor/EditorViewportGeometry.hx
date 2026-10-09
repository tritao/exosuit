package editor;

/** Retained editor dimensions in source coordinates, shared by all scroll consumers. */
class EditorViewportGeometry {
	public var viewportWidth(default, null):Float = 0;
	public var viewportHeight(default, null):Float = 0;
	public var contentWidth(default, null):Float = 0;
	public var contentHeight(default, null):Float = 0;
	public var minimapWidth(default, null):Float = 0;
	public var lineHeight(default, null):Float = 21;
	public var wordWrap(default, null):Bool = false;
	var sourceWidth:Float = 0;
	var sourceHeight:Float = 0;
	var minimapEnabled:Bool = true;

	public function new() {}

	public function configure(wrap:Bool, minimap:Bool):Void {
		wordWrap = wrap; minimapEnabled = minimap; recompute();
	}

	public function setViewport(width:Float, height:Float):Void {
		viewportWidth = Math.max(0, width); viewportHeight = Math.max(0, height); recompute();
	}

	public function resolveSource(width:Float, height:Float, lineHeight:Float):Void {
		sourceWidth = Math.max(0, width); sourceHeight = Math.max(0, height);
		this.lineHeight = Math.max(1, lineHeight); recompute();
	}

	function recompute():Void {
		minimapWidth = minimapEnabled && viewportWidth >= 480 ? 88 : 0;
		contentWidth = wordWrap ? viewportWidth : Math.max(viewportWidth, sourceWidth + minimapWidth + 12);
		contentHeight = Math.max(viewportHeight, sourceHeight + trailingSpace());
	}

	public function trailingSpace():Float return lineHeight * 5;
	public function rightPadding():Float return wordWrap ? minimapWidth : 0;
	public function usableWidth():Float return Math.max(0, viewportWidth - minimapWidth);
	public function maxScrollX():Float return Math.max(0, contentWidth - viewportWidth);
	public function maxScrollY():Float return Math.max(0, contentHeight - viewportHeight);
	public function overlapsMinimap(offsetX:Float):Bool return minimapWidth > 0 && !wordWrap && maxScrollX() - offsetX > 0.5;
	public function minimapScale(zoom:Float):Float return MinimapDensity.resolve(zoom).rowPitch / lineHeight;
	public function minimapGeometry(height:Float, zoom:Float, ?lineMap:MinimapLineMap):MinimapGeometry
		return new MinimapGeometry(height, contentHeight, viewportHeight,
			lineMap == null ? minimapScale(zoom) : MinimapDensity.resolve(zoom).rowPitch, lineMap);

	/** Reveal a source-space caret against the unobscured viewport, using the same scroll bounds. */
	public function reveal(x:Float, top:Float, bottom:Float, offsetX:Float, offsetY:Float):{x:Float, y:Float} {
		var margin = Math.min(trailingSpace(), Math.max(0, (viewportHeight - (bottom - top)) / 2));
		var y = top < offsetY + margin ? top - margin : bottom > offsetY + viewportHeight - margin ? bottom - viewportHeight + margin : offsetY;
		var right = Math.max(6, usableWidth() - 12);
		var horizontal = x < offsetX + 6 ? x - 6 : x > offsetX + right ? x - right : offsetX;
		return {x: wordWrap ? 0 : Math.max(0, Math.min(maxScrollX(), horizontal)), y: Math.max(0, Math.min(maxScrollY(), y))};
	}
}
