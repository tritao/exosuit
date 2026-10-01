package app;

import command.CommandContext;
import core.Application;
import platform.Native;
import platform.Platform;
import plugin.Plugin;
import plugin.PluginContext;
import renderer.Renderer;
import view.RootView;
import syntax.BuiltinSyntax;
import jobs.JobTask;
import completion.CompletionItem;
import completion.CompletionProvider;
import completion.CompletionRequest;
import plugin.EditorApi;
import terminalsession.TerminalProfile;
import terminalsession.TerminalProfileRegistry;
import terminalsession.TerminalSession;
import terminalsession.LocalPtyBackend;
import terminalkit.Emulator;
import NativeKitRuntime;

class SampleCompletionProvider implements CompletionProvider {
	public function new() {}
	public function complete(request:CompletionRequest):Array<CompletionItem>
		return StringTools.startsWith("pluginCompletion", request.prefix) ? [new CompletionItem("pluginCompletion", "Sample plugin")] : [];
}

class SampleJob implements JobTask {
	public var cancelled(default, null):Bool = false;
	public function new() {}
	public function step():Bool return false;
	public function cancel():Void cancelled = true;
}

class SamplePlugin implements Plugin {
	public var activations(default, null):Int = 0;
	public var deactivations(default, null):Int = 0;
	public var performed(default, null):Int = 0;
	public var events(default, null):Int = 0;
	public final job:SampleJob = new SampleJob();
	public var lastApi(default, null):Null<EditorApi>;
	final fixture:String;
	final terminalProfiles:TerminalProfileRegistry;

	public function new(fixture:String, terminalProfiles:TerminalProfileRegistry) {
		this.fixture = fixture;
		this.terminalProfiles = terminalProfiles;
	}

	public function id():String
		return "sample";

	public function activate(context:PluginContext):Void {
		activations++;
		lastApi = context.api;
		context.addSyntax(BuiltinSyntax.definition("Sample", [".sample"], ["sample"], [], []));
		context.addCommand("sample:run", function(editor:CommandContext) {
			this.performed++;
			context.api.replaceSelections("plugin");
		});
		context.bind(77, 3, ["sample:run"]);
		context.api.addPanel("status", "Sample", "ready");
		context.api.addStatusItem("mode", "Sample Ready", 10);
		context.api.addDecoration("first-word", 0, 0, 1, 0x224488FF);
		context.api.onDocumentChanged(function(event) {
			this.events++;
			context.api.setPanelText("status", event.document.buffer.text);
		});
		context.api.schedule(job);
		context.api.startProcess(fixture, ["sleep"]);
		context.addCompletionProvider(new SampleCompletionProvider());
		terminalProfiles.add(context.id, "shell", new TerminalProfile("/bin/sh", ["-c",
			"printf 'PROFILE:%s:%s\\r\\n' \"$TERM\" \"${NO_COLOR-unset}\""], "/tmp"), context.own);
	}

	public function deactivate(context:PluginContext):Void
		deactivations++;

	public function refresh():Bool
		return false;

	public function update(now:Float):Bool
		return false;

	public function diagnostic():Null<String>
		return null;

	public function requestRefresh():Bool
		return false;

	public function dispose():Void {}
}

class BrokenPlugin implements Plugin {
	final fixture:String;
	final terminalProfiles:TerminalProfileRegistry;
	public function new(fixture:String, terminalProfiles:TerminalProfileRegistry) {
		this.fixture = fixture;
		this.terminalProfiles = terminalProfiles;
	}

	public function id():String
		return "broken";

	public function activate(context:PluginContext):Void {
		context.addCommand("broken:leak", function(editor:CommandContext) {});
		context.api.addStatusItem("leak", "broken");
		context.api.addDecoration("leak", 0, 0, 1, 0xFFFFFFFF);
		context.api.startProcess(fixture, ["sleep"]);
		terminalProfiles.add(context.id, "leak", TerminalProfile.shell(), context.own);
		context.bind(1, 0, ["root:close"]);
	}

	public function deactivate(context:PluginContext):Void {}

	public function refresh():Bool
		return false;

	public function update(now:Float):Bool
		return false;

	public function diagnostic():Null<String>
		return null;

	public function requestRefresh():Bool
		return false;

	public function dispose():Void {}
}

class PluginTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function checkTerminalProfile(profiles:TerminalProfileRegistry):Void {
		var entry = profiles.find("sample", "shell");
		if (entry == null) throw "terminal profile lookup failed";
		require(entry.id() == "sample:shell", "terminal profile identity failed");
		var runtime = NativeKitRuntime.start();
		var session = new TerminalSession(LocalPtyBackend.spawn(entry.profile, 40, 4), Emulator.open(40, 4));
		var deadline = Sys.time() + 5;
		while (Sys.time() < deadline && session.status != "exited") {
			session.pollEvents();
			Sys.sleep(0.01);
		}
		session.emulator.snapshot();
		var passed = session.status == "exited" && session.exitCode == 0
			&& session.emulator.rowText(0).indexOf("PROFILE:xterm-256color:unset") >= 0;
		session.close();
		runtime.dispose();
		require(passed, "registered terminal profile did not start and exit");
	}

	static function main():Int {
		Platform.startHeadless();
		var arguments = Sys.args();
		require(arguments.length == 1, "plugin test requires process fixture");
		var window = Native.window_create("plugin-test", 320, 200),
			renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new RootView(renderer, theme, focus, workspace, 320, 200, settings)),
			root:RootView = cast application.root,
			terminalProfiles = new TerminalProfileRegistry(),
			plugin = new SamplePlugin(arguments[0], terminalProfiles);
		application.newDocument();
		require(application.plugins.load(plugin), "plugin did not activate");
		require(terminalProfiles.profiles().length == 1, "terminal profile was not registered");
		if (Sys.systemName() != "Windows") checkTerminalProfile(terminalProfiles);
		require(plugin.activations == 1 && application.plugins.isLoaded("sample") && application.completions.count() == 2
			&& application.processes.activeCount() == 1,
			"plugin activation state or completion contribution was not recorded");
		require(application.syntaxes.find("file.sample").name == "Sample", "plugin syntax did not register");
		require(!application.plugins.load(new SamplePlugin(arguments[0], terminalProfiles)), "duplicate plugin id was accepted");
		require(application.keyPressed(77, 3) && plugin.performed == 1 && plugin.events == 1
			&& application.context.requireDocument().buffer.text == "plugin", "plugin command did not perform an owned document transaction");
		require(application.commands.perform("doc:complete-word", application.context)
			&& root.commandView.results.length == 1
			&& root.commandView.results[0].value == "pluginCompletion", "plugin completion provider did not contribute to word completion");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		var panel = root.pluginPanels.find("sample", "status");
		require(panel != null && panel.text == "plugin", "plugin panel or document event contribution was not live");
		require(root.pluginStatusItems.find("sample", "mode") != null
			&& root.status.text(application.context.requireView()).indexOf("Sample Ready") >= 0
			&& root.pluginDecorations.find("sample", "first-word") != null,
			"plugin status item or editor decoration was not live");
		application.openCommandView();
		application.textInput("samplerun");
		require(root.commandView.results.length == 1, "plugin command was absent from command view");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(plugin.performed == 2, "plugin command palette entry did not dispatch");
		require(application.commands.perform("plugins:disable", application.context)
			&& root.commandView.results.length == 1, "plugin disable picker did not open");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(plugin.deactivations == 1 && !application.commands.contains("sample:run") && !application.keyPressed(77, 3),
			"plugin registrations survived disable");
		require(application.completions.count() == 1, "plugin completion provider survived disable");
		require(terminalProfiles.profiles().length == 0, "terminal profile survived disable");
		require(application.processes.activeCount() == 0, "plugin-owned process survived disable");
		var eventsAfterUnload = plugin.events;
		application.textInput("after");
		require(root.pluginPanels.find("sample", "status") == null && plugin.events == eventsAfterUnload && plugin.job.cancelled,
			"plugin panel, event subscription, or scheduled job survived disable");
		require(root.pluginStatusItems.find("sample", "mode") == null
			&& root.pluginDecorations.find("sample", "first-word") == null,
			"plugin status item or editor decoration survived disable");
		var staleApiRejected = false;
		try plugin.lastApi.addStatusItem("stale", "leak") catch (error:Dynamic) staleApiRejected = true;
		require(staleApiRejected && root.pluginStatusItems.find("sample", "stale") == null,
			"retired plugin API accepted or leaked a new contribution");
		require(application.syntaxes.find("file.sample").name == "Plain Text", "plugin syntax survived disable");
		require(!application.plugins.isLoaded("sample") && application.plugins.disabledIds().indexOf("sample") >= 0,
			"disabled plugin definition was not retained");
		require(application.commands.perform("plugins:enable", application.context)
			&& root.commandView.results.length == 1, "plugin enable picker did not open");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(plugin.activations == 2 && application.plugins.isLoaded("sample") && application.processes.activeCount() == 1,
			"plugin did not enable with fresh registrations");
		require(terminalProfiles.profiles().length == 1, "terminal profile was not restored on enable");
		require(application.commands.perform("plugins:reload", application.context)
			&& root.commandView.results.length == 1, "plugin reload picker did not open");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(plugin.activations == 3 && application.processes.activeCount() == 1, "plugin did not reload with one owned process");
		require(terminalProfiles.profiles().length == 1, "terminal profile duplicated on reload");
		var activeView = application.context.requireView(), activeDocument = application.context.requireDocument(), activeSelection = activeView.getSelection();
		require(activeSelection != null, "document view did not expose its selection");
		activeDocument.buffer.replaceAllText("alpha alphabet al", activeSelection);
		activeSelection.setCursor(activeDocument.buffer, activeDocument.buffer.endPosition());
		require(application.commands.perform("doc:complete-word", application.context)
			&& root.commandView.results.length == 2, "built-in word completion did not open through the shared registry");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(activeDocument.buffer.text == "alpha alphabet alpha", "completion acceptance did not replace the typed prefix");
		var failed = false;
		try {
			application.plugins.load(new BrokenPlugin(arguments[0], terminalProfiles));
		} catch (error:Dynamic) {
			failed = true;
		}
		require(failed
			&& !application.plugins.isLoaded("broken")
			&& !application.commands.contains("broken:leak")
			&& application.processes.activeCount() == 1
			&& root.pluginStatusItems.find("broken", "leak") == null
			&& root.pluginDecorations.find("broken", "leak") == null
			&& terminalProfiles.find("broken", "leak") == null, "failed activation leaked plugin state");
		application.shutdown();
		require(plugin.deactivations == 3 && application.plugins.count() == 0 && application.processes.activeCount() == 0,
			"application shutdown did not deactivate plugins or retire their processes");
		require(terminalProfiles.profiles().length == 0, "terminal profile survived shutdown");
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy plugin test window");
		Native.shutdown();
		Sys.println("PASS: plugin activation, palette dispatch, rollback, reload, and cleanup");
		return 0;
	}
}
