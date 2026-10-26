package platform;

/** Optional native resource chooser owned by the application's host. */
interface HostFileDialogs {
 public function openFile(handler:Bool->Array<String>->Void, ?title:String,
  ?initialPath:String, ?allowMultiple:Bool):haxe.Int64;
 public function saveFile(handler:Bool->Array<String>->Void, ?title:String,
  ?initialPath:String, ?suggestedName:String):haxe.Int64;
 public function selectDirectory(handler:Bool->Array<String>->Void, ?title:String,
  ?initialPath:String):haxe.Int64;
 public function confirmSaveChanges(filename:String, handler:String->Void):Void;
 /** Reports (confirmed, doNotAskAgain); suppression applies only after confirmation. */
 public function confirmMoveToTrash(path:String, handler:(Bool, Bool)->Void):Void;
 public function shutdown():Void;
}
