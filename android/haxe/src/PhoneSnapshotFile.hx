import haxeon.ui.core.UiContext;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function preparePrivateDirectory(path:String):Bool;

/**
	The phone's automation surface for its test scripts (android/scripts/phone-ui.ps1, machine-acceptance.ps1,
	docs/benchmarks/perf-harness/gui_scenarios/e2e_pair.py). A desktop window is driven over suit's control plane
	(`exosuit.ui.snapshot`); a phone has no suit to link to, so a debug build that a test run set up
	(`EXOSUIT_AUTOMATION_DIR`, see ExosuitActivity) writes the same picture, devtools.UiSnapshot plus the app's state, to
	`snapshot.json` in that folder whenever it changes (at most ten times a second, and at least once a second so `at`
	says how fresh it is). `seq` counts writes, so a script can wait for a snapshot newer than its last tap.
**/
class PhoneSnapshotFile {
	final directory:String;
	final ui:UiContext;
	final state:Void->Dynamic;
	var seq = 0;
	var lastAt = 0.0;
	var lastText = "";
	var lastWrite = 0.0;
	var usable = true;

	/** The file's folder when a test run asked for one, else null. */
	public static function directoryFromEnvironment():Null<String> {
		var value = Sys.getEnv("EXOSUIT_AUTOMATION_DIR");
		return value == null || value.length == 0 ? null : value;
	}

	public function new(directory:String, ui:UiContext, state:Void->Dynamic) {
		this.directory = directory;
		this.ui = ui;
		this.state = state;
		// The snapshot holds the app's state and file names: the folder is owner-only, or nothing is written.
		try usable = preparePrivateDirectory(directory) catch (_:Dynamic) usable = false;
	}

	/** Called from the host's poll; cheap when it is not time. */
	public function poll():Void {
		if (!usable) return;
		var now = Sys.time();
		if (now - lastAt < 0.1) return;
		lastAt = now;
		try {
			var picture:Dynamic = devtools.UiSnapshot.capture(ui);
			picture.state = state();
			var body = haxe.Json.stringify(picture);
			if (body == lastText && now - lastWrite < 1.0) return;
			lastText = body;
			lastWrite = now;
			var text = '{"seq":' + (++seq) + ',"at":' + now + ',' + body.substr(1);
			// Android refuses the runtime's atomic publish in the app's files directory; a rename is as atomic on POSIX.
			var target = directory + "/snapshot.json", staged = target + ".tmp";
			sys.io.File.saveContent(staged, text);
			sys.FileSystem.rename(staged, target);
		} catch (error:Dynamic) {
			try sys.io.File.saveContent(directory + "/probe-error.txt", Std.string(error)) catch (_:Dynamic) {}
		}
	}
}
