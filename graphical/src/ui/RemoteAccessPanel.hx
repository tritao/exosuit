package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import workspace.client.MachineRemoteAccess.MachineDeviceWorkspace;
import workspace.client.MachineRemoteAccess.MachineInvitation;
import workspace.client.MachineRemoteAccess.MachinePairedDevice;
import workspace.client.MachineRemoteAccess.MachineRemoteView;
import workspace.client.MachineRemoteAccess.MachineWorkspacePick;

/**
	Remote access for the whole machine (ADR 0005 section 4), from suit: the relay, pairing, and the devices with the
	workspaces each may use.
**/
class RemoteAccessPanel implements View {
	final machine:MachineRemoteView;
	final requestFrame:Void->Void;
	final copyText:String->Bool;
	var invitationError:Null<String>;
	var actionError:Null<String>;
	var confirmed:Map<String, Bool> = [];
	var editing:Map<String, Bool> = [];
	var relayOrigin:String = config.RelayUrl.DEFAULT;
	/** Set once the user types in the relay field: from then on the setting no longer replaces what is shown. */
	var relayEdited:Bool = false;
	var confirmDisconnect:Bool = false;
	/** The saved `remote/access/relay_url` setting (empty or null: the default), and how to save a new one. */
	public var relayUrlSetting:Null<Void->String>;
	public var saveRelayUrl:Null<String->Void>;
	var machineInvitation:Null<MachineInvitation>;
	/** The preset picked per device and workspace: `none`, `read`, `edit`, `all`, or `custom` for grants set elsewhere. */
	var workspacePicks:Map<String, Map<String, String>> = [];

	/**
		What a program that drives the window may read (`exosuit.state.get`): the relay status, the invitation on screen
		(including its one-time URL, a secret that the control plane gives only to processes of this user, the same
		boundary as the screen it is on) and the requests waiting for approval. Nothing here changes the panel.
	**/
	public function automationState():Dynamic {
		var machineStatus = machine.status(), machineList = machine.devices();
		return {
			relayUrl: currentRelayText(),
			relay: machineStatus == null ? null : {configured: machineStatus.enabled, connected: machineStatus.connected, origin: machineStatus.origin, error: machineStatus.error},
			connected: machineStatus != null,
			invitationUrl: machineInvitation == null ? null : machineInvitation.invitationUrl, invitationError: invitationError,
			pending: machineList == null ? [] : [for (item in machineList.pending) {deviceId: item.deviceId, code: item.authenticationCode}],
			devices: machineList == null ? [] : [for (device in machineList.devices) {deviceId: device.deviceId, connected: device.connected, revoked: device.revoked,
				workspaces: [for (entry in device.workspaces) {workspace: entry.workspace, preset: entry.preset}]}],
			workspaces: machineList == null ? [] : [for (entry in machineList.workspaces) {id: entry.id, name: entry.name}]
		};
	}

	public function new(machine:MachineRemoteView, requestFrame:Void->Void, copyText:String->Bool) {
		this.machine = machine;
		this.requestFrame = requestFrame;
		this.copyText = copyText;
	}

	function paragraph(value:String, context:BuildContext, secondary:Bool = false):Text {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		return new Text(value, style, secondary ? context.theme.tokens.textSecondary : context.theme.tokens.textPrimary,
			new TextStyleOverride(null, 13, 0, TextWrap.WordCharacter));
	}

	function permissionStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.height = LayoutAxis.fixed(28);
		style.padding = new Insets(2, 2, 2, 2);
		return style;
	}

	function sectionStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = 4;
		return style;
	}

	// ---- machine-level remote access: devices pair with the machine and are granted workspaces

	static final presetChoices:Array<{id:String, label:String}> = [
		{id: "none", label: "No access"},
		{id: "read", label: "Read only"},
		{id: "edit", label: "Edit files"},
		{id: "all", label: "All permissions"}
	];

	/** The picks of device `id`, one per workspace; `initial` (a paired device's grants) replaces them unless the owner is editing. */
	function picksOf(id:String, workspaces:Array<{id:String, name:String}>, ?initial:Array<MachineDeviceWorkspace>):Map<String, String> {
		var picks = workspacePicks.get(id);
		if (picks == null) {
			picks = [];
			workspacePicks.set(id, picks);
		}
		if (initial != null && editing.get(id) != true) {
			for (entry in workspaces) picks.set(entry.id, "none");
			for (entry in initial) picks.set(entry.workspace, entry.preset);
		}
		for (entry in workspaces) if (!picks.exists(entry.id)) picks.set(entry.id, "none");
		return picks;
	}

	function pickList(id:String, workspaces:Array<{id:String, name:String}>):Array<MachineWorkspacePick> {
		var picks = picksOf(id, workspaces);
		var result:Array<MachineWorkspacePick> = [];
		for (entry in workspaces) {
			var preset = picks.get(entry.id);
			if (preset != null && preset != "none" && preset != "custom") result.push({workspace: entry.id, preset: preset});
		}
		return result;
	}

	function pickSelectors(id:String, workspaces:Array<{id:String, name:String}>, prefix:String):Array<KeyedView> {
		var picks = picksOf(id, workspaces), result:Array<KeyedView> = [];
		for (entry in workspaces) {
			var workspaceId = entry.id, current = picks.get(workspaceId);
			var options = [for (choice in presetChoices) new SelectOption(choice.id, choice.label, choice.id)];
			if (current == "custom") options.push(new SelectOption("custom", "Custom (set elsewhere)", "custom"));
			var select = new Select<String>(prefix + id + "-" + workspaceId, options, current == null ? "none" : current, function(value) {
				if (value != "custom") picks.set(workspaceId, value);
				requestFrame();
			}, sectionStyle());
			select.accessibilityLabel = "Access to " + entry.name;
			result.push(new KeyedView("pick-name:" + workspaceId, new Text(entry.name)));
			result.push(new KeyedView("pick:" + workspaceId, select));
		}
		return result;
	}

	function workspaceName(workspaces:Array<{id:String, name:String}>, id:String):String {
		for (entry in workspaces) if (entry.id == id) return entry.name;
		return id.substr(0, 16);
	}

	function presetLabel(preset:String):String {
		for (choice in presetChoices) if (choice.id == preset) return choice.label.toLowerCase();
		return "custom";
	}

	function machineDeviceLabel(device:MachinePairedDevice, workspaces:Array<{id:String, name:String}>):String {
		var label = device.deviceId.substr(0, 8);
		label += device.connected ? " · connected" : device.revoked ? " · revoked" : " · offline";
		if (device.workspaces.length == 0) return label + " · no workspaces";
		return label + " · " + [for (entry in device.workspaces) workspaceName(workspaces, entry.workspace) + " (" + presetLabel(entry.preset) + ")"].join(", ");
	}

	/** The text for the relay field: what the user typed, else the saved setting, else the default. */
	function currentRelayText():String {
		if (!relayEdited) relayOrigin = config.RelayUrl.resolve(relayUrlSetting == null ? null : relayUrlSetting());
		return relayOrigin;
	}

	/** Checks the field, remembers a non-default relay in the settings and returns its origin; null with `actionError` set on a bad one. */
	function chosenRelay():Null<String> {
		var checked = config.RelayUrl.check(relayOrigin);
		if (checked.origin == null) { actionError = checked.error; requestFrame(); return null; }
		actionError = null;
		if (saveRelayUrl != null) saveRelayUrl(checked.origin);
		return checked.origin;
	}

	function relayField():TextField {
		var address = new TextField("remote-relay-origin", currentRelayText(), function(value) { relayOrigin = value; relayEdited = true; requestFrame(); });
		address.style.width = LayoutAxis.stretch();
		address.ellipsizeWhenUnfocused = true;
		address.label = "Relay URL";
		address.placeholder = config.RelayUrl.DEFAULT;
		return address;
	}

	function addMachineRows(view:MachineRemoteView, rows:Array<KeyedView>, context:BuildContext):Void {
		view.refresh(false);
		var status = view.status(), list = view.devices();
		var hasPending = list != null && list.pending.length > 0;
		var workspaces = list == null ? [] : list.workspaces;
		rows.push(new KeyedView("status", paragraph(status == null ? "Checking remote access…" : !status.enabled ? "Remote access not configured"
			: status.connected ? "Remote access ready" : status.error != null ? "Relay unavailable" : "Relay connecting", context)));
		if (!hasPending) rows.push(new KeyedView("intro", paragraph("Pair a phone, browser or another device with this machine. It sees only the workspaces you choose; files and sessions stay on this machine and relay traffic is encrypted end to end.", context, true)));
		if (status != null && !status.enabled) {
			var address = relayField();
			rows.push(new KeyedView("relay-label", paragraph("Relay URL", context)));
			rows.push(new KeyedView("relay-url", address));
			rows.push(new KeyedView("relay-hint", paragraph("Use the Exosuit relay, or enter your own HTTPS relay (docs/mobile/own-relay.md). Saved in Settings as Remote access / Relay URL.", context, true)));
			var enable = new Button("Enable remote access", null, function() {
				var origin = chosenRelay();
				if (origin == null) return;
				view.enable(origin, function(error) { actionError = error; requestFrame(); });
			}, "remote-access-enable");
			enable.variant = ButtonVariant.Primary;
			enable.enabled = StringTools.trim(relayOrigin).length > 0 && !view.busy();
			rows.push(new KeyedView("enable", enable));
		}
		if (status != null && status.origin != null) rows.push(new KeyedView("relay", paragraph("Relay: " + status.origin, context, true)));
		if (status != null && status.error != null) rows.push(new KeyedView("relay-error", paragraph("Relay connection: " + status.error, context)));
		if (status != null && status.enabled && !hasPending) {
			if (!confirmDisconnect) {
				rows.push(new KeyedView("relay-change", new Button("Use a different relay", null, function() { confirmDisconnect = true; requestFrame(); }, "remote-access-change-relay")));
			} else {
				rows.push(new KeyedView("relay-change-warning", paragraph("Disconnect from this relay? Devices paired through it stop working until they pair again through the new relay. Files and sessions are not touched.", context, true)));
				var disconnect = new Button("Disconnect from this relay", null, function() {
					confirmDisconnect = false;
					view.disable(function(error) { actionError = error; relayEdited = false; requestFrame(); });
				}, "remote-access-disconnect-relay");
				disconnect.enabled = !view.busy();
				rows.push(new KeyedView("relay-change-confirm", disconnect));
				rows.push(new KeyedView("relay-change-cancel", new Button("Keep this relay", null, function() { confirmDisconnect = false; requestFrame(); }, "remote-access-keep-relay")));
			}
		}
		if (status != null && status.enabled && !hasPending) {
			var create = new Button(view.busy() ? "Working…" : "Create pairing invitation", null, function() {
				machineInvitation = null;
				invitationError = null;
				view.invite(300, function(value, error) { machineInvitation = value; invitationError = error; requestFrame(); });
			}, "remote-access-create");
			create.variant = ButtonVariant.Primary;
			create.enabled = !view.busy() && status.connected;
			rows.push(new KeyedView("create", create));
		}
		var current = machineInvitation;
		if (current != null && !hasPending) {
			rows.push(new KeyedView("invitation-title", new Text("One-time invitation · expires in " + current.expiresInSeconds + " seconds")));
			rows.push(new KeyedView("invitation-target", new Text("Device " + current.deviceId.substr(0, 8) + " · one-time pairing URL")));
			rows.push(new KeyedView("invitation-warning", paragraph("Treat this URL like a password. Access starts only after code confirmation and your approval, and the device gets only the workspaces you pick.", context, true)));
			var copy = new Button("Copy one-time pairing URL", null, function() {
				if (copyText == null || !copyText(current.invitationUrl)) actionError = "Could not copy the pairing address";
				else actionError = "Pairing address copied";
				requestFrame();
			}, "remote-access-copy");
			copy.enabled = copyText != null;
			rows.push(new KeyedView("copy", copy));
		}
		if (invitationError != null) rows.push(new KeyedView("invitation-error", paragraph("Could not create invitation: " + invitationError, context)));
		if (status != null && status.enabled && !hasPending) rows.push(new KeyedView("pending-empty", paragraph("No device is waiting to pair.", context, true)));
		if (list != null && list.pending.length > 0) {
			rows.push(new KeyedView("pending-title", new Text("Requests waiting for approval")));
			for (pending in list.pending) {
				var id = pending.deviceId;
				var approve = new Button("Approve", null, function() {
					view.approve(id, pickList(id, workspaces), function(error) { actionError = error; requestFrame(); });
				}, "pairing-approve-" + id);
				approve.enabled = !view.busy() && confirmed.get(id) == true;
				var reject = new Button("Reject", null, function() {
					view.reject(id, function(error) { actionError = error; requestFrame(); });
				}, "pairing-reject-" + id);
				reject.enabled = !view.busy();
				var details:Array<KeyedView> = [
					new KeyedView("code-heading", paragraph("Compare this code on both devices", context)),
					new KeyedView("code", new Text(pending.authenticationCode, null, context.theme.tokens.textPrimary, new TextStyleOverride(null, 24, 0, TextWrap.None))),
					new KeyedView("id", paragraph("Device " + id.substr(0, 16) + " · expires in " + pending.expiresInSeconds + " seconds", context, true)),
					new KeyedView("confirmed", new Checkbox("pairing-confirm-" + id, "I checked both codes", confirmed.get(id) == true,
						function(value) { confirmed.set(id, value); requestFrame(); })),
					new KeyedView("workspaces-title", paragraph("Workspaces this device may use", context)),
					new KeyedView("workspaces-hint", paragraph(workspaces.length == 0 ? "This machine has no workspaces yet." : "Nothing is selected by default. A device sees only the workspaces you give it access to.", context, true))
				];
				for (entry in pickSelectors(id, workspaces, "pairing-workspace-")) details.push(entry);
				details.push(new KeyedView("actions", new Row("pairing-actions-" + id, [new KeyedView("approve", approve), new KeyedView("reject", reject)], sectionStyle())));
				rows.push(new KeyedView("request:" + id, new Column("pairing-request-" + id, details, sectionStyle())));
			}
		}
		if (list != null && list.devices.length > 0) rows.push(new KeyedView("devices-title", new Text("Paired devices")));
		if (list != null) for (device in list.devices) {
			var deviceId = device.deviceId;
			var children:Array<KeyedView> = [new KeyedView("details", paragraph(machineDeviceLabel(device, workspaces), context))];
			if (!device.revoked) {
				picksOf(deviceId, workspaces, device.workspaces);
				if (editing.get(deviceId) != true) {
					children.push(new KeyedView("edit-permissions", new Button("Edit workspaces", null, function() {
						picksOf(deviceId, workspaces, device.workspaces);
						editing.set(deviceId, true);
						requestFrame();
					}, "pairing-edit-grants-" + deviceId)));
				} else {
					children.push(new KeyedView("permissions-title", paragraph("Workspaces this device may use", context)));
					for (entry in pickSelectors(deviceId, workspaces, "pairing-device-workspace-")) children.push(entry);
					children.push(new KeyedView("save-permissions", new Button(view.busy() ? "Saving…" : "Save workspaces", null, function() {
						view.grant(deviceId, pickList(deviceId, workspaces), function(error) {
							if (error == null) editing.set(deviceId, false);
							actionError = error == null ? "Workspaces updated. Open streams to removed workspaces were closed." : error;
							requestFrame();
						});
					}, "pairing-save-grants-" + deviceId)));
					children.push(new KeyedView("cancel-permissions", new Button("Cancel", null, function() {
						editing.set(deviceId, false);
						picksOf(deviceId, workspaces, device.workspaces);
						requestFrame();
					}, "pairing-cancel-grants-" + deviceId)));
				}
				var revoke = new Button("Revoke", null, function() {
					view.revoke(deviceId, function(error) { actionError = error == null ? "Device revoked" : error; requestFrame(); });
				}, "pairing-revoke-" + deviceId);
				revoke.enabled = !view.busy();
				children.push(new KeyedView("revoke", revoke));
			}
			rows.push(new KeyedView("device:" + deviceId, new Column("paired-device-" + deviceId, children, sectionStyle())));
		}
	}

	public function build(context:BuildContext):RenderNode {
		var rows:Array<KeyedView> = [];
		addMachineRows(machine, rows, context);
		var failure = actionError == null ? machine.error() : actionError;
		if (failure != null) rows.push(new KeyedView("error", paragraph(failure, context)));
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = 12;
		style.padding = new Insets(12, 12, 12, 12);
		var body = new Column("remote-access-content", rows, style);
		var viewport = new LayoutStyle();
		viewport.width = LayoutAxis.stretch();
		viewport.height = LayoutAxis.grow();
		return new ScrollView("remote-access-scroll", body, viewport).build(context);
	}
}
