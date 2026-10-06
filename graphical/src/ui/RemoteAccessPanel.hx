package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.controls.Checkbox;
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
	var selected:Map<String, Bool> = [];

	static final grantOptions:Array<{id:String, label:String, grant:String, defaultValue:Bool}> = [
		{id: "files", label: "Read project files", grant: WorkspaceProtocol.READ, defaultValue: true},
		{id: "events", label: "Receive workspace updates", grant: WorkspaceProtocol.EVENTS, defaultValue: true},
		{id: "edit", label: "Edit and save files", grant: WorkspaceProtocol.WRITE, defaultValue: false},
		{id: "tree", label: "Browse project folders", grant: WorkspaceProtocol.TREE, defaultValue: true},
		{id: "terminal-read", label: "Read terminal sessions", grant: WorkspaceTerminalProtocol.READ, defaultValue: false},
		{id: "terminal-catalog", label: "List terminal sessions", grant: WorkspaceTerminalProtocol.CATALOG, defaultValue: false},
		{id: "terminal-control", label: "Control terminal sessions", grant: WorkspaceTerminalProtocol.CONTROL, defaultValue: false},
		{id: "agent-read", label: "Read Codex sessions", grant: WorkspaceAgentProtocol.READ, defaultValue: false},
		{id: "agent-control", label: "Control Codex sessions", grant: WorkspaceAgentProtocol.CONTROL, defaultValue: false}
	];

	public function new(client:WorkspacePairingClient, requestFrame:Void->Void, copyText:String->Bool) {
		this.client = client;
		this.requestFrame = requestFrame;
		this.copyText = copyText;
		for (option in grantOptions) selected.set(option.id, option.defaultValue);
	}

	function grants():Array<String> {
		var result:Array<String> = [WorkspaceProtocol.IDENTITY_CAPABILITY];
		for (option in grantOptions) if (selected.get(option.id) == true) result.push(option.grant);
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

	function grantCheckboxes():Array<KeyedView> {
		var result:Array<KeyedView> = [];
		for (option in grantOptions) {
			var checkbox = new Checkbox("pairing-grant-" + option.id, option.label,
				selected.get(option.id) == true, function(value) {
					selected.set(option.id, value);
					requestFrame();
				});
			result.push(new KeyedView(option.id, checkbox));
		}
		return result;
	}

	public function build(context:BuildContext):RenderNode {
		var list = client.pairingList();
		var rows:Array<KeyedView> = [];
		var headerStyle = new LayoutStyle();
		headerStyle.padding = new Insets(12, 4, 4, 4);
		rows.push(new KeyedView("intro", new Text("Connect another device to this workspace. The relay forwards encrypted traffic; the workspace agent keeps your files and sessions on this machine.",
			headerStyle, context.theme.tokens.textSecondary)));
		var create = new Button(client.pairingBusy() ? "Creating invitation…" : "Create pairing invitation", null,
			createInvitation, "remote-access-create");
		create.variant = ButtonVariant.Primary;
		create.enabled = client.canManagePairings() && !client.pairingBusy();
		rows.push(new KeyedView("create", create));
		var currentInvitation = invitation;
		if (currentInvitation != null) {
			rows.push(new KeyedView("invitation-title", new Text("One-time invitation · expires in " + currentInvitation.expiresInSeconds + " seconds")));
			rows.push(new KeyedView("invitation-target", new Text("Device " + currentInvitation.deviceId.substr(0, 8) + " · one-time pairing URL")));
			rows.push(new KeyedView("invitation-warning", new Text("Treat this URL like a password. It only requests approval; access starts after you compare the code and approve permissions.",
				null, context.theme.tokens.textSecondary)));
			var copy = new Button("Copy one-time pairing URL", null, function() {
				if (copyText(currentInvitation.pairingSocketUrl)) actionError = "Could not copy the pairing address";
				else actionError = "Pairing address copied";
				requestFrame();
			}, "remote-access-copy");
			copy.enabled = copyText != null;
			rows.push(new KeyedView("copy", copy));
		}
		if (invitationError != null) rows.push(new KeyedView("invitation-error", new Text("Could not create invitation: " + invitationError)));
		rows.push(new KeyedView("permissions-title", new Text("Permissions offered for approval")));
		for (entry in grantCheckboxes()) rows.push(entry);
		rows.push(new KeyedView("pending-title", new Text("Requests waiting for approval")));
		if (list == null || list.pending.length == 0) {
			rows.push(new KeyedView("pending-empty", new Text(client.canManagePairings() ? "No device is waiting to pair." : "Workspace daemon is not connected.")));
		} else {
			for (pending in list.pending) {
				var approve = new Button("Approve", null, function() {
					var id = pending.deviceId;
					client.approvePairing(id, grants(), function(error) { actionError = error; requestFrame(); });
					requestFrame();
				}, "pairing-approve-" + pending.deviceId);
				approve.enabled = !client.pairingBusy();
				var reject = new Button("Reject", null, function() {
					var id = pending.deviceId;
					client.rejectPairing(id, function(error) { actionError = error; requestFrame(); });
					requestFrame();
				}, "pairing-reject-" + pending.deviceId);
				reject.enabled = !client.pairingBusy();
				var details = new Column("pairing-request-" + pending.deviceId, [
					new KeyedView("code", new Text("Compare this code on both devices: " + pending.authenticationCode)),
					new KeyedView("id", new Text("Device " + pending.deviceId.substr(0, 16) + " · expires in " + pending.expiresInSeconds + " seconds")),
					new KeyedView("actions", new Row("pairing-actions-" + pending.deviceId,
						[new KeyedView("approve", approve), new KeyedView("reject", reject)]))
				]);
				rows.push(new KeyedView("request:" + pending.deviceId, details));
			}
		}
		rows.push(new KeyedView("devices-title", new Text("Paired devices")));
		if (list != null) for (device in list.devices) {
			var children:Array<KeyedView> = [new KeyedView("details", new Text(deviceLabel(device)))];
			if (!device.revoked) {
				var revoke = new Button("Revoke", null, function() {
					var id = device.deviceId;
					client.revokePairing(id, function(error) { actionError = error == null ? "Device revoked" : error; requestFrame(); });
					requestFrame();
				}, "pairing-revoke-" + device.deviceId);
				revoke.enabled = !client.pairingBusy();
				children.push(new KeyedView("revoke", revoke));
			}
			rows.push(new KeyedView("device:" + device.deviceId, new Row("paired-device-" + device.deviceId, children)));
		}
		var failure = actionError == null ? client.pairingError() : actionError;
		if (failure != null) rows.push(new KeyedView("error", new Text(failure)));
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = 8;
		style.padding = new Insets(10, 6, 10, 6);
		var body = new Column("remote-access-content", rows, style);
		var viewport = new LayoutStyle();
		viewport.width = LayoutAxis.stretch();
		viewport.height = LayoutAxis.grow();
		return new ScrollView("remote-access-scroll", body, viewport).build(context);
	}
}
