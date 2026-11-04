package app;

import workspace.client.WorkspacePairingClient;
import workspace.service.WorkspacePairingProtocol;
import haxeon.ui.core.RenderNode;

private class PairingFixture implements WorkspacePairingClient {
 public var connected = true;
 public var status:RemoteAccessStatus = {configured:false, connected:false, origin:null, error:null};
 public var list:PairingList = {pending:[], devices:[]};
 public var service:Null<workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus>;
 public var updateAvailable = false;
 public var updateMode = "";
 public function new() {}
 public function serviceStatus():Null<workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus> return service;
 public function serviceUpdateAvailable():Bool return updateAvailable;
 public function serviceUpdateBusy():Bool return false;
 public function serviceUpdateError():Null<String> return null;
 public function requestServiceUpdate(mode:String):Void { updateMode = mode; }
 public function workspaceConnected():Bool return connected;
 public function remoteAccessStatus():Null<RemoteAccessStatus> return status;
 public function canConfigureRelay():Bool return connected;
 public function configureRelay(origin:String):Void {}
 public function canManagePairings():Bool return connected && status.connected;
 public function pairingList():Null<PairingList> return list;
 public function pairingRevision():Int return 0;
 public function pairingBusy():Bool return false;
 public function pairingError():Null<String> return null;
 public function refreshPairings(force:Bool):Void {}
 public function createPairing(ttl:Int, complete:PairingInvitation->Null<String>->Void):Void {}
 public function approvePairing(id:String, grants:Array<String>, complete:Null<String>->Void):Void {}
 public function setPairingGrants(id:String, grants:Array<String>, complete:Null<String>->Void):Void {}
 public function rejectPairing(id:String, complete:Null<String>->Void):Void {}
 public function revokePairing(id:String, complete:Null<String>->Void):Void {}
}

private class MachineFixture implements workspace.client.MachineRemoteAccess.MachineRemoteView {
 public var current:workspace.client.MachineRemoteAccess.MachineRemoteStatus = {enabled:true, connected:true, origin:"https://relay.example", error:null};
 public var list:workspace.client.MachineRemoteAccess.MachineRemoteDevices = {pending:[], devices:[], workspaces:[]};
 public var refreshes = 0;
 public var approved:Array<workspace.client.MachineRemoteAccess.MachineWorkspacePick> = [];
 public var granted:Array<workspace.client.MachineRemoteAccess.MachineWorkspacePick> = [];
 public var revoked:Null<String>;
 public function new() {}
 public function status():Null<workspace.client.MachineRemoteAccess.MachineRemoteStatus> return current;
 public function devices():Null<workspace.client.MachineRemoteAccess.MachineRemoteDevices> return list;
 public function busy():Bool return false;
 public function error():Null<String> return null;
 public function refresh(force:Bool):Void { refreshes++; }
 public var enabledWith:Null<String>;
 public var disables = 0;
 public function enable(origin:String, done:Null<String>->Void):Void { enabledWith = origin; done(null); }
 public function disable(done:Null<String>->Void):Void { disables++; current = {enabled:false, connected:false, origin:null, error:null}; done(null); }
 public function invite(ttlSeconds:Int, done:(Null<workspace.client.MachineRemoteAccess.MachineInvitation>, Null<String>) -> Void):Void {}
 public function approve(deviceId:String, picks:Array<workspace.client.MachineRemoteAccess.MachineWorkspacePick>, done:Null<String>->Void):Void { approved = picks; done(null); }
 public function grant(deviceId:String, picks:Array<workspace.client.MachineRemoteAccess.MachineWorkspacePick>, done:Null<String>->Void):Void { granted = picks; done(null); }
 public function reject(deviceId:String, done:Null<String>->Void):Void done(null);
 public function revoke(deviceId:String, done:Null<String>->Void):Void { revoked = deviceId; done(null); }
}

@:access(ui.RemoteAccessPanel)
class RemoteAccessPanelTestMain {
 static function require(value:Bool, message:String):Void { if (!value) throw message; }
 static function main():Int {
  try return check() catch (error:Dynamic) { Sys.println("FAIL: " + Std.string(error)); return 1; }
 }
 static function check():Int {
  var fixture = new PairingFixture(), panel = new ui.RemoteAccessPanel(fixture, function() {}, function(_) return false);
  var args = Sys.args();
  if (args.length == 2) {
   require(Sys.getEnv("PRAGTICAL_PORTABLE") != null, "Preview requires isolated PRAGTICAL_PORTABLE settings");
   if (args[0] == "update") {
    fixture.updateAvailable = true;
    fixture.service = {protocol:1, build:"previous", terminals:2, agents:1, updatePending:false};
   }
   if (args[0] == "approval") {
    fixture.status = {configured:true, connected:true, origin:"https://relay.example", error:null};
    fixture.list.pending = [{deviceId:"0123456789abcdef", authenticationCode:"123 456", expiresInSeconds:120}];
   }
   var options = new haxeon.ui.host.DesktopUiHostOptions();
   options.title = "Remote access preview"; options.width = 800; options.height = 840;
   options.frameLimit = 4; options.captureDirectory = args[1];
   var preview = haxeon.ui.host.DesktopUiHost.open(options, function(host) {
    var app = new ui.ExosuitApp(host.fonts, ui.ExosuitPalette.theme(false), host, null, null, null, false);
    app.attachRemoteAccess(fixture); app.showSidebarMode("remote-access");
    return app;
   });
   while (preview.tick()) {}
   return preview.close();
  }
  var fonts = haxeon.ui.FontCollection.create();
  fonts.add(Sys.getCwd() + "/../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var session = haxeon.ui.LayoutSession.create(), context = new haxeon.ui.core.UiContext(session, fonts, ui.ExosuitPalette.theme(false));
  var enabledApprovals = 0;
  var latestRoot:RenderNode = null;
  function labels():Array<String> {
   var root:RenderNode = null;
   for (_ in 0...3) root = context.submit(panel, new haxeon.ui.LayoutFrame(280, 500));
   latestRoot = root;
   var values:Array<String> = [];
   enabledApprovals = 0;
   root.walk(function(node) {
    if (node.semantics != null && node.semantics.label != null) {
     values.push(node.semantics.label);
     if (node.semantics.label == "Approve" && (node.states & haxeon.ui.style.StyleState.Disabled) == 0) enabledApprovals++;
    }
   });
   return values;
  }
  var idle = labels().join("\n");
  require(idle.indexOf("Local workspace connected · Remote access not configured") >= 0, "Connected local daemon was misreported");
  require(idle.indexOf("Enable remote access") >= 0 && idle.indexOf("Read project files") < 0 && idle.indexOf("Paired devices") < 0,
   "Setup must be visible and idle permission/device lists must be hidden");
  var relayField:RenderNode = null;
  var abbreviated = false;
  latestRoot.walk(function(node) {
   if (node.styleKey == "remote-relay-origin") relayField = node;
   if (node.layout.text != null && node.layout.text.indexOf("https://exosuit-relay") == 0 && node.layout.text.indexOf("…") >= 0) abbreviated = true;
  });
  require(relayField != null && relayField.resolved != null && relayField.resolved.width > 240,
   "Relay field did not fill the pane width");
  require(abbreviated, "Inactive long relay URL must end with an ellipsis");
  require(context.focusWidget(relayField.id), "Relay field cannot be focused");
  labels();
  var editableFullValue = false;
  latestRoot.walk(function(node) { if (node.layout.text == panel.relayOrigin) editableFullValue = true; });
  require(editableFullValue && panel.relayOrigin == "https://exosuit-relay.joao-9f7.workers.dev",
   "Focusing the relay field must restore the full URL without changing its value");
  fixture.status = {configured:true, connected:false, origin:"https://relay.example", error:"relay_unavailable"};
  var offline = labels().join("\n");
  require(offline.indexOf("Relay unavailable") >= 0 && offline.indexOf("relay_unavailable") >= 0 && offline.indexOf("Create pairing invitation") < 0,
   "Offline relay must show its failure and disable invitations");
  fixture.status.connected = true; fixture.status.error = null;
  require(labels().join("\n").indexOf("Create pairing invitation") >= 0, "Ready relay must offer invitations");
  fixture.list.pending = [{deviceId:"one", authenticationCode:"123 456", expiresInSeconds:60}, {deviceId:"two", authenticationCode:"789 012", expiresInSeconds:60}];
  require(labels().join("\n").indexOf("I checked both codes") >= 0, "Approval must require explicit code confirmation");
  require(enabledApprovals == 0, "Approval was enabled before code confirmation");
  panel.confirmed.set("one", true); labels();
  require(enabledApprovals == 1, "Code confirmation must enable only its own request");
		require(panel.grants("one").length == 10 && panel.grants("two").length == 10,
			"New devices must default to read-only grants, including source control review and workspace ordering");
		require(panel.grants("one").indexOf(workspace.service.WorkspaceProtocol.ORDER) >= 0, "Every grant set must include workspace.order");
		panel.setPreset("one", "read");
		require(panel.grants("one").length == 10 && panel.grants("two").length == 10, "Presets must not change another request");
		panel.setPreset("one", "edit"); require(panel.grants("one").length == 11, "Edit files preset grants excess access");
		panel.setPreset("one", "all"); require(panel.grants("one").length == 16, "All permissions preset incomplete");
		fixture.list.devices = [{deviceId:"paired", grants:[workspace.service.WorkspaceScmProtocol.READ], revoked:false, connected:true}];
		var pairedLabels = labels().join("\n");
		require(pairedLabels.indexOf("Edit permissions") >= 0, "Approved devices must expose grant editing");
		panel.editing.set("paired", true);
		pairedLabels = labels().join("\n");
		require(pairedLabels.indexOf("Save permissions") >= 0 && pairedLabels.indexOf("Fetch and push Git remotes") >= 0,
			"Approved device editing must show and save the full grant set");
  fixture.updateAvailable = true;
  var legacyUpdate = labels().join("\n");
  require(legacyUpdate.indexOf("Restart now…") >= 0 && legacyUpdate.indexOf("Update when idle") < 0,
   "Legacy updates must require explicit restart");
  panel.confirmRestart = true;
  var confirmation = labels().join("\n");
  require(confirmation.indexOf("Restarting ends active terminal and Codex sessions") >= 0
   && confirmation.indexOf("Restart workspace service") >= 0, "Destructive restart must explain session loss");
  panel.confirmRestart = false;
  fixture.service = {protocol:1, build:"old", terminals:2, agents:1, updatePending:false};
  require(labels().join("\n").indexOf("Update when idle") >= 0, "Managed daemon must offer safe scheduled update");
  fixture.service.updatePending = true;
  var scheduled = labels().join("\n");
  require(scheduled.indexOf("Cancel scheduled update") >= 0 && scheduled.indexOf("Waiting for terminal and Codex sessions") >= 0,
   "Pending updates must be visible and cancelable");
  fixture.connected = false;
  require(labels().join("\n").indexOf("Local workspace disconnected") >= 0, "Disconnected local daemon must be distinguished from relay failure");
  // Machine-level remote access: a device is granted workspaces, none by default.
  var machineFixture = new MachineFixture(), machinePanel = new ui.RemoteAccessPanel(new PairingFixture(), function() {}, function(_) return false);
  machinePanel.machine = machineFixture;
  machineFixture.list = {pending:[{deviceId:"phone", authenticationCode:"555 666", expiresInSeconds:90}],
   devices:[{deviceId:"tablet", connected:false, revoked:false, workspaces:[{workspace:"wa", grants:[], preset:"read"}]}],
   workspaces:[{id:"wa", name:"Alpha"}, {id:"wb", name:"Beta"}]};
  function machineLabels():String {
   var root:RenderNode = null;
   for (_ in 0...3) root = context.submit(machinePanel, new haxeon.ui.LayoutFrame(280, 700));
   var values:Array<String> = [];
   root.walk(function(node) { if (node.semantics != null && node.semantics.label != null) values.push(node.semantics.label); });
   return values.join("
");
  }
  var machineView = machineLabels();
  require(machineFixture.refreshes > 0, "The panel must ask the machine for its devices");
  require(machineView.indexOf("Remote access ready") >= 0 && machineView.indexOf("Workspaces this device may use") >= 0
   && machineView.indexOf("Access to Alpha") >= 0 && machineView.indexOf("Access to Beta") >= 0, "A pending device must list the machine workspaces to pick from");
  require(machineView.indexOf("Read project files") < 0, "Machine pairing picks workspaces and presets, not individual grants");
  require(machinePanel.pickList("phone", machineFixture.list.workspaces).length == 0, "A new device must get no workspace until one is picked");
  machinePanel.picksOf("phone", machineFixture.list.workspaces).set("wa", "read");
  var picked = machinePanel.pickList("phone", machineFixture.list.workspaces);
  require(picked.length == 1 && picked[0].workspace == "wa" && picked[0].preset == "read", "Picking Alpha must grant Alpha only");
  machineFixture.approve("phone", picked, function(_) {});
  require(machineFixture.approved.length == 1, "Approve must send the picks");
  require(machineView.indexOf("Alpha (read only)") >= 0 && machineView.indexOf("Edit workspaces") >= 0,
   "A paired device must list its workspaces and offer editing");
  machinePanel.editing.set("tablet", true);
  machinePanel.picksOf("tablet", machineFixture.list.workspaces).set("wb", "edit");
  var edited = machinePanel.pickList("tablet", machineFixture.list.workspaces);
  require(edited.length == 2 && edited[0].preset == "read" && edited[1].workspace == "wb" && edited[1].preset == "edit", "Editing must keep Alpha and add Beta");
  require(machineLabels().indexOf("Save workspaces") >= 0, "Editing must offer saving the workspaces");
  machineFixture.current = {enabled:false, connected:false, origin:null, error:null};
  require(machineLabels().indexOf("Enable remote access") >= 0, "A machine without a relay must offer enabling it");
  // The relay URL is a setting: shown from it, typed over it, saved when used, and switchable.
  machineFixture.list = {pending:[], devices:[], workspaces:[]};
  var saved = "";
  machineFixture.current = {enabled:false, connected:false, origin:null, error:null};
  var relayPanel = new ui.RemoteAccessPanel(new PairingFixture(), function() {}, function(_) return false);
  relayPanel.machine = machineFixture;
  relayPanel.relayUrlSetting = function() return saved;
  var savedValues:Array<String> = [];
  relayPanel.saveRelayUrl = function(origin) { savedValues.push(origin); saved = origin; };
  function relayText():String {
   var root:RenderNode = null;
   for (_ in 0...3) root = context.submit(relayPanel, new haxeon.ui.LayoutFrame(280, 700));
   var shown = "";
   root.walk(function(node) { if (node.styleKey == "remote-relay-origin") shown = node.layout.text; });
   return shown;
  }
  function press(label:String):Void {
   var root:RenderNode = null;
   for (_ in 0...3) root = context.submit(relayPanel, new haxeon.ui.LayoutFrame(280, 700));
   var target:Null<RenderNode> = null;
   root.walk(function(node) { if (target == null && node.semantics != null && node.semantics.label == label) target = node; });
   require(target != null, "No button labelled " + label);
   var dispatcher = new haxeon.ui.core.EventDispatcher(new haxeon.ui.core.FocusManager());
   dispatcher.setRoot(root);
   var hit = target; if (hit != null) dispatcher.targetEvent(haxeon.ui.core.UiEventKind.Activate, hit.id);
  }
  relayText();
  require(relayPanel.relayOrigin == config.RelayUrl.DEFAULT, "An empty setting shows the default relay");
  saved = "https://mine.example.workers.dev";
  relayText();
  require(relayPanel.relayOrigin == "https://mine.example.workers.dev", "A saved relay URL fills the field");
  relayPanel.relayOrigin = "ftp://nope"; relayPanel.relayEdited = true;
  press("Enable remote access");
  require(machineFixture.enabledWith == null && savedValues.length == 0 && relayPanel.actionError != null, "A bad relay URL is refused before anything is sent or saved");
  relayPanel.relayOrigin = "https://other.example.workers.dev/"; relayPanel.relayEdited = true;
  press("Enable remote access");
  require(machineFixture.enabledWith == "https://other.example.workers.dev" && savedValues.join(",") == "https://other.example.workers.dev",
   "Enabling sends the normalized relay and saves it");
  machineFixture.current = {enabled:true, connected:true, origin:"https://other.example.workers.dev", error:null};
  press("Use a different relay");
  require(machineFixture.disables == 0, "Switching relay needs a confirmation");
  press("Disconnect from this relay");
  require(machineFixture.disables == 1, "Confirming disconnects the machine from its relay");
  relayText();
  require(relayPanel.relayOrigin == "https://other.example.workers.dev", "After disconnecting, the field offers the saved relay again");
  context.dispose(); session.dispose(); fonts.dispose();
  Sys.println("PASS: remote access setup, relay failures, invitations, independent approval permissions and machine workspace grants");
  return 0;
 }
}
