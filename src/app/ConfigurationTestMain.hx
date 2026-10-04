package app;

import command.CommandRegistry;
import command.KeyBinding;
import command.Keymap;
import config.SettingsService;
import config.ConfigurationPaths;
import core.Application;
import platform.Native;
import platform.Platform;
import renderer.Renderer;
import sys.io.File;
import sys.FileSystem;
import session.WorkspaceSession;
import recovery.RecoverySnapshot;
import recovery.RecoveryStore;
import session.SessionPersistence;
import view.RootView;

class ConfigurationTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		var arguments = Sys.args(), userPath = arguments[0], projectPath = arguments[1];
		var oldPortable = Sys.getEnv("PRAGTICAL_PORTABLE"), oldConfig = Sys.getEnv("XDG_CONFIG_HOME"), oldState = Sys.getEnv("XDG_STATE_HOME");
		Sys.putEnv("PRAGTICAL_PORTABLE", arguments[2] + "/portable/");
		require(ConfigurationPaths.userSettings() == arguments[2] + "/portable/settings.conf"
			&& ConfigurationPaths.session() == arguments[2] + "/portable/session.conf", "portable data root was not authoritative");
		Sys.putEnv("PRAGTICAL_PORTABLE", "");
		if (Sys.systemName() != "Windows" && Sys.systemName() != "Mac") {
			Sys.putEnv("XDG_CONFIG_HOME", arguments[2] + "/xdg-config");
			Sys.putEnv("XDG_STATE_HOME", arguments[2] + "/xdg-state");
			require(ConfigurationPaths.userSettings() == arguments[2] + "/xdg-config/pragtical-haxeon/settings.conf"
				&& ConfigurationPaths.session() == arguments[2] + "/xdg-state/pragtical-haxeon/session.conf", "XDG data roots were not respected");
		}
		Sys.putEnv("PRAGTICAL_PORTABLE", oldPortable == null ? "" : oldPortable);
		Sys.putEnv("XDG_CONFIG_HOME", oldConfig == null ? "" : oldConfig);
		Sys.putEnv("XDG_STATE_HOME", oldState == null ? "" : oldState);
		var service = new SettingsService(userPath, projectPath);
		require(service.diagnostics.length == 0, "valid settings produced diagnostics");
		require(service.current.fontSize == 18 && service.current.sidebarWidth == 280 && !service.current.insertSpaces, "layer precedence failed");
		require(service.current.fontFallbackPaths.length == 2 && StringTools.endsWith(service.current.fontFallbackPaths[1], "/fallback-two.ttf"),
			"font fallback configuration was not layered");
		require(service.current.keybindings.length == 1 && service.current.keybindings[0].commands[0] == "doc:redo", "project keybinding did not replace user bindings");
		var lastGood = service.current;
		File.saveContent(projectPath, "version=1\neditor.fontSize=broken\n");
		require(!service.reload() && service.current == lastGood && service.diagnostics.length > 0, "invalid reload replaced last good settings");
		File.saveContent(projectPath, "version=1\neditor.fontSize=19\n");
		require(service.reload() && service.current.fontSize == 19 && service.current.sidebarWidth == 240 && service.current.insertSpaces,
			"fixed reload did not reapply layered settings and defaults");
		var notifications = 0, release = service.subscribe(function(value) {
			notifications++;
		});
		require(notifications == 1 && !service.reload(), "subscription or unchanged reload was not stable");
		release();
		release();
		File.saveContent(projectPath, "version=1\neditor.fontSize=20\n");
		require(service.reload() && notifications == 1, "released settings subscription was retained");
		FileSystem.deleteFile(projectPath);
		require(service.reload() && service.current.fontSize == 16 && service.current.sidebarWidth == 240,
			"removing the project layer did not reset to user/default values");
		File.saveContent(projectPath, "version=1\neditor.fontSize=19\n");
		require(service.reload(), "could not restore project settings after reset test");
		var unreadable = new SettingsService(arguments[2]);
		require(unreadable.diagnostics.length > 0, "settings read failure did not become a diagnostic");

		File.saveContent(projectPath, "version=1\neditor.scroll_animation_type=none\neditor.scroll_animation_duration=0.2\n");
		require(service.reload() && service.current.scrollAnimationType == "none" && service.current.scrollAnimationDuration == 0.2,
			"scroll settings did not load");
		require(service.current.copy().scrollAnimationDuration == 0.2, "scroll settings copy lost duration");
		for (invalid in ["NaN", "Infinity", "0.12oops", "-0.1", "0.31"]) {
			File.saveContent(projectPath, "version=1\neditor.scroll_animation_duration=" + invalid + "\n");
			require(!service.reload() && service.current.scrollAnimationDuration == 0.2, "invalid duration replaced last good settings");
		}
		File.saveContent(projectPath, "version=1\neditor.scroll_animation_type=unknown\n");
		require(!service.reload() && service.current.scrollAnimationType == "none", "invalid scroll type replaced last good settings");
		File.saveContent(projectPath, "version=1\neditor.fontSize=19\n");
		require(service.reload() && service.current.scrollAnimationType == "smooth" && service.current.scrollAnimationDuration == 0.12,
			"removed scroll override did not restore defaults");

		for (mode in ["auto", "always", "hidden"]) {
			File.saveContent(projectPath, "version=1\nworkbench.scrollbarVisibility=" + mode + "\n");
			require(service.reload() && service.current.scrollbarVisibility == mode && service.current.copy().scrollbarVisibility == mode,
				"scrollbar visibility setting or copy failed");
		}
		File.saveContent(projectPath, "version=1\nworkbench.scrollbarVisibility=invalid\n");
		require(!service.reload() && service.current.scrollbarVisibility == "hidden", "invalid scrollbar policy replaced last good settings");
		File.saveContent(projectPath, "version=1\neditor.fontSize=19\n");
		require(service.reload() && service.current.scrollbarVisibility == "auto", "removed scrollbar policy did not restore auto");

		File.saveContent(projectPath, 'version=1\nplugins.haxeon.enabled=false\nplugins.haxeon.verbose=true\nplugins.haxeon.command=["/server with spaces", "--stdio", "", "comma,arg"]\n');
		require(service.reload() && !service.current.haxeonEnabled && service.current.haxeonVerbose && service.current.haxeonCommand.length == 4,
			"typed language configuration failed");
		var copied = service.current.copy(); copied.haxeonCommand[0] = "changed";
		require(service.current.haxeonCommand[0] == "/server with spaces", "settings copy aliased command arguments");
		for (invalid in ['"server"', '[1]', '[null]', '[""]', '["server",false]', '[broken']) {
			File.saveContent(projectPath, "version=1\nplugins.haxeon.command=" + invalid + "\n");
			require(!service.reload() && service.current.haxeonCommand[0] == "/server with spaces", "invalid argv replaced last good configuration");
		}
		var configured = ["configured executable", "arg with spaces", ""];
		var selected = config.LanguageServerCommand.resolve(configured, "environment", "bundled", true, "/compiler");
		require(selected.length == 3 && selected[1] == "arg with spaces" && selected[2] == "", "configured argv was shell-split");
		selected[0] = "changed"; require(configured[0] == "configured executable", "resolver changed configured argv");
		require(config.LanguageServerCommand.resolve([], "environment path", "bundled", true, "/compiler")[0] == "environment path", "environment precedence failed");
		require(config.LanguageServerCommand.resolve([], "", "bundled", true, "/compiler")[0] == "bundled", "bundled precedence failed");
		require(config.LanguageServerCommand.resolve([], null, "bundled", false, "/compiler")[0] == "/compiler/scripts/haxeon-lsp", "compiler fallback failed");
		File.saveContent(projectPath, "version=1\neditor.fontSize=19\n");
		require(service.reload() && service.current.haxeonEnabled && !service.current.haxeonVerbose && service.current.haxeonCommand.length == 0,
			"removed language overrides did not restore defaults");

		Platform.startHeadless();
		var window = Native.window_create("configuration-test", 640, 320), renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new RootView(renderer, theme, focus, workspace, 640, 320, settings),
				service, new session.RecentProjects(arguments[2] + "/recent.conf")), performed = 0;
		require(Native.font_fallback_count(renderer.font) == service.current.fontFallbackPaths.length + 1,
			"configured font fallback group was not installed");
		application.commands.add("test:configured", function(context) {
			performed += 1;
		});
		var previousFont = renderer.font;
		File.saveContent(projectPath, "version=1\neditor.fontSize=21\ntheme.selection=123456\nkeybinding=Ctrl+A|test:configured\n");
		application.update();
		require(renderer.fontSize == 21 && renderer.font != previousFont && Native.font_height(previousFont) == -1,
			"live font replacement leaked the retired font handle");
		require(application.theme.selection == 123456, "live semantic theme update was not applied");
		require(application.keyPressed(Platform.KEY_A, Platform.MOD_CTRL) && performed == 1,
			"live configured binding was missing or duplicated");
		File.saveContent(projectPath, "version=1\n");
		application.update();
		var defaultSettings = new config.Settings();
		require(renderer.fontSize == 16 && application.theme.selection == defaultSettings.selection,
			"live settings reset did not restore layered defaults");
		require(application.keymap.commandsFor(Platform.KEY_A, Platform.MOD_CTRL)[0] == "doc:undo",
			"settings reset did not restore the user-layer binding");
		performed = 0;
		application.keymap.setConfigured([new KeyBinding(Platform.KEY_A, Platform.MOD_CTRL, ["test:configured"])]);
		require(application.keyPressed(Platform.KEY_A, Platform.MOD_CTRL) && performed == 1, "configured binding did not override defaults");
		application.keymap.setConfigured([]);
		require(application.keymap.commandsFor(Platform.KEY_A, Platform.MOD_CTRL)[0] == "doc:select-all", "clearing configured bindings lost defaults");
		var projectSettingsDirectory = arguments[2] + "/.pragtical", workspaceSettingsPath = projectSettingsDirectory + "/settings.conf";
		if (!FileSystem.exists(projectSettingsDirectory)) FileSystem.createDirectory(projectSettingsDirectory);
		File.saveContent(workspaceSettingsPath, "version=1\neditor.fontSize=22\ntheme.accent=654321\nfiles.exclude=.git,generated\n");
		application.openArgument(arguments[2]);
		require(renderer.fontSize == 22 && application.theme.accent == 654321,
			"opening a project did not apply its layered settings");
		File.saveContent(workspaceSettingsPath, "version=1\neditor.fontSize=23\ntheme.accent=765432\nfiles.exclude=.git,generated\n");
		var activeProject = application.workspace.activeProject;
		if (activeProject == null) throw "active project has no settings service";
		var projectSettings = activeProject.settings;
		if (projectSettings == null) throw "active project has no settings service";
		projectSettings.reload();
		application.update();
		require(renderer.fontSize == 23 && application.theme.accent == 765432,
			"live project setting changes were not applied through the active layer");
		var projectLastGood = projectSettings.current, errorsBeforeInvalidProject = application.errors.entries.length;
		File.saveContent(workspaceSettingsPath, "version=1\nrun=untrusted-project-code\n");
		require(!projectSettings.reload() && projectSettings.current == projectLastGood,
			"project configuration was not treated as validated data");
		application.update();
		require(application.errors.entries.length > errorsBeforeInvalidProject,
			"project configuration diagnostics were not visible in the editor");
		File.saveContent(workspaceSettingsPath, "version=1\neditor.fontSize=23\ntheme.accent=765432\nfiles.exclude=.git,generated\n");
		require(projectSettings.reload(), "valid project configuration did not recover after a diagnostic");
		application.open(arguments[3]);
		application.update();
		require(renderer.fontSize == 16, "leaving the project did not restore user-layer settings");
		var sessionPath = arguments[2] + "/state/nested/session.conf", session = WorkspaceSession.capture(application);
		require(session.save(sessionPath), "session did not create its state directory");
		var loaded = WorkspaceSession.load(sessionPath);
		require(loaded != null && loaded.projects.length == 1 && loaded.documents.length == 1 && loaded.activeDocument == arguments[3],
			"session round trip lost workspace state");
		var recoveryPath = arguments[2] + "/state/recovery.conf", recovery = new RecoveryStore(recoveryPath);
		require(recovery.saveSnapshots([new RecoverySnapshot("recovered-1", "recovered", arguments[3], "dirty\nrecovered")]), "recovery snapshot save failed");
		var snapshots = recovery.load();
		require(snapshots.length == 1 && snapshots[0].path == arguments[3] && snapshots[0].text == "dirty\nrecovered",
			"length-framed recovery snapshot round trip failed");
		require(recovery.save(application) && recovery.load().length == 1, "unaccepted recovery was erased by periodic save");
		var untitledView = application.newDocument(), untitled = untitledView.getDocument();
		if (untitled == null) throw "untitled view has no document";
		untitledView.textInput("unsaved untitled");
		require(recovery.save(application), "untitled recovery save failed");
		var withUntitled = recovery.load(), untitledSnapshot:Null<RecoverySnapshot> = null;
		for (snapshot in withUntitled) if (snapshot.path == null) untitledSnapshot = snapshot;
		require(untitledSnapshot != null && untitledSnapshot.text == "unsaved untitled", "untitled recovery identity or content was lost");
		if (untitledSnapshot == null) throw "missing untitled recovery snapshot";
		var recoveredApplication = new Application((theme, focus, workspace, settings) -> new RootView(renderer, theme, focus, workspace, 640, 320, settings),
				service, new session.RecentProjects("")),
			recoveredSession = WorkspaceSession.capture(application);
		recoveredSession.restore(recoveredApplication, recovery);
		var recoveredUntitled = false;
		for (document in recoveredApplication.documents.documents)
			if (document.recoveryId == untitledSnapshot.id && document.buffer.text == "unsaved untitled") recoveredUntitled = true;
		require(recoveredUntitled, "session did not restore a dirty pathless document through its stable recovery identity");
		var pendingRecovery = recovery.loadPending(recoveredApplication);
		require(pendingRecovery.length == 1 && pendingRecovery[0].id == "recovered-1",
			"session-restored recovery was offered again instead of leaving only orphaned snapshots");
		recoveredApplication.shutdown();
		var beforeRestore = application.documents.documents.length;
		require(recovery.restore(application, untitledSnapshot) && application.documents.documents.length == beforeRestore,
			"accepting an already restored recovery identity duplicated its pathless document");
		var many:Array<RecoverySnapshot> = [];
		for (index in 0...RecoveryStore.MAX_SNAPSHOTS + 5)
			many.push(new RecoverySnapshot("bounded-" + (index + 1), "bounded-" + index, null, "value-" + index));
		require(recovery.saveSnapshots(many) && recovery.load().length == RecoveryStore.MAX_SNAPSHOTS
			&& recovery.load()[0].title == "bounded-5", "recovery retention was not bounded to the newest snapshots");
		var accepted = recovery.load()[0];
		require(recovery.forgetSnapshot(accepted) && recovery.load().length == RecoveryStore.MAX_SNAPSHOTS - 1,
			"accepted recovery snapshot was retained");
		require(!recovery.restore(application, new RecoverySnapshot("missing-2", "missing", arguments[2] + "/missing", "lost")) && recovery.diagnostics.length > 0,
			"missing recovery source was silently ignored");
		File.saveContent(recoveryPath, "pragtical-recovery=1\nnope:2:xx");
		require(recovery.load().length == 0 && recovery.diagnostics.length > 0, "corrupt recovery lengths accepted");
		require(!FileSystem.exists(recoveryPath) && FileSystem.exists(recoveryPath + ".incompatible")
			&& recovery.save(application) && StringTools.startsWith(File.getContent(recoveryPath), "pragtical-recovery=3\n"),
			"incompatible recovery was not quarantined before current state was saved");
		var persistencePath = arguments[2] + "/state/debounced-session.conf", persistence = new SessionPersistence(persistencePath);
		persistence.begin(application);
		application.newDocument();
		require(!persistence.update(application, 0.0) && persistence.update(application, 1.0)
			&& WorkspaceSession.load(persistencePath) != null, "debounced session persistence did not publish stable state");
		application.newDocument();
		require(persistence.flush(application), "controlled session shutdown flush failed");
		File.saveContent(sessionPath, "corrupt session");
		require(WorkspaceSession.load(sessionPath) == null && !FileSystem.exists(sessionPath)
			&& FileSystem.exists(sessionPath + ".incompatible"), "corrupt session did not fail closed into quarantine");
		File.saveContent(sessionPath, "version=3\nlayout=S\tbad-route\tH\tnot-a-number\nlayout=T\t\t1\tbad\t0\t0\t0\tP\tmissing\n");
		var malformedLayout = WorkspaceSession.load(sessionPath);
		require(malformedLayout != null && malformedLayout.layout.length == 0,
			"malformed versioned layout records survived defensive decoding");
		var emptyLayout = WorkspaceSession.decode("version=3\nlayout=S\t\tH\t500\nlayout=S\t1\tH\t500\n"
			+ "layout=T\t11\t1\t0\t0\t0\t0\tR\tmissing-recovery\nlayout=A\t11\n");
		var emptyApplication = new Application((theme, focus, workspace, settings) -> new RootView(renderer, theme, focus, workspace, 640, 320, settings),
			service, new session.RecentProjects("")),
			emptyRoot:RootView = cast emptyApplication.root;
		emptyLayout.restore(emptyApplication, new RecoveryStore(arguments[2] + "/missing-recovery.conf"));
		require(emptyRoot.node.isLeaf() && emptyRoot.tabs.views.length == 0,
			"unrestorable session tabs retained an empty split topology");
		emptyApplication.shutdown();
		application.shutdown();
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy configuration test window");
		Native.shutdown();
		Sys.println("PASS: typed layered settings, invalid reload rollback, and keybinding overlays");
		return 0;
	}
}
