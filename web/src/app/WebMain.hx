package app;

import haxeon.ui.FontFamily;
import haxeon.ui.core.Command;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.ui.icons.IconName;
import haxeon.ui.host.BrowserUiHost;
import haxeon.ui.host.BrowserUiHostOptions;
import haxeon.ui.host.BrowserUiHostOptions.BrowserUiFontAsset;
import haxeon.ui.host.BrowserUiHostSession;
import haxeon.ui.host.UiHostSession.UiHostLifecycle;
import haxeon.ui.theme.Theme;
import platform.HostCapabilities;
import app.BrowserRemoteAccessPanel;
import app.BrowserRemoteWorkspaceClient;
import sys.FileSystem;
import sys.io.File;
import ui.ExosuitApp;

class WebMain {
	static var width = 1280;
	static var height = 840;
	static var session:Null<BrowserUiHostSession>;
	static var editor:Null<ExosuitApp>;
	static var remoteAccess:Null<BrowserRemoteWorkspaceClient>;

	@:expose public static function configure(canvasWidth:Int, canvasHeight:Int):Int {
		if (session != null || canvasWidth <= 0 || canvasHeight <= 0) return 1;
		width = canvasWidth;
		height = canvasHeight;
		return 0;
	}

	@:expose public static function main():Int {
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
			var remote = new BrowserRemoteWorkspaceClient(context.events,
				function() return NativeKit.nk_time_seconds() * 1000,
				function() context.requestFrame());
			remoteAccess = remote;
			var remotePanel = new BrowserRemoteAccessPanel(remote, function() context.requestFrame());
			var remoteAttached = false;
			context.onPoll = function() {
				if (!remoteAttached) remote.poll();
				var connected = remote.isWorkspaceConnected() && remote.canReadFiles();
				if (connected && !remoteAttached) {
					remoteAttached = true;
					app.attachWorkspace(remote);
					app.activateSidebarDestination("files");
				} else if (!connected && remoteAttached) {
					remoteAttached = false;
					app.detachWorkspace(remote);
					app.activateSidebarDestination("remote-access");
				}
			};
			app.registerSidebarDestination("remote-access", IconName.Radar, function() return remotePanel,
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Remote Access", 30, true));
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
			shell: app.diagnosticState(),
			remoteAccess: remoteAccess == null ? null : {
				status: remoteAccess.status,
				error: remoteAccess.error,
				authenticationCode: remoteAccess.authenticationCode,
				codeConfirmed: remoteAccess.codeConfirmed,
				connecting: remoteAccess.connecting,
				workspaceRoot: remoteAccess.workspaceRoot,
				grants: remoteAccess.grants,
				savedDevices: remoteAccess.savedDevices
			}
		}));
		return 0;
	}

	@:expose public static function openDocumentation():Int {
		return NativeKit.nk_shell_open_url("https://github.com/tritao/exosuit") == Result.Ok ? 0 : 1;
	}

	/** Completion callback for IndexedDB credential persistence in the browser host. */
	@:expose public static function remoteCredentialStored(request:Int, success:Int):Int {
		var client = remoteAccess;
		if (client == null) return 1;
		client.credentialStored(request, success != 0);
		return 0;
	}

	/** IndexedDB metadata and credentials cross the browser boundary as bounded ASCII chunks. */
	@:expose public static function remoteStorePayloadChunk(request:Int, kind:Int, index:Int, value:Int):Int {
		var client = remoteAccess;
		if (client == null) return 1;
		client.receiveStorePayloadChunk(request, kind, index, value);
		return 0;
	}

	@:expose public static function remoteStorePayloadComplete(request:Int, kind:Int, length:Int, success:Int):Int {
		var client = remoteAccess;
		if (client == null) return 1;
		client.receiveStorePayloadComplete(request, kind, length, success != 0);
		return 0;
	}
}
