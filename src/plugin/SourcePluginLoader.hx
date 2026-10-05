package plugin;

/** Host-owned source compilation; unavailable hosts supply no loader. */
interface SourcePluginLoader {
 public function initialize():Void;
 public function load(path:String):Plugin;
 public function shutdown():Void;
}
