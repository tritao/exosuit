package plugin;

import editor.Document;

class PluginDecoration {
	public final owner:String;
	public final id:String;
	public final document:Document;
	public final line:Int;
	public final startColumn:Int;
	public final endColumn:Int;
	public final color:Int;
	public final kind:PluginDecorationKind;

	public function new(owner:String, id:String, document:Document, line:Int, startColumn:Int, endColumn:Int, color:Int, kind:PluginDecorationKind = Background) {
		this.owner = owner;
		this.id = id;
		this.document = document;
		this.line = line;
		this.startColumn = startColumn;
		this.endColumn = endColumn;
		this.color = color;
		this.kind = kind;
	}
}
