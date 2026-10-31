package devtools;

import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;

/**
	Opt-in state channel for driving the real editor with real input in test runs. Enabled only when
	`EXOSUIT_AUTOMATION_DIR` names a folder. It writes `snapshot.json` there, atomically, whenever the picture or the
	app's state changes (at most ten times a second):

	  seq, at, frame        a counter, `Sys.time()`, and the UI frame number
	  viewport              {width, height}: the UI's size in logical pixels (the driver divides the window's client
	                        size by it to get the display scale)
	  elements              every visible node with an accessibility label: {id, role, label, x, y, w, h} in logical
	                        viewport pixels. Workbench tree rows are labelled with their row keys (`g:`, `w:`, ...).
	  state                 whatever the app adds (workspaces, groups, tabs, ...), see ExosuitApp.automationState

	Positions come from here, never from fixed pixels. The driver is `docs/benchmarks/perf-harness/gui_driver.py`.
**/
class AutomationProbe {
	public static inline var ELEMENT_LIMIT = 4000;

	public final directory:String;
	final ui:UiContext;
	final state:Void->Dynamic;
	var seq = 0;
	var lastAt = 0.0;
	var lastText = "";

	public static function directoryFromEnvironment():Null<String> {
		var value = Sys.getEnv("EXOSUIT_AUTOMATION_DIR");
		return value == null || value.length == 0 ? null : value;
	}

	/**
		A folder a test run chose in place of the native folder dialog, which real input cannot drive portably: the driver
		writes the path to `pick-folder.txt` in the automation folder before it clicks the menu item that opens the dialog.
		Read once, then deleted; null when automation is off or nothing was written.
	**/
	public static function takeFolderAnswer():Null<String> {
		var directory = directoryFromEnvironment();
		if (directory == null) return null;
		var path = directory + "/pick-folder.txt";
		try {
			if (!sys.FileSystem.exists(path)) return null;
			var answer = StringTools.trim(sys.io.File.getContent(path));
			sys.FileSystem.deleteFile(path);
			return answer.length == 0 ? null : answer;
		} catch (_:Dynamic) return null;
	}

	public function new(directory:String, ui:UiContext, state:Void->Dynamic) {
		this.directory = directory; this.ui = ui; this.state = state;
		try sys.FileSystem.createDirectory(directory) catch (_:Dynamic) {}
	}

	/** Called from the host's poll; cheap when it is not time. */
	public function poll():Void {
		var now = Sys.time();
		if (now - lastAt < 0.1) return;
		lastAt = now;
		try {
			var elements:Array<Dynamic> = [];
			var width = 0.0, height = 0.0;
			var root = ui.root;
			if (root != null) {
				try { var bounds = root.globalBounds(); width = bounds.width; height = bounds.height; } catch (_:Dynamic) {}
				root.walk(function(node:RenderNode) {
					if (elements.length >= ELEMENT_LIMIT) return;
					var semantics = node.semantics;
					if (semantics == null || semantics.label == null || semantics.label.length == 0) return;
					if (node.styleType == "devtools-overlay") return;
					var geometry = node.resolved;
					if (geometry == null || !geometry.visible) return;
					try {
						var bounds = node.globalBounds();
						if (bounds.width <= 0 || bounds.height <= 0) return;
						elements.push({id: node.id.value, role: Std.string(semantics.role), label: semantics.label.substr(0, 160),
							x: bounds.x, y: bounds.y, w: bounds.width, h: bounds.height});
					} catch (_:Dynamic) {}
				});
			}
			var metrics = ui.frameMetrics;
			var payload:Dynamic = {seq: 0, at: 0.0, frame: metrics == null ? -1 : metrics.frameNumber, viewport: {width: width, height: height},
				elements: elements, state: state()};
			// Only a change is written; `seq` counts writes, so a driver can wait for "a snapshot newer than my last input".
			var body = haxe.Json.stringify({frame: payload.frame, viewport: payload.viewport, elements: elements, state: payload.state});
			if (body == lastText) return;
			lastText = body;
			payload.seq = ++seq; payload.at = now;
			var temporary = directory + "/snapshot.tmp", target = directory + "/snapshot.json";
			sys.io.File.saveContent(temporary, haxe.Json.stringify(payload));
			if (sys.FileSystem.exists(target)) sys.FileSystem.deleteFile(target); // rename does not replace on Windows
			sys.FileSystem.rename(temporary, target);
		} catch (error:Dynamic) {
			try sys.io.File.saveContent(directory + "/probe-error.txt", Std.string(error)) catch (_:Dynamic) {}
		}
	}
}
