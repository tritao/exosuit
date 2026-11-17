package workspace.transport;

/**
	Keeps the process's timer at 1 ms resolution for a while (Windows). NativeKit's local pipes are polled: a transport
	thread looks for data every 5 ms, and at Windows' default 15.6 ms timer resolution each of those looks comes up to a
	whole tick late, so every hop of a request costs up to 16 ms. NativeKit holds 1 ms only while the main thread waits,
	which an editor drawing frames seldom does. While a connection is made or used (`hold`), a helper thread sleeps in
	short steps; HashLink's sleep holds 1 ms resolution for its duration, and with it the whole process.
**/
class FineTimer {
	#if !wasm
	static var until = 0.0;
	static var running = false;
	static final mutex = new sys.thread.Mutex();
	#end

	/** Holds 1 ms resolution for `seconds` more (from now). Nothing elsewhere than on Windows. */
	public static function hold(seconds:Float):Void {
		#if !wasm
		if (Sys.systemName() != "Windows") return;
		mutex.acquire();
		var end = Sys.time() + seconds;
		if (end > until) until = end;
		var start = !running;
		running = true;
		mutex.release();
		if (start)
			sys.thread.Thread.create(function() {
				while (true) {
					Sys.sleep(0.02);
					mutex.acquire();
					var done = Sys.time() >= until;
					if (done) running = false;
					mutex.release();
					if (done) return;
				}
			});
		#end
	}
}
