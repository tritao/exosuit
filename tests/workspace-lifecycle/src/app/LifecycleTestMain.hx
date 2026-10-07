package app;
class LifecycleTestMain {
 static function require(value:Bool):Void { if (!value) throw "Update policy failed"; }
 static function main():Void {
  var policy = new workspace.service.WorkspaceUpdatePolicy();
  require(!policy.shouldRestart(0, 0));
  require(policy.request("idle"));
  require(!policy.shouldRestart(1, 0));
  require(!policy.shouldRestart(0, 1));
  require(policy.shouldRestart(0, 0));
  require(policy.request("cancel") && !policy.shouldRestart(0, 0));
  require(!policy.request("invalid"));
  require(policy.request("now") && policy.shouldRestart(1, 1));
  var method = workspace.service.WorkspaceLifecycleProtocol.STATUS;
  require(method.encodeRequest({}).length > 0);
  Sys.println("PASS: daemon update activity policy");
 }
}
