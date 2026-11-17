package workspace.provider;

/** A chat provider the workspace service builds when it is first needed (`WorkspaceAgentService`). */
class AgentProviderFactory {
 public final kind:String;
 /** A provider built before the service (tests): the service takes it at once. */
 public final existing:Null<LocalAgentProvider>;
 final make:Void->LocalAgentProvider;

 public function new(kind:String, make:Void->LocalAgentProvider, ?existing:LocalAgentProvider) {
  this.kind = kind;
  this.make = make;
  this.existing = existing;
 }

 public function build():LocalAgentProvider {
  var provider = existing != null ? existing : make();
  if (provider.driverKind() != kind) throw "Agent provider " + kind + " built a " + provider.driverKind() + " provider";
  return provider;
 }

 /** Providers that are built already (tests). */
 public static function built(providers:Array<LocalAgentProvider>):Array<AgentProviderFactory>
  return [for (provider in providers) new AgentProviderFactory(provider.driverKind(), null, provider)];
}
