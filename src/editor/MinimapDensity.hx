package editor;

/** Screen-space preview density, independent of editor text size and workbench zoom. */
class MinimapDensity {
	public final rowPitch:Float;
	public final markHeight:Int;
	public final rasterScale:Float;

	function new(zoom:Float) {
		rowPitch = 1.0 / zoom;
		markHeight = 1;
		rasterScale = zoom;
	}

	public static function resolve(applicationZoom:Float = 1.0):MinimapDensity {
		var zoom = applicationZoom > 0 && applicationZoom - applicationZoom == 0 ? applicationZoom : 1.0;
		return new MinimapDensity(zoom);
	}
}
