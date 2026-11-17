package ui;

import workspace.client.RemoteMachine;
import workspace.client.RemoteMachines;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import workspace.client.WorkspaceCatalogMirror;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineWorkspaceEntry;

/**
	A device's Remote view (the phone's, the browser's; ADR 0005 section 4): the machines this device is paired with and whether they are
	online, each machine's granted workspaces (the owner grants them on the machine; they appear here without pairing
	again), and each workspace's groups and sessions from its catalog. Tapping a workspace opens it as the attached
	workspace. Pairing another machine (URL, the code to compare) is below the list.
**/
class RemoteMachinesPanel implements View {
	/** Rows of groups and sessions shown per workspace before "and N more". */
	static inline final CATALOG_ROWS = 40;

	final remote:RemoteMachines;
	final requestFrame:Void->Void;
	var pairingUrl = "";

	public function new(remote:RemoteMachines, requestFrame:Void->Void) {
		this.remote = remote;
		this.requestFrame = requestFrame;
	}

	/** Puts a link into the pairing field (a shared invitation); the person still presses Pair. */
	public function prefill(url:String):Void {
		pairingUrl = url;
		requestFrame();
	}

	public function build(context:BuildContext):RenderNode {
		var tokens = context.theme.tokens;
		var rows:Array<KeyedView> = [new KeyedView("heading", new Text(remote.machines.length == 0 ? "Remote machines" : "Remote machines (" + remote.machines.length + ")"))];
		for (machine in remote.machines) machineRows(rows, machine, context);
		if (remote.authenticationCode != null) {
			rows.push(new KeyedView("code-instruction", new Text("Compare this code with the machine, then confirm.")));
			rows.push(new KeyedView("code", new Text(remote.authenticationCode, null, tokens.textPrimary, TextStyleOverride.text(28, TextWrap.None))));
			rows.push(new KeyedView("key-check", remote.machineKeyVerified ? new Text("The machine's key matches the invitation.", null, tokens.textSecondary)
				: new Text("This invitation carries no machine key (it comes from an older desktop), so comparing the code is the only check.",
					null, tokens.textSecondary)));
			if (remote.machineKeyChanged)
				rows.push(new KeyedView("key-changed", new Text("Warning: this phone is already paired with a machine of this id, and this one has a "
					+ "different key. Continue only if you reset or reinstalled that machine and created this invitation yourself. "
					+ "Confirming replaces the old pairing.", null, tokens.danger)));
			if (!remote.codeConfirmed) {
				var confirm = new Button(remote.machineKeyChanged ? "The code matches: replace the old pairing" : "The code matches", null,
					remote.confirmCode, "phone-pairing-confirm", true, ButtonVariant.Primary);
				rows.push(new KeyedView("confirm", confirm));
			}
		} else if (!remote.pairing) {
			var address = new TextField("phone-pairing-url", pairingUrl, function(value) {
				pairingUrl = value;
				requestFrame();
			});
			address.label = "One-time pairing URL";
			address.placeholder = "wss://…/v1/machines/…/pair/…?secret=…";
			address.style.width = LayoutAxis.grow();
			address.ellipsizeWhenUnfocused = true;
			rows.push(new KeyedView("url-label", new Text(remote.machines.length == 0 ? "Pair this device with a machine" : "Pair another machine", null, tokens.textSecondary)));
			// The field has no paste menu on a phone; this reads the host clipboard the way the terminal's Paste key does.
			var paste = new Button("Paste", null, function() {
				try context.clipboard.readText(function(text) {
					var trimmed = StringTools.trim(text == null ? "" : text);
					if (trimmed.length > 0) pairingUrl = trimmed;
					requestFrame();
				}) catch (_:Dynamic) {}
			}, "phone-pairing-paste");
			var addressRowStyle = new LayoutStyle();
			addressRowStyle.width = LayoutAxis.stretch();
			addressRowStyle.childGap = 8;
			rows.push(new KeyedView("url", new Row("phone-pairing-url-row", [new KeyedView("field", address), new KeyedView("paste", paste)], addressRowStyle)));
			var pair = new Button("Pair", null, function() {
				if (remote.beginPairing(pairingUrl)) pairingUrl = "";
				requestFrame();
			}, "phone-pairing-start", pairingUrl.length > 0, ButtonVariant.Primary);
			rows.push(new KeyedView("pair", pair));
		}
		if (remote.pairing)
			rows.push(new KeyedView("cancel", new Button("Cancel pairing", null, function() {
				remote.cancelPairing();
				requestFrame();
			}, "phone-pairing-cancel")));
		if (remote.status != "") rows.push(new KeyedView("status", new Text(remote.status, null, tokens.textSecondary)));
		if (remote.error != null) rows.push(new KeyedView("error", new Text(remote.error, null, tokens.danger)));
		var contentStyle = new LayoutStyle();
		contentStyle.width = LayoutAxis.stretch();
		contentStyle.childGap = 10;
		contentStyle.padding = new Insets(12, 8, 12, 8);
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.stretch();
		viewportStyle.height = LayoutAxis.grow();
		return new ScrollView("phone-remote-scroll", new Column("phone-remote-content", rows, contentStyle), viewportStyle).build(context);
	}

	function machineRows(rows:Array<KeyedView>, machine:RemoteMachine, context:BuildContext):Void {
		var tokens = context.theme.tokens;
		var key = machine.device.machineId + ":" + machine.device.deviceId;
		var refusal = machine.refusal();
		var online = machine.online();
		var state = refusal != null ? "needs attention" : online ? "online" : "offline";
		rows.push(new KeyedView("machine:" + key, new Text((online ? "● " : "○ ") + machine.name() + " · " + state, null, online ? tokens.textPrimary : tokens.textSecondary)));
		if (refusal != null) rows.push(new KeyedView("refusal:" + key, new Text(refusal, null, tokens.danger)));
		else if (!online) {
			var why = machine.machine.error;
			rows.push(new KeyedView("offline:" + key, new Text(why == null ? "Connecting to the machine…" : "Cannot reach the machine (" + why + "). Retrying.", null, tokens.textSecondary)));
		}
		var directory = machine.machine.directory;
		if (directory != null) {
			if (directory.workspaces.length == 0)
				rows.push(new KeyedView("none:" + key, new Text("Waiting for the owner to grant workspaces.", null, tokens.textSecondary)));
			for (entry in directory.workspaces) workspaceRows(rows, machine, entry, key);
		}
		rows.push(new KeyedView("forget:" + key, new Button("Forget " + machine.name(), null, function() {
			remote.forget(machine.device.machineId, machine.device.deviceId);
			requestFrame();
		}, "phone-forget-" + machine.device.deviceId.substr(0, 8))));
	}

	function workspaceRows(rows:Array<KeyedView>, machine:RemoteMachine, entry:MachineWorkspaceEntry, machineKey:String):Void {
		var key = machineKey + ":" + entry.workspace;
		var isOpen = remote.openMachine == machine && remote.openId == entry.workspace;
		var mirror = remote.mirrorOf(machine, entry.workspace);
		var count = mirror == null ? "" : " · " + mirror.sessionList().length + " sessions";
		var label = entry.name + " · " + (entry.status == MachineDirectoryProtocol.RUNNING ? "running" : "idle") + count + (isOpen ? " · open" : "");
		var button = new Button(label, null, function() {
			remote.openWorkspace(machine, entry.workspace);
			requestFrame();
		}, "phone-workspace-" + entry.workspace.substr(0, 12), true, isOpen ? ButtonVariant.Primary : null);
		rows.push(new KeyedView("workspace:" + key, button));
		if (mirror == null) return;
		var shown = 0, total = 0;
		var sessions = mirror.sessionList();
		var add = function(id:String, text:String):Void {
			total++;
			if (shown >= CATALOG_ROWS) return;
			shown++;
			rows.push(new KeyedView(id, new Text(text)));
		};
		for (group in mirror.groupList()) {
			add("group:" + key + ":" + group.id, "▸ " + group.name);
			for (session in sessions) if (session.group == group.id) add("session:" + key + ":" + session.id, "    • " + session.name + " · " + session.state);
		}
		var groupIds = [for (group in mirror.groupList()) group.id];
		for (session in sessions) if (session.group == "" || groupIds.indexOf(session.group) < 0) add("session:" + key + ":" + session.id, "• " + session.name + " · " + session.state);
		if (total > shown) rows.push(new KeyedView("more:" + key, new Text("and " + (total - shown) + " more")));
	}
}
