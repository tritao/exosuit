package ui;

/** Immutable remote file contents displayed in a workbench preview tab. */
class UiWorkspaceFileTab {
	public final id:String;
	public final root:String;
	public final scope:String;
	public final rootName:String;
	public final path:String;
	public final revision:String;
	public final title:String;
	public final contents:String;
	public final sizeBytes:Int;
	public var preview:Bool;

	public function new(root:String, scope:String, rootName:String, path:String, revision:String,
			contents:String, sizeBytes:Int, preview:Bool) {
		this.root = root;
		this.scope = scope;
		this.rootName = rootName;
		this.path = path;
		this.revision = revision;
		this.contents = contents;
		this.sizeBytes = sizeBytes;
		this.preview = preview;
		var slash = path.lastIndexOf("/");
		this.title = slash < 0 ? path : path.substring(slash + 1);
		this.id = "workspace-file:" + scope + ":" + root + ":" + path;
	}
}
