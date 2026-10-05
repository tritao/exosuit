package app;

import haxeon.ui.FontFamily;
import haxeon.ui.core.Command;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.ui.host.BrowserUiHost;
import haxeon.ui.host.BrowserUiHostOptions;
import haxeon.ui.host.BrowserUiHostOptions.BrowserUiFontAsset;
import haxeon.ui.host.BrowserUiHostSession;
import haxeon.ui.host.UiHostSession.UiHostLifecycle;
import haxeon.ui.theme.Theme;
import platform.HostCapabilities;
import platform.Platform;
import sys.FileSystem;
import sys.io.File;
import ui.ExosuitApp;

class WebMain {
	static var width = 1280;
	static var height = 840;
	static var session:Null<BrowserUiHostSession>;
	static var editor:Null<ExosuitApp>;

	@:expose public static function configure(canvasWidth:Int, canvasHeight:Int):Int {
		if (session != null || canvasWidth <= 0 || canvasHeight <= 0) return 1;
		width = canvasWidth;
		height = canvasHeight;
		return 0;
	}

	@:expose public static function main():Int {
		Platform.startHeadless();
		FileSystem.createDirectory("/workspace");
		File.saveContent("/workspace/Main.hx", "class Main { static function main():Int { return 1; } }\n");
		var options = new BrowserUiHostOptions();
		options.title = "exosuit";
		options.width = width;
		options.height = height;
		options.fonts = [
			new BrowserUiFontAsset("IBMPlexSans-Regular", "assets/IBMPlexSans-Regular.ttf", "/assets/IBMPlexSans-Regular.ttf", FontFamily.Default),
			new BrowserUiFontAsset("IBMPlexMono-Regular", "assets/IBMPlexMono-Regular.ttf", "/assets/IBMPlexMono-Regular.ttf", FontFamily.Monospace),
			new BrowserUiFontAsset("NotoEmoji-Regular", "assets/NotoEmoji-Regular.ttf", "/assets/NotoEmoji-Regular.ttf", FontFamily.Emoji)
		];
		var started = BrowserUiHost.start(options, function(context) {
			var app = new ExosuitApp(context.fonts, Theme.light(), context, "/workspace", HostCapabilities.browser());
			app.application.openArgument("/workspace/Main.hx");
			app.application.commands.add("help:documentation", function(_) {
				if (openDocumentation() != 0) Sys.println("exosuit: could not open documentation");
			}, null, "Open Documentation");
			app.ui.commands.register(new Command("help.documentation", "Open Documentation", function() { openDocumentation(); }));
			editor = app;
			return app;
		});
		session = started;
		return started.state == UiHostLifecycle.Failed ? 1 : 0;
	}

	@:expose public static function frame(time:Float):Int {
		var active = session;
		if (active == null) return -1;
		try {
			var result = active.advance(time);
			if (result < 0) Sys.println("exosuit: " + Std.string(active.error));
			return result;
		} catch (error:Dynamic) {
			Sys.println("exosuit: " + Std.string(error));
			return -1;
		}
	}

	/** Diagnostics cross the host boundary as UTF-8 JSON, independent of the guest's value layout. */
	@:expose public static function snapshot():Int {
		var app = editor;
		if (app == null) return 1;
		var active = app.host.activeDocument();
		Sys.println("exosuit-state:" + haxe.Json.stringify({
			content: File.getContent("/workspace/Main.hx"),
			buffer: active == null ? "" : active.buffer.text,
			dirty: active == null ? false : active.dirty,
			errors: [for (entry in app.application.errors.entries) entry.message],
			commands: [for (command in app.application.commands.all()) command.name],
			shell: app.diagnosticState()
		}));
		return 0;
	}

	@:expose public static function openDocumentation():Int {
		return NativeKit.nk_shell_open_url("https://github.com/tritao/exosuit") == Result.Ok ? 0 : 1;
	}
}
