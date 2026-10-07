package ui;

import style.Theme;
import syntax.SyntaxRegistry;

/** Immutable remote file contents displayed in a workbench preview tab. */
class UiWorkspaceFileTab {
	public final id:String;
	public final workspace:String;
	public final root:String;
	public final scope:String;
	public final rootName:String;
	public final path:String;
	public final revision:String;
	public final title:String;
	public final textModel:WorkspaceFileTextModel;
	public final sizeBytes:Int;
	public var preview:Bool;
	public var refreshing:Bool = false;
	public var refreshError:Null<String>;
	public var diskChanged:Bool = false;

	public function new(workspace:String, root:String, scope:String, rootName:String, path:String, revision:String,
			contents:String, sizeBytes:Int, preview:Bool, syntaxes:SyntaxRegistry, editorTheme:Theme) {
		this.workspace = workspace;
		this.root = root;
		this.scope = scope;
		this.rootName = rootName;
		this.path = path;
		this.revision = revision;
		this.textModel = new WorkspaceFileTextModel(path, contents, syntaxes, editorTheme);
		this.sizeBytes = sizeBytes;
		this.preview = preview;
		var slash = path.lastIndexOf("/");
		this.title = slash < 0 ? path : path.substring(slash + 1);
		this.id = "workspace-file:" + scope + ":" + root + ":" + path;
	}
}
