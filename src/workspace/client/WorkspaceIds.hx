package workspace.client;

/** Opaque resource/operation IDs; never authentication credentials. */
class WorkspaceIds {
	static var sequence:Int = 0;

	public static function create(kind:String):String {
		sequence++;
		return kind + "-" + haxe.crypto.Sha256.encode(Sys.time() + ":" + Math.random() + ":" + sequence);
	}
}
