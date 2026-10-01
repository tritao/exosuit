package plugin;

/** Desktop compiler/runtime adapter, excluded from the browser graph. */
class NativeSourcePluginLoader implements SourcePluginLoader {
 public function new() {}
 public function initialize():Void DynamicHostRouter.initialize();
 public function load(path:String):Plugin return new DynamicPlugin(new PluginManifest(path));
}
