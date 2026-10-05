package ui;

import haxe.crypto.Sha256;
import haxeon.wire.JsonWire;

@:wire typedef ResourceReference = {
	@:id(1) var resource:String;
	@:optional @:id(2) var workspaceRoot:Null<String>;
}

/** View keys are workspace-scoped; service resource IDs remain opaque. */
class ResourceViewIdentity {
	public static function view(root:String, resource:String, kind:String = "terminal"):String
		return "workspace-" + kind + "-view-" + Sha256.encode(root.length + ":" + root + resource);

	public static function encode(resource:String, ?workspaceRoot:String):String {
		var reference:ResourceReference = {resource: resource, workspaceRoot: workspaceRoot};
		return JsonWire.encode(reference);
	}

	public static function decode(value:String):Null<ResourceReference> {
		try {
			var reference:ResourceReference = JsonWire.decode(value);
			return reference.resource != null && reference.resource.length > 0 && reference.resource.length <= 128 ? reference : null;
		} catch (_:Dynamic) {
			return null;
		}
	}
}
