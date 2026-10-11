package plugin;

import editor.Document;

/** Owner-scoped marker over an inclusive, zero-based logical line range. */
class PluginGutterMarker {
	public final owner:String;
	public final id:String;
	public final document:Document;
	public final startLine:Int;
	public final endLine:Int;
	public final kind:PluginGutterMarkerKind;

	public function new(owner:String, id:String, document:Document, startLine:Int, endLine:Int,
			kind:PluginGutterMarkerKind) {
		this.owner = owner;
		this.id = id;
		this.document = document;
		this.startLine = startLine;
		this.endLine = endLine;
		this.kind = kind;
	}
}
