package app;

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
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.widgets.scroll.ScrollView;

/** Browser-side one-time pairing view. Workspace resources arrive after M16.1 connects. */
class BrowserRemoteAccessPanel implements View {
	final client:BrowserRemoteWorkspaceClient;
	final requestFrame:Void->Void;
	var pairingUrl:String = "";

	public function new(client:BrowserRemoteWorkspaceClient, requestFrame:Void->Void) {
		this.client = client;
		this.requestFrame = requestFrame;
	}

	public function build(context:BuildContext):RenderNode {
		var rows:Array<KeyedView> = [
			new KeyedView("heading", new Text("Connect to a workspace")),
			new KeyedView("description", new Text("On the desktop, open Remote Access, click Create pairing invitation, then Copy pairing URL. Paste that one-time WSS link here. The relay HTTPS address is for desktop setup only.",
				null, context.theme.tokens.textSecondary))
		];
		if (client.workspaceRoot != null) {
			rows.push(new KeyedView("root", new Text("Workspace: " + client.workspaceRoot)));
			rows.push(new KeyedView("grants-title", new Text("Granted permissions")));
			for (index in 0...client.grants.length)
				rows.push(new KeyedView("grant:" + index, new Text("• " + grantLabel(client.grants[index]))));
			if (!client.canReadFiles()) rows.push(new KeyedView("files-unavailable", new Text(
				"This device was not granted saved-file browsing. Ask the desktop owner to approve that permission and pair again.",
				null, context.theme.tokens.textSecondary)));
		} else if (client.authenticationCode != null) {
			rows.push(new KeyedView("code-instruction", new Text("Compare this code with the desktop before continuing.")));
			rows.push(new KeyedView("code", new Text(client.authenticationCode, null,
				context.theme.tokens.textPrimary, TextStyleOverride.text(28, TextWrap.None))));
			if (!client.codeConfirmed) {
				var confirm = new Button("I verified the code matches", null, client.confirmCode, "remote-pairing-confirm-code");
				confirm.variant = ButtonVariant.Primary;
				rows.push(new KeyedView("confirm", confirm));
			} else {
				rows.push(new KeyedView("confirmed", new Text("Code confirmed. Waiting for desktop approval and secure storage…")));
			}
		} else if (client.connecting) {
			rows.push(new KeyedView("saved-connection", new Text(client.status)));
		} else {
			if (client.savedDevices.length > 0) {
				rows.push(new KeyedView("saved-heading", new Text("Saved devices")));
				for (index in 0...client.savedDevices.length) {
					var device = client.savedDevices[index];
					var machineId = device.machineId, deviceId = device.deviceId, relayOrigin = device.relayOrigin;
					var shortMachine = machineId.substr(0, 8);
					var shortDevice = deviceId.substr(0, 8);
					rows.push(new KeyedView("saved-label:" + index,
						new Text("Machine " + shortMachine + " · device " + shortDevice)));
					var reconnect = new Button(relayOrigin == null ? "Pair again from desktop" : "Reconnect",
						null, function() {
							if (relayOrigin != null) client.beginSavedConnection(machineId, deviceId);
							requestFrame();
						}, "remote-saved-device:" + machineId + ":" + deviceId);
					reconnect.enabled = relayOrigin != null;
					rows.push(new KeyedView("saved-connect:" + index, reconnect));
				}
			}
			var address = new TextField("remote-pairing-url", pairingUrl, function(value) {
				pairingUrl = value;
				requestFrame();
			});
			address.label = "One-time pairing URL";
			address.placeholder = "wss://…/v1/machines/…/pair/…?secret=…";
			address.style.width = LayoutAxis.stretch();
			address.ellipsizeWhenUnfocused = true;
			rows.push(new KeyedView("url-label", new Text("One-time pairing URL")));
			rows.push(new KeyedView("url", address));
			var connect = new Button("Pair new device", null, function() {
				if (client.beginPairing(pairingUrl)) pairingUrl = "";
				requestFrame();
			}, "remote-pairing-connect");
			connect.variant = ButtonVariant.Primary;
			connect.enabled = pairingUrl.length > 0;
			rows.push(new KeyedView("connect", connect));
		}
		rows.push(new KeyedView("status", new Text(client.status)));
		if (client.error != null) rows.push(new KeyedView("error", new Text(client.error, null, context.theme.tokens.danger)));
		if (client.authenticationCode != null || client.workspaceRoot != null || client.connecting || client.error != null) {
			var disconnect = new Button("Disconnect", null, function() {
				client.disconnect();
				requestFrame();
			}, "remote-pairing-disconnect");
			rows.push(new KeyedView("disconnect", disconnect));
		}
		var contentStyle = new LayoutStyle();
		contentStyle.width = LayoutAxis.stretch();
		contentStyle.childGap = 10;
		contentStyle.padding = new Insets(12, 8, 12, 8);
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.stretch();
		viewportStyle.height = LayoutAxis.grow();
		return new ScrollView("browser-remote-access-scroll", new Column("browser-remote-access-content", rows, contentStyle), viewportStyle).build(context);
	}

	static function grantLabel(grant:String):String {
		if (grant == workspace.service.WorkspaceProtocol.READ) return "Read project files";
		if (grant == workspace.service.WorkspaceProtocol.EVENTS) return "Workspace updates";
		if (grant == workspace.service.WorkspaceProtocol.WRITE) return "Edit and save files";
		if (grant == workspace.service.WorkspaceProtocol.TREE) return "Browse project folders";
		if (grant == workspace.service.WorkspaceTerminalProtocol.READ) return "Read terminal output";
		if (grant == workspace.service.WorkspaceTerminalProtocol.CATALOG) return "List terminal sessions";
		if (grant == workspace.service.WorkspaceTerminalProtocol.CONTROL) return "Control terminal sessions";
		if (grant == workspace.service.WorkspaceAgentProtocol.READ) return "Read Codex sessions";
		if (grant == workspace.service.WorkspaceAgentProtocol.CONTROL) return "Control Codex sessions";
		if (grant == workspace.service.WorkspaceFileProtocol.READ) return "Browse and read saved workspace files";
		if (grant == workspace.service.WorkspaceProtocol.IDENTITY_CAPABILITY) return "Workspace identity";
		return grant;
	}
}
