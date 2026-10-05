package app;

import command.CommandRegistry;
import command.KeyBinding;
import command.Keymap;
import config.Preferences;
import config.ConfigurationPaths;
import core.Application;
import platform.Platform;
import testing.model.ModelTextMetrics;
import sys.io.File;
import sys.FileSystem;
import session.WorkspaceSession;
import recovery.RecoverySnapshot;
import recovery.RecoveryStore;
import session.SessionPersistence;
import testing.model.ModelWorkbenchHost;

class ConfigurationTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		var arguments = Sys.args(), userPath = arguments[0], projectPath = arguments[1];
		var oldPortable = Sys.getEnv("PRAGTICAL_PORTABLE"), oldConfig = Sys.getEnv("XDG_CONFIG_HOME"), oldState = Sys.getEnv("XDG_STATE_HOME");
		Sys.putEnv("PRAGTICAL_PORTABLE", arguments[2] + "/portable/");
		require(ConfigurationPaths.userSettings() == arguments[2] + "/portable/settings.json"
			&& ConfigurationPaths.session() == arguments[2] + "/portable/session.conf", "portable data root was not authoritative");
		Sys.putEnv("PRAGTICAL_PORTABLE", "");
		if (Sys.systemName() != "Windows" && Sys.systemName() != "Mac") {
			Sys.putEnv("XDG_CONFIG_HOME", arguments[2] + "/xdg-config");
			Sys.putEnv("XDG_STATE_HOME", arguments[2] + "/xdg-state");
			require(ConfigurationPaths.userSettings() == arguments[2] + "/xdg-config/pragtical-haxeon/settings.json"
				&& ConfigurationPaths.session() == arguments[2] + "/xdg-state/pragtical-haxeon/session.conf", "XDG data roots were not respected");
		}
		Sys.putEnv("PRAGTICAL_PORTABLE", oldPortable == null ? "" : oldPortable);
		Sys.putEnv("XDG_CONFIG_HOME", oldConfig == null ? "" : oldConfig);
		Sys.putEnv("XDG_STATE_HOME", oldState == null ? "" : oldState);
		// UIKit persists only overrides, validates edits and preserves unknown module keys.
		if (FileSystem.exists(userPath)) FileSystem.deleteFile(userPath);
		var service = new Preferences(userPath);
		var store = service.store;
		var notifications = 0, release = service.subscribe(function(_) notifications++);
		require(notifications == 1, "initial preference notification missing");
		require(store.set("editor/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(18)) == null,
			"valid font size rejected");
		require(service.current.fontSize == 18 && notifications == 2, "preference did not apply immediately");
		require(store.set("editor/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(0)) != null
			&& service.current.fontSize == 18 && notifications == 2, "invalid preference changed the snapshot");
		require(store.set("languages/haxeon/command", haxeon.ui.properties.PropertyValue.Text("[1]")) != null,
			"invalid language argv accepted");
		require(store.set("editor/keyboard/keybindings", haxeon.ui.properties.PropertyValue.Text('["Ctrl+A|doc:undo"]')) == null,
			"valid keybinding rejected");
		require(new Preferences(userPath).current.fontSize == 18, "preferences did not survive restart");
		store.set("editor/display/minimap_enabled", haxeon.ui.properties.PropertyValue.Bool(false));
		require(!service.current.minimapEnabled && !service.current.copy().minimapEnabled, "minimap did not apply");
		store.reset("editor/display/minimap_enabled");
		require(service.current.minimapEnabled, "reset did not restore default");
		for (mode in ["auto", "always", "hidden"])
			require(store.set("editor/display/scrollbar_visibility", haxeon.ui.properties.PropertyValue.Enum(mode)) == null
				&& service.current.scrollbarVisibility == mode, "scrollbar choice did not apply");
		require(store.set("editor/display/scroll_animation_duration", haxeon.ui.properties.PropertyValue.Float(0.31)) != null,
			"out of range scroll duration accepted");
		release(); release();
		var count = notifications;
		store.set("editor/indentation/tab_width", haxeon.ui.properties.PropertyValue.Int(8));
		require(notifications == count, "released listener retained");
		store.resetUnder("");
		File.saveContent(userPath, "invalid JSON");
		var lastGood = service.current;
		require(!service.reload(true) && service.current == lastGood && service.diagnostics.length > 0,
			"malformed JSON replaced last good snapshot");
		store.save();
		service.reload(true);
		var liveStore = service.store;

		var metrics = new ModelTextMetrics("ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings),
				service, new session.RecentProjects(arguments[2] + "/recent.conf")), performed = 0;
		require(metrics.fontFallbackPaths.join("\n") == service.current.fontFallbackPaths.join("\n"),
			"configured font fallback group was not installed");
		application.commands.add("test:configured", function(context) {
			performed += 1;
		});
		var previousFont = metrics.revision;
		liveStore.batch(function() {
			liveStore.set("editor/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(21));
			liveStore.set("appearance/colors/selection", haxeon.ui.properties.PropertyValue.Int(123456));
			liveStore.set("editor/keyboard/keybindings", haxeon.ui.properties.PropertyValue.Text('["Ctrl+A|test:configured"]'));
		});
		application.update();
		require(metrics.fontSize == 21 && metrics.revision > previousFont,
			"live font settings did not update model metrics");
		require(application.theme.selection == 123456, "live theme update missing");
		require(application.keyPressed(Platform.KEY_A, Platform.MOD_CTRL) && performed == 1, "configured shortcut missing");
		liveStore.resetUnder(""); application.update();
		require(metrics.fontSize == 15 && application.theme.selection == new config.Settings().selection,
			"preference reset did not restore defaults");
		require(application.keymap.commandsFor(Platform.KEY_A, Platform.MOD_CTRL)[0] == "doc:select-all", "reset lost default shortcut");
		var workspaceSettingsPath = ConfigurationPaths.projectSettings(arguments[2]);
		var projectPreferences = service.forProject(workspaceSettingsPath);
		projectPreferences.store.set("languages/haxeon/enabled", haxeon.ui.properties.PropertyValue.Bool(false));
		require(!projectPreferences.registry.exists("editor/fonts/font_size"), "user preferences leaked into project configuration");
		application.openArgument(arguments[2]);
		var configuredProject = application.workspace.activeProject;
		if (configuredProject == null || configuredProject.settings == null) throw "Project configuration missing";
		require(!configuredProject.settings.current.haxeonEnabled, "project language configuration not loaded");
		liveStore.set("editor/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(23));
		application.update();
		require(metrics.fontSize == 23, "project configuration blocked live user preferences");
		application.open(arguments[3]); application.update();
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
		var recoveredApplication = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings),
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
		var emptyApplication = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings),
			service, new session.RecentProjects("")),
			emptyRoot:ModelWorkbenchHost = cast emptyApplication.root;
		emptyLayout.restore(emptyApplication, new RecoveryStore(arguments[2] + "/missing-recovery.conf"));
		require(emptyRoot.node.isLeaf() && emptyRoot.tabs.views.length == 0,
			"unrestorable session tabs retained an empty split topology");
		emptyApplication.shutdown();
		application.shutdown();

		Sys.println("PASS: UIKit preference persistence, validation, live updates, resets and project configuration");
		return 0;
	}
}
