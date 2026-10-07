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
	var relayOrigin:String = "https://exosuit-relay.joao-9f7.workers.dev";
	var confirmRestart:Bool = false;

	static final grantOptions:Array<{id:String, label:String, grant:String, defaultValue:Bool}> = [
		{id: "files", label: "Read project files", grant: WorkspaceProtocol.READ, defaultValue: true},
		{id: "events", label: "Receive updates", grant: WorkspaceProtocol.EVENTS, defaultValue: true},
		{id: "edit", label: "Edit and save files", grant: WorkspaceProtocol.WRITE, defaultValue: true},
		{id: "tree", label: "Browse project folders", grant: WorkspaceProtocol.TREE, defaultValue: true},
		{id: "terminal-read", label: "Read terminals", grant: WorkspaceTerminalProtocol.READ, defaultValue: true},
		{id: "terminal-catalog", label: "List terminals", grant: WorkspaceTerminalProtocol.CATALOG, defaultValue: true},
		{id: "terminal-control", label: "Control terminals", grant: WorkspaceTerminalProtocol.CONTROL, defaultValue: true},
		{id: "agent-read", label: "Read Codex sessions", grant: WorkspaceAgentProtocol.READ, defaultValue: true},
		{id: "agent-control", label: "Control Codex sessions", grant: WorkspaceAgentProtocol.CONTROL, defaultValue: true}
	];

	public function new(client:WorkspacePairingClient, requestFrame:Void->Void, copyText:String->Bool) {
		this.client = client;
		this.requestFrame = requestFrame;
		this.copyText = copyText;
	}

	function selection(id:String):Map<String, Bool> {
		var selected = selections.get(id);
		if (selected == null) {
			selected = [];
			for (option in grantOptions) selected.set(option.id, option.defaultValue);
			selections.set(id, selected);
		}
		return selected;
	}

	function grants(id:String):Array<String> {
		var selected = selection(id);
		var result:Array<String> = [WorkspaceProtocol.IDENTITY_CAPABILITY];
		for (option in grantOptions) if (selected.get(option.id) == true) result.push(option.grant);
		if (selected.get("files") == true) result.push(workspace.service.WorkspaceFileProtocol.READ);
		return result;
	}

	function createInvitation():Void {
		invitation = null;
		invitationError = null;
		client.createPairing(180, function(value, error) {
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
		if (grant == WorkspaceProtocol.IDENTITY_CAPABILITY) return "workspace identity";
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
			var reading = option.id == "files" || option.id == "events" || option.id == "tree";
			if (!checked) all = false;
			if (checked != reading) read = false;
			if (checked != (reading || option.id == "edit")) edit = false;
		}
		return all ? "all" : read ? "read" : edit ? "edit" : "custom";
	}

	function setPreset(id:String, preset:String):Void {
		var selected = selection(id);
		for (option in grantOptions) selected.set(option.id, preset == "all"
			|| option.id == "files" || option.id == "events" || option.id == "tree" || preset == "edit" && option.id == "edit");
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

	public function build(context:BuildContext):RenderNode {
		var list = client.pairingList();
		var hasPending = list != null && list.pending.length > 0;
		var rows:Array<KeyedView> = [];
		var service = client.serviceStatus();
		if (client.serviceUpdateAvailable() || client.serviceUpdateBusy() || service != null && service.updatePending) {
			rows.push(new KeyedView("update-title", paragraph("Workspace service update available", context)));
			if (service != null) rows.push(new KeyedView("update-sessions", paragraph(
				service.terminals + " terminal sessions · " + service.agents + " Codex sessions active", context, true)));
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
					rows.push(new KeyedView("update-warning", paragraph("Restarting ends active terminal and Codex sessions. Continue?", context)));
					rows.push(new KeyedView("update-confirm", new Button("Restart workspace service", null, function() { confirmRestart = false; client.requestServiceUpdate("now"); requestFrame(); }, "service-update-confirm")));
					rows.push(new KeyedView("update-keep", new Button("Keep sessions running", null, function() { confirmRestart = false; requestFrame(); }, "service-update-keep")));
				}
			}
		}
		if (client.serviceUpdateError() != null) rows.push(new KeyedView("update-error", paragraph(client.serviceUpdateError(), context)));
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
			var address = new TextField("remote-relay-origin", relayOrigin, function(value) { relayOrigin = value; requestFrame(); });
			address.style.width = LayoutAxis.stretch();
			address.ellipsizeWhenUnfocused = true;
			address.label = "Relay URL";
			address.placeholder = "https://exosuit-relay.joao-9f7.workers.dev";
			rows.push(new KeyedView("relay-label", paragraph("Relay URL", context)));
			rows.push(new KeyedView("relay-url", address));
			rows.push(new KeyedView("relay-hint", paragraph("Use the Exosuit relay, or enter your own HTTPS relay.", context, true)));
			var enable = new Button("Enable remote access", null, function() { client.configureRelay(relayOrigin); requestFrame(); }, "remote-access-enable");
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
					new KeyedView("permissions-hint", paragraph("All permissions are selected by default. Adjust access before approving.", context, true))
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
				var revoke = new Button("Revoke", null, function() {
					var id = device.deviceId;
					client.revokePairing(id, function(error) { actionError = error == null ? "Device revoked" : error; requestFrame(); });
					requestFrame();
				}, "pairing-revoke-" + device.deviceId);
				revoke.enabled = !client.pairingBusy();
				children.push(new KeyedView("revoke", revoke));
			}
			rows.push(new KeyedView("device:" + device.deviceId, new Column("paired-device-" + device.deviceId, children, sectionStyle())));
		}
		var failure = actionError == null ? client.pairingError() : actionError;
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
