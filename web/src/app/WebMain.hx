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
import ui.ExosuitPalette;
import platform.HostCapabilities;
import workspace.client.RemoteMachines;
import workspace.service.WorkspaceTerminalProtocol;
import sys.FileSystem;
import sys.io.File;
import ui.ExosuitApp;

class WebMain {
	static var width = 1280;
	static var height = 840;
	static var session:Null<BrowserUiHostSession>;
	static var editor:Null<ExosuitApp>;
	static var remoteAccess:Null<RemoteMachines>;
	static var pairedMachines:Null<BrowserPairedMachines>;

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
			ui.TerminalSymbolFont.addTo(context.fonts);
			var browserApp:Null<ExosuitApp> = null;
			var redraw = function() {
				if (browserApp == null) context.requestFrame(); else browserApp.requestFrame();
			};
			// The browser is a paired device like the phone: RemoteMachines over exohost's machine relay, its pairings in IndexedDB.
			var store = new BrowserPairedMachines();
			pairedMachines = store;
			var remote = new RemoteMachines(context.events, function() return NativeKit.nk_time_seconds() * 1000, store, redraw);
			var app = new ExosuitApp(context.fonts, ExosuitPalette.theme(false), context, "/workspace", HostCapabilities.browser(), null, false, null,
				function(id, cwd, restored, requestFrame, palette, group, directory)
					return ui.TerminalPane.openRemote(function() return remote, id, cwd, restored,
						requestFrame, palette, group, directory, context.fonts, !restored));
			browserApp = app;
			remoteAccess = remote;
			var machines = new ui.DeviceWorkbenchMachine(app, remote);
			app.attachWorkbenchMachine(machines);
			var remotePanel = new ui.RemoteMachinesPanel(remote, redraw);
			store.load(function(unreadable) {
				remote.connectSaved(unreadable);
				redraw();
			});
			var filesAttached = false;
			var attachedWorkbench:Null<workspace.client.WorkspaceWorkbenchClient> = null;
			// ExosuitApp owns service/explorer polling once the workspace is attached.
			// Preserve it when adding the browser connection lifecycle callback.
			var pollEditor = context.onPoll;
			context.onPoll = function() {
				if (pollEditor != null) pollEditor();
				machines.poll();
				// Keep projections attached while a known workspace reconnects. Their
				// clients disable mutations until the new authenticated connection is ready.
				var identified = remote.fileScope() != null;
				var filesAvailable = identified && remote.hasCapability(workspace.service.WorkspaceFileProtocol.READ);
				if (filesAvailable && !filesAttached) {
					filesAttached = true;
					app.attachWorkspace(remote);
					app.activateSidebarDestination("files");
				} else if (!filesAvailable && filesAttached) {
					filesAttached = false;
					app.detachWorkspace(remote);
					app.activateSidebarDestination("remote-access");
				}
				var workbenchAvailable = identified && remote.hasCapability(WorkspaceTerminalProtocol.READ)
					&& remote.hasCapability(WorkspaceTerminalProtocol.CATALOG);
				// The Workbench reads the open workspace's link: another workspace opened is another client.
				var wanted = workbenchAvailable ? remote.workbenchService() : null, attached = attachedWorkbench;
				if (attached != wanted) {
					if (attached != null) app.detachWorkbench(attached);
					attachedWorkbench = wanted;
					if (wanted != null) app.attachWorkbench(wanted);
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
			hostError: session == null || session.error == null ? null : {
				stage: session.error.stage,
				message: session.error.message,
				stack: session.error.stack
			},
			remoteAccess: remoteAccess == null ? null : remoteAccess.automationState()
		}));
		return 0;
	}

	@:expose public static function openDocumentation():Int {
		return NativeKit.nk_shell_open_url("https://github.com/tritao/exosuit") == Result.Ok ? 0 : 1;
	}

	/** Completion callback for IndexedDB credential persistence in the browser host. */
	@:expose public static function remoteCredentialStored(request:Int, success:Int):Int {
		var store = pairedMachines;
		if (store == null) return 1;
		store.stored(request, success != 0);
		return 0;
	}

	/** IndexedDB metadata and credentials cross the browser boundary as bounded ASCII chunks. */
	@:expose public static function remoteStorePayloadChunk(request:Int, kind:Int, index:Int, value:Int):Int {
		var store = pairedMachines;
		if (store == null) return 1;
		store.chunk(request, kind, index, value);
		return 0;
	}

	@:expose public static function remoteStorePayloadComplete(request:Int, kind:Int, length:Int, success:Int):Int {
		var store = pairedMachines;
		if (store == null) return 1;
		store.complete(request, kind, length, success != 0);
		return 0;
	}
}
