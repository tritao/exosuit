package platform;

/** Optional native resource chooser owned by the application's host. */
interface HostFileDialogs {
 public function openFile(handler:Bool->Array<String>->Void, ?title:String,
  ?initialPath:String, ?allowMultiple:Bool):haxe.Int64;
 public function selectDirectory(handler:Bool->Array<String>->Void, ?title:String,
  ?initialPath:String):haxe.Int64;
 public function shutdown():Void;
}
