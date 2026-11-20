package ui.shell.phone;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.TextField;
import workspace.client.MachinesPanelSource;
import workspace.client.MachinesPanelSource.PairedMachineCard;
import workspace.service.MachineDirectoryProtocol;

/**
	The machines this device is paired with (docs/phone-ui/mockups/Machines.dc.html): a card per machine with its
	workspaces (tap: Sessions scoped to it), dead pairings as one line with Forget, and Pair a machine. Without paired
	machines (the desktop in phone form) the one card is this machine's.
**/
class MachinesScreen extends PhoneUi implements View {
	final host:PhoneHost;
	final remote:() -> Null<MachinesPanelSource>;
	var pairingOpen = false;
	var pairingUrl = "";

	public function new(host:PhoneHost, remote:() -> Null<MachinesPanelSource>) {
		this.host = host;
		this.remote = remote;
	}

	public function build(context:BuildContext):RenderNode {
		var cards:Array<KeyedView> = [];
		var devices = remote();
		if (devices == null) cards.push(PhoneUi.kv("this-machine", thisMachine()));
		else for (machine in devices.pairedMachines()) {
			var key = machine.machineId + ":" + machine.deviceId;
			cards.push(PhoneUi.kv("m:" + key, machine.refusal != null ? deadPairing(devices, machine, key) : machineCard(devices, machine, key)));
		}
		if (devices != null) cards.push(PhoneUi.kv("pair", pairing(devices, context)));
		var list = PhoneUi.column("machines-cards", cards, function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 16, 16, 16);
			s.childGap = 12;
		});
		var viewport = new LayoutStyle();
		viewport.width = LayoutAxis.stretch();
		viewport.height = LayoutAxis.grow();
		return PhoneChrome.screen("machines-screen", [
			PhoneUi.kv("heading", PhoneChrome.heading("Machines")),
			PhoneUi.kv("rule", PhoneUi.rule("rule")),
			PhoneUi.kv("scroll", new ScrollView("machines-scroll", list, viewport))
		]).build(context);
	}

	static function card(key:String, children:Array<KeyedView>):View
		return PhoneUi.column(key, children, function(s) {
			s.width = LayoutAxis.stretch();
			s.background = PhoneUi.SURFACE;
			PhoneUi.radius(s, 14);
			s.clipHorizontal = true;
			s.clipVertical = true;
		});

	static function cardHeader(key:String, name:String, online:Bool, state:String):View
		return PhoneUi.row(key, [
			PhoneUi.kv("dot", online ? PhoneUi.dot("dot", PhoneUi.ONLINE) : PhoneUi.dot("dot", PhoneUi.MUTED)),
			PhoneUi.kv("name", PhoneUi.text(PhoneUi.clip(name, 28), 17, PhoneUi.TEXT, true)),
			PhoneUi.kv("state", PhoneUi.text(state, 13, online ? PhoneUi.ONLINE_TEXT : PhoneUi.SECONDARY))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 14, 16, 14);
			s.childGap = 12;
		});

	function workspaceRow(key:String, name:String, detail:String, onTap:Void->Void):View {
		var line = PhoneUi.row("line", [
			PhoneUi.kv("icon", PhoneUi.icon("icon", IconName.FolderClosed, 20, PhoneUi.SECONDARY)),
			PhoneUi.kv("name", PhoneUi.text(PhoneUi.clip(name, 28), 16, PhoneUi.TEXT, true)),
			PhoneUi.kv("detail", PhoneUi.text(detail, 13, PhoneUi.SECONDARY)),
			PhoneUi.kv("chev", PhoneUi.icon("chev", IconName.ChevronRight, 16, PhoneUi.MUTED))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fit(56);
			s.padding = new Insets(16, 0, 16, 0);
			s.childGap = 12;
		});
		return PhoneUi.column(key, [PhoneUi.kv("rule", PhoneUi.rule("rule", PhoneUi.RULE_SOFT)), PhoneUi.kv("tap", PhoneUi.tappable("tap", line, onTap))], function(s) s.width = LayoutAxis.stretch());
	}

	function countDetail(workspace:String, running:Bool):String {
		var count = host.core().sessionCount(workspace);
		return (running ? "running" : "idle") + (count > 0 ? " · " + count : "");
	}

	function thisMachine():View {
		var core = host.core();
		var rows = [PhoneUi.kv("head", cardHeader("head", core.machineName(), core.machineOnline(), core.machineOnline() ? "online" : "offline"))];
		for (workspace in core.workspaces()) {
			var id = workspace.id;
			rows.push(PhoneUi.kv("w:" + id, workspaceRow("w", workspace.name, countDetail(id, core.workspaceRunning(id)), function() {
				host.scopeTo(id);
			})));
		}
		return card("card", rows);
	}

	function machineCard(devices:MachinesPanelSource, machine:PairedMachineCard, key:String):View {
		var online = machine.online;
		var rows = [PhoneUi.kv("head", cardHeader("head", machine.name, online, online ? "online" : "offline"))];
		var workspaces = machine.workspaces;
		if (workspaces != null) {
			var machineId = machine.machineId, deviceId = machine.deviceId;
			for (entry in workspaces) {
				var id = entry.workspace;
				rows.push(PhoneUi.kv("w:" + id, workspaceRow("w", entry.name, countDetail(id, entry.status == MachineDirectoryProtocol.RUNNING), function() {
					devices.openMachineWorkspace(machineId, deviceId, id);
					host.scopeTo(id);
				})));
			}
		} else if (!online) {
			var why = machine.error;
			rows.push(PhoneUi.kv("why", PhoneUi.column("why", [PhoneUi.kv("t", PhoneUi.text(why == null ? "Connecting…" : "Cannot reach the machine. Retrying.", 13, PhoneUi.SECONDARY))],
				function(s) s.padding = new Insets(16, 4, 16, 14))));
		}
		return card("card", rows);
	}

	function deadPairing(devices:MachinesPanelSource, machine:PairedMachineCard, key:String):View {
		var refusal = machine.refusal;
		var texts = PhoneUi.column("texts", [
			PhoneUi.kv("name", PhoneUi.text(PhoneUi.clip(machine.name, 28), 16, PhoneUi.TEXT, true)),
			PhoneUi.kv("why", PhoneUi.text(PhoneUi.clip(refusal == null ? "" : refusal, 40), 13, PhoneUi.DANGER, true))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.clipHorizontal = true;
		});
		var forget = new Button("Forget", null, function() {
			devices.forget(machine.machineId, machine.deviceId);
			host.refresh();
		}, "forget-" + key);
		return PhoneUi.row("dead", [PhoneUi.kv("ring", PhoneUi.dot("ring", PhoneUi.IDLE)), PhoneUi.kv("texts", texts), PhoneUi.kv("forget", forget)], function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 14, 16, 14);
			s.childGap = 12;
			s.background = PhoneUi.SURFACE;
			PhoneUi.radius(s, 14);
		});
	}

	/** "Pair a machine" and, once pressed, the invitation field, the code to compare and the status. */
	function pairing(devices:MachinesPanelSource, context:BuildContext):View {
		var pairingNow = devices.pairingActive();
		var code = devices.pairingCode();
		var keyChanged = devices.pairingMachineKeyChanged();
		var open = pairingOpen || pairingNow || code != null;
		var rows:Array<KeyedView> = [];
		if (!open) {
			rows.push(PhoneUi.kv("button", PhoneUi.tappable("pair-open", PhoneUi.tile("pair-tile", 52, 14, PhoneUi.CHIP, PhoneUi.text("Pair a machine", 16, PhoneUi.ACCENT)), function() {
				pairingOpen = true;
				host.refresh();
			})));
		} else {
			if (code != null) {
				rows.push(PhoneUi.kv("instruction", PhoneUi.text("Compare this code with the machine, then confirm.", 14, PhoneUi.SECONDARY)));
				rows.push(PhoneUi.kv("code", PhoneUi.text(code, 28, PhoneUi.TEXT)));
				if (keyChanged)
					rows.push(PhoneUi.kv("changed", PhoneUi.text("This machine has a different key than the one already paired. Continue only if you reset it yourself.", 13, PhoneUi.DANGER)));
				if (!devices.pairingCodeConfirmed())
					rows.push(PhoneUi.kv("confirm", new Button(keyChanged ? "The code matches: replace the old pairing" : "The code matches", null, function() {
						devices.confirmCode();
						host.refresh();
					}, "phone-pairing-confirm", true, ButtonVariant.Primary)));
			} else if (!pairingNow) {
				var address = new TextField("phone-pairing-url", pairingUrl, function(value) {
					pairingUrl = value;
					host.refresh();
				});
				address.label = "One-time pairing URL";
				address.placeholder = "wss://…/pair/…?secret=…";
				address.style.width = LayoutAxis.grow();
				address.ellipsizeWhenUnfocused = true;
				var paste = new Button("Paste", null, function() {
					try context.clipboard.readText(function(pasted) {
						var trimmed = StringTools.trim(pasted == null ? "" : pasted);
						if (trimmed.length > 0) pairingUrl = trimmed;
						host.refresh();
					}) catch (_:Dynamic) {}
				}, "phone-pairing-paste");
				var fieldRow = new Row("pairing-row", [PhoneUi.kv("field", address), PhoneUi.kv("paste", paste)], rowStyle());
				rows.push(PhoneUi.kv("label", PhoneUi.text("Pair this device with a machine", 14, PhoneUi.SECONDARY)));
				rows.push(PhoneUi.kv("url", fieldRow));
				rows.push(PhoneUi.kv("go", new Button("Pair", null, function() {
					if (devices.beginPairing(pairingUrl)) pairingUrl = "";
					host.refresh();
				}, "phone-pairing-start", pairingUrl.length > 0, ButtonVariant.Primary)));
			}
			if (pairingNow) rows.push(PhoneUi.kv("cancel", new Button("Cancel pairing", null, function() {
				devices.cancelPairing();
				pairingOpen = false;
				host.refresh();
			}, "phone-pairing-cancel")));
			var status = devices.panelStatus(), error = devices.panelError();
			if (status != "") rows.push(PhoneUi.kv("status", PhoneUi.text(status, 13, PhoneUi.SECONDARY)));
			if (error != null) rows.push(PhoneUi.kv("error", PhoneUi.text(error, 13, PhoneUi.DANGER)));
		}
		return PhoneUi.column("pairing", rows, function(s) {
			s.width = LayoutAxis.stretch();
			s.childGap = 8;
		});
	}

	static function rowStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = 8;
		style.childAlignY = LayoutAlignmentY.Center;
		return style;
	}
}
