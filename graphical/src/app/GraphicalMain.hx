package app;

import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import ui.ExosuitApp;
import ui.ExosuitPalette;

/** Hosted desktop entry. UIKit owns the window, GPU, and frame loop. */
class GraphicalMain {
	static function main():Int {
		var startupMemory = Sys.getEnv("EXOSUIT_STARTUP_MEMORY_DIR");
		if (startupMemory != null) StartupMemory.sample(startupMemory, "01-runtime");
		var arguments = Sys.args();
		var pluginManifest:Null<String> = null;
		var captureDirectory:Null<String> = null;
		var frameLimit = 0;
		var captureSeconds = 0.0;
		var recordPath:Null<String> = null;
		var openTerminal = false;
		var openTerminalBrowser = false;
		var openWorkbench = false;
		var themeChoice = "system";
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
			else if (argument == "--open-workbench")
				openWorkbench = true;
			else if (argument == "--open-workspace-terminals")
				openTerminalBrowser = true;
			else if (argument == "--open-terminal")
				openTerminal = true;
			else if (StringTools.startsWith(argument, "--theme="))
				themeChoice = argument.substring(8);
			else if (!StringTools.startsWith(argument, "--"))
				openPaths.push(argument);
		}
		var host = new DesktopUiHostOptions();
		host.title = "exosuit";
		host.customTitlebar = true;
		host.width = 1280;
		host.height = 840;
		host.captureDirectory = captureDirectory;
		host.frameLimit = frameLimit;
		host.captureSeconds = captureSeconds;
		host.recordPath = recordPath;
		var allocationProfile = Sys.getEnv("EXOSUIT_ALLOCATION_PROFILE");
		var profileFrames = 0;
		var reportedFirstFrame = false;
		var memoryFrames = 0;
		host.captureReady = function() {
			if (startupMemory != null) {
				memoryFrames++;
				if (memoryFrames == 1) StartupMemory.sample(startupMemory, "03-first-frame");
				if (memoryFrames == 20) {
					StartupMemory.sample(startupMemory, "04-warm-startup");
					StartupMemory.dump(startupMemory);
					StartupMemory.sample(startupMemory, "05-after-gc-dump");
				}
			}
			if (allocationProfile != null) {
				profileFrames++;
				// Skip warm-up and exclude serialization of capture diagnostics.
				if (profileFrames == 20) hl.Gc.censusReset();
				if (frameLimit > 0 && profileFrames >= frameLimit) hl.Gc.censusStop();
			}
			if (recordPath != null && !reportedFirstFrame) {
				reportedFirstFrame = true;
				Sys.println("exosuit: first frame ready");
				Sys.stdout().flush();
			}
			return true;
		};
		var app:Null<ExosuitApp> = null;
		var terminalWorkspaces:Null<workspace.client.LocalTerminalWorkspacePool> = null;
		var session = DesktopUiHost.open(host, function(context) {
			var dark = prefersDark(themeChoice);
			var workspaceClient:Null<workspace.client.LocalWorkspaceClient> = null;
			var instance = new ExosuitApp(context.fonts, ExosuitPalette.theme(dark), context,
				openPaths.length == 0 ? null : openPaths[0], null,
				new NativeDesktopServices(context), dark, ui.TerminalPane.open,
				(Sys.systemName() == "Linux" || Sys.systemName() == "Windows") ? function(id,cwd,restored,requestFrame,palette,group,directory)
					return ui.TerminalPane.openRemote(function() return terminalWorkspaces == null ? null : terminalWorkspaces.endpoint(cwd),id,cwd,restored,requestFrame,palette,group,directory,null,true) : null);
			if (Sys.systemName() == "Linux" || Sys.systemName() == "Windows") {
				try {
					workspaceClient = new workspace.client.LocalWorkspaceClient(context.events, instance.application.processes,
						workspace.client.LocalWorkspaceClient.findLauncher(), function() return NativeKit.nk_time_seconds() * 1000);
					terminalWorkspaces = new workspace.client.LocalTerminalWorkspacePool(context.events, instance.application.processes,
						workspace.client.LocalWorkspaceClient.findLauncher(), function() return NativeKit.nk_time_seconds() * 1000);
					instance.attachWorkspace(workspaceClient);
					instance.attachWorkbench(workspaceClient);
					instance.attachRemoteAccess(workspaceClient);
				}
				catch (failure:Dynamic)
					instance.application.reportError("workspace", Std.string(failure));
			}
			for (index in 1...openPaths.length) instance.application.openArgument(openPaths[index]);
			if (openTerminal) instance.openTerminal();
			if (openTerminalBrowser) instance.openWorkspaceTerminals();
			if (openWorkbench) instance.showSidebarMode("workbench");
			if (pluginManifest != null && !instance.application.loadPluginManifest(pluginManifest))
				Sys.println('exosuit: could not load plugin manifest "$pluginManifest"');
			var applicationPoll = context.onPoll;
			context.onPoll = function() {
				if (terminalWorkspaces != null) terminalWorkspaces.poll();
				if (applicationPoll != null) applicationPoll();
				if (terminalWorkspaces != null) terminalWorkspaces.retainRoots(
					[for (terminal in instance.host.allTerminalTabs()) if (terminal.remote && !terminal.disposed) terminal.workspaceRoot]);
			};
			app = instance;
			if (startupMemory != null) StartupMemory.sample(startupMemory, "02-app-created");
			return instance;
		});
		if (recordPath != null) {
			Sys.println("exosuit: window ready");
			Sys.stdout().flush();
		}
		// Optional allocation census, excluding window/application construction.
		if (allocationProfile != null) hl.Gc.censusStart(16384);
		while (session.tick()) {}
		if (terminalWorkspaces != null) terminalWorkspaces.dispose();
		if (allocationProfile != null) {
			hl.Gc.censusStop();
			var encoded = haxe.io.Bytes.ofString(allocationProfile);
			var terminated = haxe.io.Bytes.alloc(encoded.length + 1);
			terminated.blit(0, encoded, 0, encoded.length);
			hl.Gc.censusDump(AllocationProfileBytes.data(terminated));
		}
		var status = session.close();
		return status;
	}

	static function prefersDark(choice:String):Bool {
		if (choice == "dark") return true;
		if (choice == "light") return false;
		if (choice != "system") throw 'Unknown theme "$choice" (use system, light, or dark)';
		try {
			var appearance = new SystemAppearance();
			appearance.set_struct_size(32);
			NativeKit.nk_system_get_appearance(appearance);
			return Std.int(appearance.get_color_scheme()) != 1;
		} catch (_:Dynamic) {
			return true;
		}
	}
}

private extern class AllocationProfileBytes {
	@:hlNative("haxeon_runtime", "__bytes_get_data")
	public static function data(bytes:haxe.io.Bytes):hl.Bytes;
}
