package testing.model;

import commandview.CommandInput;

/** Explicit test clipboard; the application receives its clipboard from the UI host. */
class ModelClipboard {
 static var value:String = "";
 public static function read():String return value;
 public static function write(text:String):Bool { value = text; return true; }
 public static function attach(input:CommandInput):Void {
  input.writeClipboard = write;
  input.readClipboard = function(handler) handler(value);
 }
}
