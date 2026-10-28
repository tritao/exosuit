package app;

import haxe.io.Bytes;

import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostSession;
import haxeon.ui.host.DesktopUiHostOptions;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import ui.ExosuitApp;
import ui.ExosuitPalette;

/**
	Hosted desktop entry. UIKit owns the window, GPU, and frame loop.

	`main` runs the loop itself. `haxeon run --watch --live` instead calls `start`, then `tick` until it
	returns 0, then `close`, and patches changed functions between ticks without restarting the editor.
**/
class GraphicalMain {
	static var session:Null<DesktopUiHostSession> = null;
	static var terminalWorkspaces:Null<workspace.client.LocalTerminalWorkspacePool> = null;
	static var allocationProfile:Null<String> = null;
	static var inspection:Null<devtools.InspectionAgent> = null;
	static var devtoolsProcess:Null<sys.io.ChildProcess> = null;
	static final devtoolsOutput:haxe.io.Bytes = haxe.io.Bytes.alloc(4096);

	static function main():Int {
		open(Sys.args());
		while (tick() != 0) {}
		return close();
	}

	@:keep public static function start(arguments:String):Void
		open(haxe.Json.parse(arguments));

	@:keep public static function tick():Int {
		var current = session;
		return current != null && current.tick() ? 1 : 0;
	}

	@:keep public static function close():Int {
		var current = session;
		if (current == null) return 0;
		session = null;
		suit.SuitClient.unregister();
		if (inspection != null) {
			var target:devtools.InspectionAgent = cast inspection;
			var endpoint = target.path;
			inspection.dispose(); inspection = null; devtools.DevToolsEndpoint.cleanup(endpoint);
		}
		var workspaces = terminalWorkspaces;
		terminalWorkspaces = null;
		if (workspaces != null) workspaces.dispose();
		var profile = allocationProfile;
		if (profile != null) {
			hl.Gc.censusStop();
			var encoded = haxe.io.Bytes.ofString(profile);
			var terminated = haxe.io.Bytes.alloc(encoded.length + 1);
			terminated.blit(0, encoded, 0, encoded.length);
			hl.Gc.censusDump(AllocationProfileBytes.data(terminated));
		}
		return current.close();
	}

	/** A structural live reload reopens the window; tabs and layout come back from the editor's session file. */
	@:keep public static function saveState():String
		return "";

	@:keep public static function restoreState(state:String):Void {}

	static function open(arguments:Array<String>):Void {
		var startupMemory = Sys.getEnv("EXOSUIT_STARTUP_MEMORY_DIR");
		if (startupMemory != null) StartupMemory.sample(startupMemory, "01-runtime");
		var pluginManifest:Null<String> = null;
		var captureDirectory:Null<String> = null;
		var frameLimit = 0;
		var captureSeconds = 0.0;
		var recordPath:Null<String> = null;
		var inputScriptPath:Null<String> = null;
		var openTerminal = false;
		var openTerminalBrowser = false;
		var openWorkbench = false;
		var themeChoice = "system";
		var titleOverride:Null<String> = null;
		var openPaths:Array<String> = [];
		for (argument in arguments) {
			if (StringTools.startsWith(argument, "--input-script="))
				inputScriptPath = argument.substring(15);
			else if (StringTools.startsWith(argument, "--plugin="))
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
			else if (StringTools.startsWith(argument, "--title="))
				titleOverride = argument.substring(8);
			else if (!StringTools.startsWith(argument, "--"))
				openPaths.push(argument);
		}
		// Settle EXOSUIT_SUIT once, before anything is spawned, then tell the per-user suit daemon (the tray
		// icon) this editor is running; never blocks or throws.
		suit.SuitClient.resolve();
		suit.SuitClient.announceEditor();
		var host = new DesktopUiHostOptions();
		var stableChannel = Sys.getEnv("EXOSUIT_CHANNEL") == "stable";
		host.applicationId = stableChannel ? "Exosuit.Stable" : "Exosuit.Desktop";
		// A benchmark names its window, so its capture screenshots that window rather than another exosuit's.
		host.title = titleOverride != null && titleOverride.length > 0 ? titleOverride : stableChannel ? "Exosuit Stable" : "exosuit";
		host.icons = ApplicationIcons.create();
		host.customTitlebar = true;
		host.width = 1280;
		host.height = 840;
		host.minimumWidth = 320;
		host.minimumHeight = 200;
		host.captureDirectory = captureDirectory;
		host.frameLimit = frameLimit;
		host.captureSeconds = captureSeconds;
		host.recordPath = recordPath;
		host.inputScriptPath = inputScriptPath;
		allocationProfile = Sys.getEnv("EXOSUIT_ALLOCATION_PROFILE");
		var profileFrames = 0;
		var reportedFirstFrame = false;
		var memoryFrames = 0;
		host.captureReady = function() {
			if (inspection != null) inspection.recordFrame();
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
		session = DesktopUiHost.open(host, function(context) {
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
			instance.context().commands.register(new haxeon.ui.core.Command("devtools.open", "Developer: Open DevTools", function() {
				try {
					var projectRoot = Sys.getEnv("EXOSUIT_PROJECT_ROOT");
					if (projectRoot == null) throw "Launch through scripts/run.py to locate DevTools";
					if (inspection == null) {
						var endpoint = devtools.DevToolsEndpoint.create();
						inspection = new devtools.InspectionAgent(endpoint, context, instance.context());
					}
					if (devtoolsProcess != null && devtoolsProcess.pollExit() == -1) return;
					if (devtoolsProcess != null) devtoolsProcess.close();
					var python = Sys.getEnv("EXOSUIT_HAXEON_CLI_PYTHON");
					var activeInspection:devtools.InspectionAgent = cast inspection;
					var toolArguments = [projectRoot + "/scripts/devtools.py", "--endpoint=" + activeInspection.path];
					var profilerPort = Sys.getEnv("EXOSUIT_DEVTOOLS_PROFILER_PORT");
					if (profilerPort != null) toolArguments.push("--profiler-port=" + profilerPort);
					devtoolsProcess = sys.io.Process.spawn(python == null ? "python3" : python,
						toolArguments, projectRoot);
				} catch (error:Dynamic) instance.application.reportError("devtools", Std.string(error));
			}));
			context.onPoll = function() {
				if (inspection != null) inspection.poll();
				if (devtoolsProcess != null) {
					devtoolsProcess.readStdout(devtoolsOutput, 0, devtoolsOutput.length);
					var count = devtoolsProcess.readStderr(devtoolsOutput, 0, devtoolsOutput.length);
					if (count > 0) Sys.println(devtoolsOutput.getString(0, count));
					var code = devtoolsProcess.pollExit();
					if (code != -1) {
						devtoolsProcess.close(); devtoolsProcess = null;
						if (code != 0) instance.application.reportError("devtools", "DevTools exited with status " + code);
					}
				}
				if (terminalWorkspaces != null) terminalWorkspaces.poll();
				if (applicationPoll != null) applicationPoll();
				if (terminalWorkspaces != null) terminalWorkspaces.retainRoots(
					[for (terminal in instance.host.allTerminalTabs()) if (terminal.remote && !terminal.disposed) terminal.workspaceRoot]);
			};
			if (arguments.indexOf("--open-devtools") >= 0) instance.context().commands.execute("devtools.open");
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
