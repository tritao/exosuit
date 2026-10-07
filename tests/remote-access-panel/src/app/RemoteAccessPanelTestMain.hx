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
 public function rejectPairing(id:String, complete:Null<String>->Void):Void {}
 public function revokePairing(id:String, complete:Null<String>->Void):Void {}
}

@:access(ui.RemoteAccessPanel)
class RemoteAccessPanelTestMain {
 static function require(value:Bool, message:String):Void { if (!value) throw message; }
 static function main():Int {
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
  require(panel.grants("one").length == 11 && panel.grants("two").length == 11, "All permissions must default on per request");
  panel.setPreset("one", "read");
  require(panel.grants("one").length == 5 && panel.grants("two").length == 11, "Presets must not change another request");
  panel.setPreset("one", "edit"); require(panel.grants("one").length == 6, "Edit files preset grants excess access");
  panel.setPreset("one", "all"); require(panel.grants("one").length == 11, "All permissions preset incomplete");
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
  context.dispose(); session.dispose(); fonts.dispose();
  Sys.println("PASS: remote access setup, relay failures, invitations and independent approval permissions");
  return 0;
 }
}
