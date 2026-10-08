package process;

/** Bounded, asynchronous access to a retained Linux crash report. Never invokes a shell or debugger. */
class CrashReportReader {
	public var text(default, null):String = "";
	public var loading(default, null):Bool = false;
	public var revision(default, null):Int = 0;
	final manager:ProcessManager;
	var child:Null<OwnedProcess>;
	var deadline:Float;
	static inline final LIMIT = 65536;

	public function new(manager:ProcessManager) this.manager = manager;

	public function open(pid:Int):Void {
		close();
		text = "";
		revision++;
		if (pid <= 0 || Sys.systemName() != "Linux" || !manager.available) {
			text = "Retained crash reports are unavailable on this host.";
			return;
		}
		try {
			child = manager.start("coredumpctl", ["info", Std.string(pid), "--no-pager"], "",
				["SYSTEMD_COLORS" => "0", "SYSTEMD_PAGER" => "cat"]);
			child.closeStdin();
			loading = true;
			deadline = Sys.time() + 10;
		} catch (error:Dynamic) text = "Could not open crash report: " + Std.string(error);
	}

	public function poll():Void {
		var process = child;
		if (process == null) return;
		try {
			for (_ in 0...16) {
				var chunk = process.readStdout() + process.readStderr();
				if (chunk == "") break;
				text += chunk;
				revision++;
				if (text.length >= LIMIT) {
					text = text.substr(0, LIMIT) + "\n[Report truncated]";
					close();
					return;
				}
			}
			if (process.exited()) {
				var status = process.exitStatus();
				if (text == "") text = status == 0 ? "No crash report was returned." : "Crash report is unavailable or access was denied.";
				close();
			} else if (Sys.time() >= deadline) {
				text += "\n[Timed out reading crash report]";
				close();
			}
		} catch (error:Dynamic) {
			text += "\nCould not read crash report: " + Std.string(error);
			close();
		}
	}

	public function close():Void {
		var process = child;
		child = null;
		if (process != null) manager.release(process);
		loading = false;
		revision++;
	}
}
