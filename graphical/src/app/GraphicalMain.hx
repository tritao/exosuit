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

	`main` runs the loop itself, after handing its paths to an open window when one takes them (LaunchForwarding).
	`haxeon run --watch --live` instead calls `start`, then `tick` until it returns 0, then `close`, and patches changed
	functions between ticks without restarting the editor; a live run always opens its own window.
**/
class GraphicalMain {
	static var session:Null<DesktopUiHostSession> = null;
	static var app:Null<ExosuitApp> = null;
	static var workspaceLinks:Null<workspace.client.WorkspaceLinks> = null;
	static var allocationProfile:Null<String> = null;
	static var inspection:Null<devtools.InspectionAgent> = null;
	/** The window's side of exohost's control plane: the methods exohost routes here, and synthetic input. */
	static var control:Null<ui.control.EditorControl> = null;
	static var devtoolsProcess:Null<sys.io.ChildProcess> = null;
	static final devtoolsOutput:haxe.io.Bytes = haxe.io.Bytes.alloc(4096);
	/** Where the window was last time; null for benchmark and capture runs, which keep the system's placement. */
	static var placementFile:Null<WindowPlacementFile> = null;
	/** Writes the state folder's logs/ui-hang.log when the UI thread stops ticking for 5 s. */
	static var hangWatchdog:Null<devtools.HangWatchdog> = null;
	static var placementReader:Null<Void->Null<haxeon.ui.host.WindowPlacement>> = null;

	static function main():Int {
		var launch = LaunchForwarding.forward(Sys.args());
		if (launch == null) return 0;
		open(launch.arguments, launch.positions);
		while (tick() != 0) {}
		return close();
	}

	@:keep public static function start(arguments:String):Void
		open(haxe.Json.parse(arguments));

	@:keep public static function tick():Int {
		var current = session;
		var watchdog = hangWatchdog;
		if (watchdog != null) watchdog.beat("tick");
		if (current != null && placementFile != null) placementFile.update(placementReader);
		return current != null && current.tick() ? 1 : 0;
	}

	@:keep public static function close():Int {
		var current = session;
		if (current == null) return 0;
		if (hangWatchdog != null) { hangWatchdog.stop(); hangWatchdog = null; }
		// A live reload closes and reopens the window: it must come back where it was, like a new run.
		if (placementFile != null) placementFile.update(placementReader, true);
		placementReader = null;
		session = null;
		app = null;
		if (control != null) { control.dispose(); control = null; }
		// exohost learns that this window closed from its link closing.
		var link = exohost.ExohostLink.instance;
		if (link != null) link.dispose();
		if (inspection != null) {
			var target:devtools.InspectionAgent = cast inspection;
			var endpoint = target.path;
			inspection.dispose(); inspection = null; devtools.DevToolsEndpoint.cleanup(endpoint);
		}
		// The window's links close with it (ExosuitApp.dispose); a second dispose is a no-op.
		var links = workspaceLinks;
		workspaceLinks = null;
		if (links != null) links.dispose();
		var profile = allocationProfile;
		if (profile != null) {
			hl.Gc.censusStop();
			hl.Gc.censusDump(profile);
		}
		return current.close();
	}

	/** A structural live reload reopens the window; tabs and layout come back from the editor's session file. */
	@:keep public static function saveState():String
		return "";

	@:keep public static function restoreState(state:String):Void {}

	/**
		Before a live patch that drops functions: let go of the UI tree and the handlers it holds, so the patch is not
		refused for closures only the old UI kept (haxeon docs/LIVE_PATCHING.md, "Stored closures").
	**/
	@:keep public static function liveRelease():Void {
		var current = app;
		if (current != null) current.releaseRetained();
	}

	/** After every live patch, applied or refused: the next frame builds the UI from the code that now runs. */
	@:keep public static function liveRebuild():Void {
		var current = app;
		if (current != null) current.requestFrame();
	}

	/** Opens the window; `positions` puts the cursor on the line the command line gave for a path (LaunchForwarding). */
	static function open(arguments:Array<String>, ?positions:Array<LaunchForwarding.LaunchPath>):Void {
		// Startup in the connect timeline (seconds since the process began), by phase: startup-main, window-open,
		// app-constructed, workspace-clients, context-started, app-built, first-frame.
		workspace.client.ConnectTimeline.mark("startup-main");
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
		var startContext:Null<String> = null;
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
				frameLimit = Std.parseInt(argument.substring(15)) ?? 0;
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
			else if (StringTools.startsWith(argument, workspace.NewWindow.ARGUMENT))
				startContext = workspace.NewWindow.contextOf([argument]);
			else if (!StringTools.startsWith(argument, "--"))
				openPaths.push(argument);
		}
		var host = new DesktopUiHostOptions();
		var stableChannel = Sys.getEnv("EXOSUIT_CHANNEL") == "stable";
		host.applicationId = stableChannel ? "Exosuit.Stable" : "Exosuit.Desktop";
		// A benchmark names its window, so its capture screenshots that window rather than another exosuit's.
		host.title = titleOverride != null && titleOverride.length > 0 ? titleOverride : stableChannel ? "Exosuit Stable" : "exosuit";
		host.icons = ApplicationIcons.create();
		host.customTitlebar = true;
		// EXOSUIT_FORM_FACTOR=phone|desktop forces a shell (ADR 0007); phone opens a 412x915 window that takes mouse input as touch.
		var formFactor = Sys.getEnv("EXOSUIT_FORM_FACTOR");
		if (formFactor != "phone" && formFactor != "desktop") formFactor = null;
		var phoneForm = formFactor == "phone";
		host.width = phoneForm ? 412 : 1280;
		host.height = phoneForm ? 915 : 840;
		if (phoneForm) haxeon.ui.core.NativeInputAdapter.mouseAsTouch = true;
		host.minimumWidth = 320;
		host.minimumHeight = 200;
		host.captureDirectory = captureDirectory;
		host.frameLimit = frameLimit;
		host.captureSeconds = captureSeconds;
		host.recordPath = recordPath;
		host.inputScriptPath = inputScriptPath;
		var benchmark = captureDirectory != null || recordPath != null || inputScriptPath != null
			|| titleOverride != null && titleOverride.length > 0;
		placementFile = benchmark || phoneForm ? null : new WindowPlacementFile();
		if (!benchmark && Sys.getEnv("EXOSUIT_HANG_WATCHDOG") != "0") {
			hangWatchdog = new devtools.HangWatchdog(devtools.HangWatchdog.defaultFile());
			hangWatchdog.start();
		}
		if (placementFile != null) host.placement = placementFile.load();
		allocationProfile = Sys.getEnv("EXOSUIT_ALLOCATION_PROFILE");
		var profileFrames = 0;
		var reportedFirstFrame = false;
		var memoryFrames = 0;
		host.captureReady = function() {
			// Runs after every rendered frame: the title bar's frame rate counts it.
			var rendering = app;
			if (rendering != null) rendering.frameRendered();
			workspace.client.ConnectTimeline.markOnce("startup-first-frame", "first-frame");
			workspace.client.ConnectTimeline.frameDrawn();
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
		if (devtools.SwitchTrace.enabled())
			host.onFrameRendered = function() {
				var current = app;
				devtools.SwitchTrace.mark("R", current == null ? "-" : current.host.layoutContextKey);
			};
		session = DesktopUiHost.open(host, function(context) {
			placementReader = context.windowPlacement;
			workspace.client.ConnectTimeline.mark("window-open");
			var dark = prefersDark(themeChoice);
			if (phoneForm) {
				context.touchPrimary = true;
				// TODO(track A): context density = Density.Touch once UiContext.density exists (set it on the UiContext the app builds).
			}
			// Scripted "back" input goes where the system Back button does.
			haxeon.ui.host.ScriptedInput.backHandler = context.handleBack;
			// Input and dialogs a program driving this window over exohost's control plane goes through (EditorControl).
			var input = new ui.control.SyntheticInput(context.events, context.window);
			var dialogs = new ui.control.DrivenDialogs(new NativeDesktopServices(context), input.driven);
			var instance = new ExosuitApp(context.fonts, ExosuitPalette.theme(dark), context,
				openPaths.length == 0 ? null : openPaths[0], null,
				dialogs, dark, ui.TerminalPane.open,
				(Sys.systemName() == "Linux" || Sys.systemName() == "Windows" || Sys.systemName() == "Mac") ? function(id,cwd,restored,requestFrame,palette,group,directory)
					return ui.TerminalPane.openRemote(function() return app == null ? null : app.terminalEndpoint(cwd, id),id,cwd,restored,requestFrame,palette,group,directory,null,true) : null);
			instance.formFactorOverride = formFactor;
			workspace.client.ConnectTimeline.mark("app-constructed");
			if (Sys.systemName() == "Linux" || Sys.systemName() == "Windows" || Sys.systemName() == "Mac") {
				try {
					var clock = function() return NativeKit.nk_time_seconds() * 1000;
					// The window's link to exohost (the tray daemon), which it starts when it does not answer; never blocks. exohost
					// starts the workspaces' services and names their pipes (`workspace.open`).
					var link = exohost.ExohostLink.start(context.events);
					var machine = new workspace.client.MachineClient(link);
					// One link per workspace the window uses: the one it shows, expanded rows, terminals.
					workspaceLinks = new workspace.client.WorkspaceLinks(context.events, clock, machine.open);
					instance.attachLinks(workspaceLinks);
					instance.attachMachineWorkspaces(machine);
					control = new ui.control.EditorControl(instance, link, input, dialogs);
				}
				catch (failure:Dynamic)
					instance.application.reportError("workspace", Std.string(failure));
			}
			workspace.client.ConnectTimeline.mark("workspace-clients");
			instance.contexts.startInContext(startContext);
			workspace.client.ConnectTimeline.mark("context-started");
			// More paths on the command line: files open in tabs; a folder opens as its workspace (the last one shown wins).
			for (index in 1...openPaths.length) instance.application.openArgument(openPaths[index]);
			if (positions != null)
				for (item in positions) instance.openArgument(item.path, item.line, item.column);
			if (openTerminal) instance.terminalTabs.openTerminal();
			if (openTerminalBrowser) instance.terminalTabs.openWorkspaceTerminals();
			if (openWorkbench) instance.showSidebarMode("workbench");
			if (pluginManifest != null && !instance.application.loadPluginManifest(pluginManifest))
				Sys.println('exosuit: could not load plugin manifest "$pluginManifest"');
			var applicationPoll = context.onPoll;
			var terminalRootsAt = -1.0;
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
					devtoolsProcess = sys.io.ChildProcess.spawn(python == null ? "python3" : python,
						toolArguments, projectRoot);
				} catch (error:Dynamic) instance.application.reportError("devtools", Std.string(error));
			}));
			context.onPoll = function() {
				if (control != null) control.poll();
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
				if (applicationPoll != null) applicationPoll();
				// Terminal tabs keep their workspaces' links (and services) in use. A link lingers for
				// WorkspaceLinks.LINGER_MS, so once a second is enough: resolving a root's workspace checks its folders on
				// disk, which every poll of an idle window did before, once per tab.
				var now = NativeKit.nk_time_seconds();
				if (workspaceLinks != null && now - terminalRootsAt >= 1.0) {
					terminalRootsAt = now;
					var roots:Array<String> = [];
					for (terminal in instance.host.allTerminalTabs())
						if (terminal.remote && !terminal.disposed && roots.indexOf(terminal.workspaceRoot) < 0) roots.push(terminal.workspaceRoot);
					instance.useTerminalRoots(roots);
				}
			};
			if (arguments.indexOf("--open-devtools") >= 0) instance.context().commands.execute("devtools.open");
			app = instance;
			workspace.client.ConnectTimeline.mark("app-built");
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
			return appearance.get_color_scheme() != ColorScheme.Light;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
