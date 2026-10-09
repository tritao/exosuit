package ui;

/** Non-editable file tab; byte inspection never creates a text document. */
class UiUnsupportedFileTab extends view.View {
	public final id:String;
	public final file:workspace.UnsupportedTextFile;
	public var preview:Bool;
	public var showBytes:Bool = false;
	public function new(file:workspace.UnsupportedTextFile, preview:Bool) {
		super(haxe.io.Path.withoutDirectory(file.path));
		this.file = file;
		this.id = "unsupported-file:" + file.path;
		this.preview = preview;
	}
}
