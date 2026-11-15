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
import workspace.client.WorkspacePairingClient;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspacePairingProtocol.PairingDevice;
import workspace.service.WorkspacePairingProtocol.PairingInvitation;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** Same-user desktop controls for approving and revoking remote workspace devices. */
class RemoteAccessPanel implements View {
	final client:WorkspacePairingClient;
	final requestFrame:Void->Void;
	final copyText:String->Bool;
	var invitation:Null<PairingInvitation>;
	var invitationError:Null<String>;
	var actionError:Null<String>;
	var selections:Map<String, Map<String, Bool>> = [];
	var confirmed:Map<String, Bool> = [];
	var editing:Map<String, Bool> = [];
	var relayOrigin:String = config.RelayUrl.DEFAULT;
	/** Set once the user types in the relay field: from then on the setting no longer replaces what is shown. */
	var relayEdited:Bool = false;
	var confirmDisconnect:Bool = false;
	/** The saved `remote/access/relay_url` setting (empty or null: the default), and how to save a new one. */
	public var relayUrlSetting:Null<Void->String>;
	public var saveRelayUrl:Null<String->Void>;
	var confirmRestart:Bool = false;
	/**
		Remote access for the whole machine (ADR 0005 section 4), when suit is on: the relay, pairing and the devices
		with the workspaces each may use come from it. Null means suit is off, and the panel pairs with the open
		workspace's service as before.
	**/
	public var machine:Null<MachineRemoteView>;
	var machineInvitation:Null<MachineInvitation>;
	/** The preset picked per device and workspace: `none`, `read`, `edit`, `all`, or `custom` for grants set elsewhere. */
	var workspacePicks:Map<String, Map<String, String>> = [];

	static final grantOptions:Array<{id:String, label:String, grant:String, defaultValue:Bool}> = [
		{id: "files", label: "Read project files", grant: WorkspaceProtocol.READ, defaultValue: true},
		{id: "events", label: "Receive updates", grant: WorkspaceProtocol.EVENTS, defaultValue: true},
		{id: "edit", label: "Edit and save files", grant: WorkspaceProtocol.WRITE, defaultValue: false},
		{id: "tree", label: "Browse project folders", grant: WorkspaceProtocol.TREE, defaultValue: true},
		{id: "terminal-read", label: "Read terminals", grant: WorkspaceTerminalProtocol.READ, defaultValue: true},
		{id: "terminal-catalog", label: "List terminals", grant: WorkspaceTerminalProtocol.CATALOG, defaultValue: true},
		{id: "terminal-control", label: "Control terminals", grant: WorkspaceTerminalProtocol.CONTROL, defaultValue: false},
		{id: "agent-read", label: "Read Codex sessions", grant: WorkspaceAgentProtocol.READ, defaultValue: true},
		{id: "agent-control", label: "Control Codex sessions", grant: WorkspaceAgentProtocol.CONTROL, defaultValue: false},
		{id: "scm-read", label: "Review source control", grant: workspace.service.WorkspaceScmProtocol.READ, defaultValue: true},
		{id: "scm-write", label: "Change source control", grant: workspace.service.WorkspaceScmProtocol.WRITE, defaultValue: false},
		{id: "scm-remote", label: "Fetch and push Git remotes", grant: workspace.service.WorkspaceScmProtocol.REMOTE, defaultValue: false},
		{id: "catalog", label: "List workspaces and sessions", grant: workspace.service.WorkspaceCatalogProtocol.CAPABILITY, defaultValue: false}
	];

	/**
		What a test driver (EXOSUIT_AUTOMATION_DIR, see devtools.AutomationProbe) may read: the relay status, the invitation
		on screen (including its one-time URL, which is a secret: the automation folder is owner-only and exists only in
		a test run) and the requests waiting for approval. Nothing here changes the panel.
	**/
	public function automationState():Dynamic {
		var view = machine;
		if (view != null) {
			var machineStatus = view.status(), machineList = view.devices();
			return {
				machine: true,
				relayUrl: currentRelayText(),
				relay: machineStatus == null ? null : {configured: machineStatus.enabled, connected: machineStatus.connected, origin: machineStatus.origin, error: machineStatus.error},
				canManage: true, canConfigure: true, connected: machineStatus != null,
				invitationUrl: machineInvitation == null ? null : machineInvitation.invitationUrl, invitationError: invitationError,
				pending: machineList == null ? [] : [for (item in machineList.pending) {deviceId: item.deviceId, code: item.authenticationCode}],
				devices: machineList == null ? [] : [for (device in machineList.devices) {deviceId: device.deviceId, connected: device.connected, revoked: device.revoked,
					workspaces: [for (entry in device.workspaces) {workspace: entry.workspace, preset: entry.preset}]}],
				workspaces: machineList == null ? [] : [for (entry in machineList.workspaces) {id: entry.id, name: entry.name}]
			};
		}
		var status = client.remoteAccessStatus(), list = client.pairingList();
		return {
			relay: status == null ? null : {configured: status.configured, connected: status.connected, origin: status.origin, error: status.error},
			canManage: client.canManagePairings(), canConfigure: client.canConfigureRelay(), connected: client.workspaceConnected(),
			invitationUrl: invitation == null ? null : invitation.pairingSocketUrl, invitationError: invitationError,
			pending: list == null ? [] : [for (item in list.pending) {deviceId: item.deviceId, code: item.authenticationCode}],
			devices: list == null ? [] : [for (device in list.devices) {deviceId: device.deviceId, connected: device.connected, revoked: device.revoked, grants: device.grants.length}]
		};
	}

	public function new(client:WorkspacePairingClient, requestFrame:Void->Void, copyText:String->Bool) {
		this.client = client;
		this.requestFrame = requestFrame;
		this.copyText = copyText;
	}

	function selection(id:String, ?initialGrants:Array<String>):Map<String, Bool> {
		var selected = selections.get(id);
		if (selected == null) {
			selected = [];
			for (option in grantOptions) selected.set(option.id, option.defaultValue);
			selections.set(id, selected);
		}
		if (initialGrants != null && editing.get(id) != true)
			for (option in grantOptions) selected.set(option.id, initialGrants.indexOf(option.grant) >= 0);
		return selected;
	}

	function grants(id:String):Array<String> {
		var selected = selection(id);
		var result:Array<String> = [WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceProtocol.ORDER];
		for (option in grantOptions) if (selected.get(option.id) == true) result.push(option.grant);
		if (selected.get("files") == true) result.push(workspace.service.WorkspaceFileProtocol.READ);
		return result;
	}

	function createInvitation():Void {
		invitation = null;
		invitationError = null;
		client.createPairing(300, function(value, error) {
			invitation = value;
			invitationError = error;
			requestFrame();
		});
		requestFrame();
	}

	function deviceLabel(device:PairingDevice):String {
		var label = device.deviceId.substr(0, 8);
		label += device.connected ? " · connected" : device.revoked ? " · revoked" : " · offline";
		if (device.grants.length > 0) {
			var names = [for (grant in device.grants) grantName(grant)];
			label += " · " + names.join(", ");
		}
		return label;
	}

	function grantName(grant:String):String {
		if (grant == WorkspaceProtocol.READ) return "files";
		if (grant == workspace.service.WorkspaceFileProtocol.READ) return "saved files";
		if (grant == WorkspaceProtocol.EVENTS) return "updates";
		if (grant == WorkspaceProtocol.WRITE) return "editing";
		if (grant == WorkspaceProtocol.TREE) return "folder browsing";
		if (grant == WorkspaceTerminalProtocol.READ) return "terminal output";
		if (grant == WorkspaceTerminalProtocol.CATALOG) return "terminal list";
		if (grant == WorkspaceTerminalProtocol.CONTROL) return "terminal control";
		if (grant == WorkspaceAgentProtocol.READ) return "Codex sessions";
		if (grant == WorkspaceAgentProtocol.CONTROL) return "Codex control";
		if (grant == workspace.service.WorkspaceScmProtocol.READ) return "source control review";
		if (grant == workspace.service.WorkspaceScmProtocol.WRITE) return "source control changes";
		if (grant == workspace.service.WorkspaceScmProtocol.REMOTE) return "Git remotes";
		if (grant == WorkspaceProtocol.IDENTITY_CAPABILITY) return "workspace identity";
		if (grant == workspace.service.WorkspaceCatalogProtocol.CAPABILITY) return "workspace list";
		return grant;
	}

	function grantCheckboxes(id:String):Array<KeyedView> {
		var selected = selection(id);
		var result:Array<KeyedView> = [];
		for (option in grantOptions) {
			var checkbox = new Checkbox("pairing-grant-" + id + "-" + option.id, option.label,
				selected.get(option.id) == true, function(value) {
					selected.set(option.id, value);
					requestFrame();
				}, permissionStyle());
			result.push(new KeyedView(option.id, checkbox));
		}
		return result;
	}

	function preset(id:String):String {
		var selected = selection(id), all = true, read = true, edit = true;
		for (option in grantOptions) {
			var checked = selected.get(option.id) == true;
			var reading = option.defaultValue;
			if (!checked) all = false;
			if (checked != reading) read = false;
			if (checked != (reading || option.id == "edit")) edit = false;
		}
		return all ? "all" : read ? "read" : edit ? "edit" : "custom";
	}

	function setPreset(id:String, preset:String):Void {
		var selected = selection(id);
		for (option in grantOptions) selected.set(option.id, preset == "all"
			|| option.defaultValue || preset == "edit" && option.id == "edit");
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

	/** What "Restart now" costs: terminals in terminal hosts are picked up again by the restarted service, the rest end. */
	public static function restartWarning(terminals:Int, kept:Int):String {
		if (kept <= 0) return "Restarting ends active terminal and Codex sessions. Continue?";
		if (kept >= terminals) return "Restarting ends active Codex sessions. Terminals stay running and reconnect. Continue?";
		return "Restarting ends active Codex sessions and " + (terminals - kept) + " of " + terminals + " terminals; the others stay running and reconnect. Continue?";
	}

	public function build(context:BuildContext):RenderNode {
		var list = client.pairingList();
		var hasPending = list != null && list.pending.length > 0;
		var rows:Array<KeyedView> = [];
		var service = client.serviceStatus();
		if (client.serviceUpdateAvailable() || client.serviceUpdateBusy() || service != null && service.updatePending) {
			rows.push(new KeyedView("update-title", paragraph("Workspace service update available", context)));
			var kept = service == null || service.keptTerminals == null ? 0 : service.keptTerminals;
			if (service != null) rows.push(new KeyedView("update-sessions", paragraph(
				service.terminals + " terminal sessions · " + service.agents + " Codex sessions active"
				+ (kept > 0 ? " · " + (kept >= service.terminals ? "all" : Std.string(kept)) + " terminals stay running through a restart" : ""), context, true)));
			else rows.push(new KeyedView("update-legacy", paragraph("This older service cannot check session activity safely. A one-time restart is required.", context, true)));
			if (client.serviceUpdateBusy()) rows.push(new KeyedView("update-preparing", paragraph("Preparing update. Existing sessions remain available.", context, true)));
			else if (service != null && service.updatePending) {
				rows.push(new KeyedView("update-waiting", paragraph("Update scheduled. Waiting for terminal and Codex sessions to finish.", context, true)));
				rows.push(new KeyedView("update-cancel", new Button("Cancel scheduled update", null, function() { client.requestServiceUpdate("cancel"); requestFrame(); }, "service-update-cancel")));
			} else if (service != null) {
				rows.push(new KeyedView("update-idle", new Button("Update when idle", null, function() { client.requestServiceUpdate("idle"); requestFrame(); }, "service-update-idle")));
			}
			if (!client.serviceUpdateBusy()) {
				if (!confirmRestart) rows.push(new KeyedView("update-now", new Button("Restart now…", null, function() { confirmRestart = true; requestFrame(); }, "service-update-now")));
				else {
					rows.push(new KeyedView("update-warning", paragraph(restartWarning(service == null ? 0 : service.terminals, kept), context)));
					rows.push(new KeyedView("update-confirm", new Button("Restart workspace service", null, function() { confirmRestart = false; client.requestServiceUpdate("now"); requestFrame(); }, "service-update-confirm")));
					rows.push(new KeyedView("update-keep", new Button("Keep sessions running", null, function() { confirmRestart = false; requestFrame(); }, "service-update-keep")));
				}
			}
		}
		if (client.serviceUpdateError() != null) rows.push(new KeyedView("update-error", paragraph(client.serviceUpdateError(), context)));
		var view = machine;
		if (view != null) addMachineRows(view, rows, context);
		else {
		var status = client.remoteAccessStatus();
		var connected = client.workspaceConnected();
		var statusLabel = !connected ? "Local workspace disconnected"
			: status == null ? (client.canManagePairings() ? "Local workspace connected · Remote access ready"
				: client.canConfigureRelay() ? "Local workspace connected · Checking remote access…"
				: "Local workspace connected · Remote access status unavailable")
			: !status.configured ? "Local workspace connected · Remote access not configured"
			: status.connected ? "Local workspace connected · Remote access ready"
			: status.error != null ? "Local workspace connected · Relay unavailable"
			: "Local workspace connected · Relay connecting";
		rows.push(new KeyedView("status", paragraph(statusLabel, context)));
		if (!hasPending) rows.push(new KeyedView("intro", paragraph("Pair a browser or another device with this workspace. Files and sessions stay on this machine; relay traffic is encrypted end to end.", context, true)));
		if (connected && status != null && !status.configured && client.canConfigureRelay()) {
			var address = relayField();
			rows.push(new KeyedView("relay-label", paragraph("Relay URL", context)));
			rows.push(new KeyedView("relay-url", address));
			rows.push(new KeyedView("relay-hint", paragraph("Use the Exosuit relay, or enter your own HTTPS relay (docs/mobile/own-relay.md). Saved in Settings as Remote access / Relay URL.", context, true)));
			var enable = new Button("Enable remote access", null, function() {
				var origin = chosenRelay();
				if (origin != null) client.configureRelay(origin);
				requestFrame();
			}, "remote-access-enable");
			enable.variant = ButtonVariant.Primary;
			enable.enabled = StringTools.trim(relayOrigin).length > 0;
			rows.push(new KeyedView("enable", enable));
		} else if (connected && status == null && !client.canConfigureRelay() && !client.canManagePairings()) {
			rows.push(new KeyedView("upgrade", paragraph("This workspace daemon needs an update to configure remote access here. Existing sessions are still available.", context, true)));
		}
		if (status != null && status.origin != null) rows.push(new KeyedView("relay", paragraph("Relay: " + status.origin, context, true)));
		if (status != null && status.error != null) rows.push(new KeyedView("relay-error", paragraph("Relay connection: " + status.error, context)));
		if (client.canManagePairings() && !hasPending) {
			var create = new Button(client.pairingBusy() ? "Creating invitation…" : "Create pairing invitation", null,
				createInvitation, "remote-access-create");
			create.variant = ButtonVariant.Primary;
			create.enabled = !client.pairingBusy();
			rows.push(new KeyedView("create", create));
		}
		var currentInvitation = invitation;
		if (currentInvitation != null && !hasPending) {
			rows.push(new KeyedView("invitation-title", new Text("One-time invitation · expires in " + currentInvitation.expiresInSeconds + " seconds")));
			rows.push(new KeyedView("invitation-target", new Text("Device " + currentInvitation.deviceId.substr(0, 8) + " · one-time pairing URL")));
			rows.push(new KeyedView("invitation-warning", paragraph("Treat this URL like a password. Access starts only after code confirmation and your approval.", context, true)));
			var copy = new Button("Copy one-time pairing URL", null, function() {
				if (copyText == null || !copyText(currentInvitation.pairingSocketUrl)) actionError = "Could not copy the pairing address";
				else actionError = "Pairing address copied";
				requestFrame();
			}, "remote-access-copy");
			copy.enabled = copyText != null;
			rows.push(new KeyedView("copy", copy));
		}
		if (invitationError != null) rows.push(new KeyedView("invitation-error", paragraph("Could not create invitation: " + invitationError, context)));
		if (client.canManagePairings() && (list == null || list.pending.length == 0))
			rows.push(new KeyedView("pending-empty", paragraph("No device is waiting to pair.", context, true)));
		if (list != null && list.pending.length > 0) {
			rows.push(new KeyedView("pending-title", new Text("Requests waiting for approval")));
			for (pending in list.pending) {
				var approve = new Button("Approve", null, function() {
					var id = pending.deviceId;
					client.approvePairing(id, grants(id), function(error) { actionError = error; requestFrame(); });
					requestFrame();
				}, "pairing-approve-" + pending.deviceId);
				approve.enabled = !client.pairingBusy() && confirmed.get(pending.deviceId) == true;
				var reject = new Button("Reject", null, function() {
					var id = pending.deviceId;
					client.rejectPairing(id, function(error) { actionError = error; requestFrame(); });
					requestFrame();
				}, "pairing-reject-" + pending.deviceId);
				reject.enabled = !client.pairingBusy();
				var id = pending.deviceId;
				var permissions:Array<KeyedView> = [
					new KeyedView("code-heading", paragraph("Compare this code on both devices", context)),
					new KeyedView("code", new Text(pending.authenticationCode, null, context.theme.tokens.textPrimary, new TextStyleOverride(null, 24, 0, TextWrap.None))),
					new KeyedView("id", paragraph("Device " + id.substr(0, 16) + " · expires in " + pending.expiresInSeconds + " seconds", context, true)),
					new KeyedView("confirmed", new Checkbox("pairing-confirm-" + id, "I checked both codes", confirmed.get(id) == true,
						function(value) { confirmed.set(id, value); requestFrame(); })),
					new KeyedView("permissions-title", paragraph("Permissions to approve", context)),
					new KeyedView("permissions-hint", paragraph("Read-only access is selected by default. Review write and control access before approving.", context, true))
				];
				var presets = new Select<String>("pairing-presets-" + id, [
					new SelectOption("all", "All permissions", "all"),
					new SelectOption("read", "Read only", "read"),
					new SelectOption("edit", "Edit files", "edit"),
					new SelectOption("custom", "Custom", "custom")
				], preset(id), function(value) { if (value != "custom") setPreset(id, value); requestFrame(); }, sectionStyle());
				presets.accessibilityLabel = "Permission preset";
				permissions.push(new KeyedView("presets", presets));
				for (entry in grantCheckboxes(id)) permissions.push(entry);
				permissions.push(new KeyedView("actions", new Row("pairing-actions-" + id,
					[new KeyedView("approve", approve), new KeyedView("reject", reject)], sectionStyle())));
				var details = new Column("pairing-request-" + id, permissions, sectionStyle());
				rows.push(new KeyedView("request:" + pending.deviceId, details));
			}
		}
		if (list != null && list.devices.length > 0) rows.push(new KeyedView("devices-title", new Text("Paired devices")));
		if (list != null) for (device in list.devices) {
			var children:Array<KeyedView> = [new KeyedView("details", paragraph(deviceLabel(device), context))];
			if (!device.revoked) {
				var deviceId = device.deviceId;
				selection(deviceId, device.grants);
				if (editing.get(deviceId) != true) {
					children.push(new KeyedView("edit-permissions", new Button("Edit permissions", null, function() {
						selection(deviceId, device.grants);
						editing.set(deviceId, true);
						requestFrame();
					}, "pairing-edit-grants-" + deviceId)));
				} else {
					children.push(new KeyedView("permissions-title", paragraph("Device permissions", context)));
					var presets = new Select<String>("pairing-device-presets-" + deviceId, [
						new SelectOption("all", "All permissions", "all"),
						new SelectOption("read", "Read only", "read"),
						new SelectOption("edit", "Edit files", "edit"),
						new SelectOption("custom", "Custom", "custom")
					], preset(deviceId), function(value) { if (value != "custom") setPreset(deviceId, value); requestFrame(); }, sectionStyle());
					presets.accessibilityLabel = "Device permission preset";
					children.push(new KeyedView("presets", presets));
					for (entry in grantCheckboxes(deviceId)) children.push(entry);
					children.push(new KeyedView("save-permissions", new Button(client.pairingBusy() ? "Saving permissions…" : "Save permissions", null, function() {
						client.setPairingGrants(deviceId, grants(deviceId), function(error) {
							if (error == null) editing.set(deviceId, false);
							actionError = error == null ? "Permissions updated. The device must reconnect." : error;
							requestFrame();
						});
						requestFrame();
					}, "pairing-save-grants-" + deviceId)));
					children.push(new KeyedView("cancel-permissions", new Button("Cancel", null, function() {
						editing.set(deviceId, false);
						selection(deviceId, device.grants);
						requestFrame();
					}, "pairing-cancel-grants-" + deviceId)));
				}
				var revoke = new Button("Revoke", null, function() {
					var id = deviceId;
					client.revokePairing(id, function(error) { actionError = error == null ? "Device revoked" : error; requestFrame(); });
					requestFrame();
				}, "pairing-revoke-" + deviceId);
				revoke.enabled = !client.pairingBusy();
				children.push(new KeyedView("revoke", revoke));
			}
			rows.push(new KeyedView("device:" + device.deviceId, new Column("paired-device-" + device.deviceId, children, sectionStyle())));
		}
		}
		var failure = actionError == null ? (view != null ? view.error() : client.pairingError()) : actionError;
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
