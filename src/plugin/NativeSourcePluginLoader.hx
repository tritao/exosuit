package plugin;

/** Desktop compiler/runtime adapter, excluded from the browser graph. */
class NativeSourcePluginLoader implements SourcePluginLoader {
 var owners:Int = 0;
 public function new() {}
 public function initialize():Void {
  DynamicHostRouter.initialize();
  owners++;
 }
 public function shutdown():Void {
  if (owners == 0) return;
  owners--;
  DynamicHostRouter.shutdown();
 }
 public function load(path:String):Plugin return new DynamicPlugin(new PluginManifest(path));
}
