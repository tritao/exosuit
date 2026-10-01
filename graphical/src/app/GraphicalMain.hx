package app;

import nativekit.ui.host.DesktopUiHost;
import nativekit.ui.host.DesktopUiHostOptions;
import nativekit.ui.theme.Theme;
import platform.Native;
import platform.Platform;
import ui.ExosuitApp;

/**
 * Graphical entry point: `DesktopUiHost` owns the window, GPU, and frame
 * loop; `ui.ExosuitApp` only supplies the view tree. This replaces the old
 * hand-rolled `Native.window_create` + `renderer.Renderer` + `Native.host_install`
 * loop, which drove the legacy pixel-drawn `view.RootView` shell that this
 * package's graphical path no longer uses (see `ui.ExosuitApp`'s doc comment).
 *
 * `ExosuitApp` now owns a `core.Application`, whose `process.ProcessManager`
 * (used by the build controller and the Haxeon language client) is backed
 * by `platform.Native`'s process functions - the same headless platform
 * layer the 14 headless tests initialize with `Platform.startHeadless()`,
 * independent of `DesktopUiHost`'s own native window/GPU layer. Without
 * this call those native process functions fail (they check the same
 * "platform is not initialized" guard a real window would), so build tasks
 * and the language server could never start.
 */
class GraphicalMain {
	static function main():Int {
		Platform.startHeadless();
		var arguments = Sys.args();
		var pluginManifest:Null<String> = null;
		var captureDirectory:Null<String> = null;
		var frameLimit = 0;
		var captureSeconds = 0.0;
		var recordPath:Null<String> = null;
		var openPaths:Array<String> = [];
		for (argument in arguments) {
			if (StringTools.startsWith(argument, "--plugin="))
				pluginManifest = argument.substring(9);
			else if (StringTools.startsWith(argument, "--capture-dir="))
				captureDirectory = argument.substring(14);
			else if (StringTools.startsWith(argument, "--capture-seconds="))
				captureSeconds = Std.parseFloat(argument.substring(18));
			else if (StringTools.startsWith(argument, "--record-path="))
				recordPath = argument.substring(14);
			else if (StringTools.startsWith(argument, "--smoke-frames="))
				frameLimit = Std.parseInt(argument.substring(15));
			else if (!StringTools.startsWith(argument, "--"))
				openPaths.push(argument);
		}
		var host = new DesktopUiHostOptions();
		host.title = "exosuit";
		host.width = 1280;
		host.height = 840;
		host.captureDirectory = captureDirectory;
		host.frameLimit = frameLimit;
		host.captureSeconds = captureSeconds;
		host.recordPath = recordPath;
		var app:Null<ExosuitApp> = null;
		var session = DesktopUiHost.open(host, function(context) {
			var instance = new ExosuitApp(context.fonts, Theme.light(), context, openPaths.length == 0 ? null : openPaths[0]);
			for (index in 1...openPaths.length) instance.application.openArgument(openPaths[index]);
			if (pluginManifest != null && !instance.application.loadPluginManifest(pluginManifest))
				Sys.println('exosuit: could not load plugin manifest "$pluginManifest"');
			app = instance;
			return instance;
		});
		if (recordPath != null) {
			Sys.println("exosuit: window ready");
			Sys.stdout().flush();
		}
		while (session.tick()) {}
		var status = session.close();
		Native.shutdown();
		return status;
	}
}
