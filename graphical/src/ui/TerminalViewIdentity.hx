package ui;
import haxe.crypto.Sha256;
import haxeon.wire.JsonWire;

@:wire typedef TerminalReference = {
  @:id(1) var resource:String;
}

/** View keys are workspace-scoped; service resource IDs remain opaque. */
class TerminalViewIdentity {
  public static function view(root:String,
    resource:String):String return "workspace-terminal-view-" + Sha256.encode(root.length + ":" + root + resource);
  public static function encode(resource:String):String {
    var reference:TerminalReference = {resource: resource};
    return JsonWire.encode(reference);
  }
  public static function decode(value:String):Null<String> {
    try {
      var reference:TerminalReference = JsonWire.decode(value);
      return reference.resource != null
        && reference.resource.length > 0 && reference.resource.length <= 128 ? reference.resource : null;
    } catch (_:Dynamic) {
      return null;
    }
  }
}
