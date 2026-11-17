package ui;

/**
	Frames the window rendered per second, read once a second of wall time. The window renders only when something
	changes, so an idle window reads about 1 fps: the frame that shows the new reading.
**/
class FrameRateMeter {
	/** The latest reading; -1 before the first full second. */
	public var fps(default, null):Int = -1;

	var frames = 0;
	var since = -1.0;

	public function new() {}

	public function frameRendered():Void
		frames++;

	/** Takes a reading when a second has passed since the last one; true when it did. */
	public function sample(now:Float):Bool {
		if (since < 0.0) {
			since = now;
			frames = 0;
			return false;
		}
		var elapsed = now - since;
		if (elapsed < 1.0) return false;
		var reading = Math.round(frames / elapsed);
		frames = 0;
		since = now;
		fps = reading;
		return true;
	}

	public function label():String
		return fps < 0 ? "" : fps + " fps";
}
