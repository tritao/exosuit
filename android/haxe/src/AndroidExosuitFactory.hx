import workspace.client.RemoteMachines;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.ui.host.UiApplication;
import haxeon.ui.host.UiHostContext;
import nativekit.ffi.NativeKit;
import platform.HostCapabilities;
import platform.HostCapability;
import sys.FileSystem;
import ui.ExosuitApp;
import ui.ExosuitPalette;
import haxeon.ui.icons.IconName;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** Builds the same ExosuitApp the desktop runs, with the capabilities a phone has, attached to its paired workspace. */
class AndroidExosuitFactory {
	/** The phone's remote attachment, once the app exists; the Activity's test-rig commands (pair, open) go to it. */
	public static var remote(default, null):Null<RemoteMachines>;
	static var phonePanel:Null<ui.RemoteMachinesPanel>;
	static var lastView:Null<PhoneLastView>;
	/** The workspace that was open (or opening) when an invitation link arrived: its Workbench attaching does not cover the Remote panel. */
	static var prefillHold:Null<String> = null;
	static var prefillHolding = false;

	/**
		A shared or opened invitation (the Activity's `prefill` command): puts the link into the pairing field and shows the
		Remote panel. It does not pair; the person presses Pair. False when the text is no pairing link.
	**/
	public static function prefillPairing(url:String):Bool {
		var panel = phonePanel, current = app;
		if (panel == null || current == null) return false;
		var text = StringTools.trim(url);
		if (workspace.client.PairingLink.parse(text) == null) {
			Sys.println("exosuit-prefill: the text is no pairing link and was ignored");
			return false;
		}
		panel.prefill(text);
		// The person came to pair: the last view a cold start would reopen does not cover the panel (PhoneLastView.yieldToPairing),
		// nor does the Workbench of a workspace that was already open or opening. Opening a workspace afterwards shows it as usual.
		var view = lastView;
		if (view != null) view.yieldToPairing();
		var open = remote == null ? null : remote.openView();
		prefillHold = open == null ? null : open.workspace;
		prefillHolding = open != null;
		current.showSidebarMode("remote-access");
		return true;
	}

	/** The app, for the live-patch hooks (UiBridge.liveRelease, liveRebuild). */
	public static var app(default, null):Null<ExosuitApp>;

	/** `credentialsUnreadable`: the host has a credential file it could not open (`credentialDocument` is then null). */
	public static function create(context:UiHostContext, appFilesRoot:String, credentialDocument:Null<Bytes>, credentialsUnreadable:Bool):UiApplication {
		if (!Path.isAbsolute(appFilesRoot) || !FileSystem.isDirectory(appFilesRoot))
			throw "An existing absolute app-files directory is required";
		var root = appFilesRoot;
		while (root.length > 1 && (StringTools.endsWith(root, "/") || StringTools.endsWith(root, "\\"))) root = root.substr(0, root.length - 1);
		// The app keeps its settings and state in its private files directory. There is no suit on the phone: only the
		// desktop's GraphicalMain makes a suit link, and the phone reaches its machine's suit through the relay.
		Sys.putEnv("PRAGTICAL_PORTABLE", root);
		var app:Null<ExosuitApp> = null;
		var redraw = function() {
			if (app == null) context.requestFrame(); else app.requestFrame();
		};
		// The terminal service tells "the same client came back" from "another client" by this key. The desktop makes a random
		// one per process; a phone whose process was killed must come back with the same key, or the service keeps the old
		// attachment's control lease and the phone returns as an observer. RpcTerminalBackend keeps it bound to this process's pid.
		workspace.client.RpcTerminalBackend.adoptClientKey(persistentClientKey(root));
		var credentials = new PhoneCredentials();
		credentials.load(credentialDocument, credentialsUnreadable);
		if (credentialDocument != null) for (index in 0...credentialDocument.length) credentialDocument.set(index, 0);
		var phone = new RemoteMachines(context.events, function() return NativeKit.nk_time_seconds() * 1000, credentials, redraw);
		// A workspace terminal is a service-owned PTY the phone attaches to (never a local shell); the pane gets the touch
		// extra-keys row and finger scrolling because this host's primary input is touch.
		var openTerminal = function(id:String, cwd:String, restored:Bool, requestFrame:Void->Void, palette:ui.TerminalPalette, group:Null<String>,
				directory:Null<String>):ui.TerminalPanel {
			var panel = ui.TerminalPane.openRemote(function() return phone, id, cwd, restored, requestFrame, palette, group, directory, null, true);
			cast(panel, ui.TerminalPane).touchKeys = true;
			cast(panel, ui.TerminalPane).substituteGlyphs = true;
			// Over the relay a whole history (up to 16 MiB) took long on every open and every return to the app: the phone
			// asks for the recent 256 KiB (a few thousand rows; more with plain text) and re-attaches by replay.
			cast(panel, ui.TerminalPane).recentHistoryOnly(256 * 1024);
			return panel;
		};
		var created = new ExosuitApp(context.fonts, ExosuitPalette.theme(false), context, null, new HostCapabilities([HostCapability.Filesystem]), null,
			false, null, openTerminal);
		app = created;
		AndroidExosuitFactory.app = created;
		// A phone is about 50 terminal columns wide at 11 px; the desktop default (14) leaves 40. A user's own choice stays.
		var settings = created.application.settings.store;
		if (settings.isDefault("terminal/fonts/font_size")) settings.set("terminal/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(11));
		remote = phone;
		var machines = new ui.DeviceWorkbenchMachine(created, phone);
		created.attachWorkbenchMachine(machines);
		var panel = new ui.RemoteMachinesPanel(phone, redraw);
		phonePanel = panel;
		created.registerSidebarDestination("remote-access", IconName.Radar, function() return panel,
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Remote", 30, true));
		var filesAttached = false;
		var attachedWorkbench:Null<workspace.client.WorkspaceWorkbenchClient> = null;
		var lastView = new PhoneLastView(root, phone, created, function() return NativeKit.nk_time_seconds() * 1000);
		AndroidExosuitFactory.lastView = lastView;
		var applicationPoll = context.onPoll;
		// Debug builds with files/automation.on (see ExosuitActivity): the labelled elements and the app's state for the test scripts.
		var automationDirectory = PhoneSnapshotFile.directoryFromEnvironment();
		var automation = automationDirectory == null ? null : new PhoneSnapshotFile(automationDirectory, created.context(), function() {
			var state:Dynamic = created.diagnostics.automationState();
			state.phone = phone.automationState();
			return state;
		});
		context.onPoll = function() {
			if (applicationPoll != null) applicationPoll();
			if (automation != null) automation.poll();
			machines.poll();
			lastView.poll();
			var identified = phone.fileScope() != null;
			var filesAvailable = identified && phone.hasCapability(WorkspaceFileProtocol.READ);
			if (filesAvailable && !filesAttached) {
				filesAttached = true;
				created.attachWorkspace(phone);
			} else if (!filesAvailable && filesAttached) {
				filesAttached = false;
				created.detachWorkspace(phone);
			}
			var workbenchAvailable = identified && phone.hasCapability(WorkspaceTerminalProtocol.READ) && phone.hasCapability(WorkspaceTerminalProtocol.CATALOG);
			// The Workbench reads the open workspace's link: another workspace opened is another client.
			var wanted = workbenchAvailable ? phone.workbenchService() : null, attached = attachedWorkbench;
			if (attached != wanted) {
				if (attached != null) created.detachWorkbench(attached);
				attachedWorkbench = wanted;
				if (wanted != null) {
					created.attachWorkbench(wanted);
					var open = phone.openView();
					var held = prefillHolding && (open == null ? null : open.workspace) == prefillHold;
					prefillHolding = false;
					if (!held) created.showSidebarMode("workbench");
				} else
					created.showSidebarMode("remote-access");
			}
		};
		created.showSidebarMode("remote-access");
		phone.connectSaved(credentials.unreadable);
		return created;
	}

	/** A random key kept in the app's files: the same for every process of this installation. */
	static function persistentClientKey(root:String):String {
		var path = root + "/terminal-client-key";
		try {
			if (FileSystem.exists(path)) {
				var key = StringTools.trim(sys.io.File.getContent(path));
				if (key.length >= 16 && key.length <= 128) return key;
			}
		} catch (_:Dynamic) {}
		var key = haxe.crypto.Sha256.encode(Sys.time() + ":" + Math.random() + ":" + Sys.getPid()).substr(0, 32);
		try sys.io.File.saveContent(path, key) catch (_:Dynamic) {}
		return key;
	}
}
