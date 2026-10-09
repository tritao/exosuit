package ui;

import style.Theme;
import syntax.SyntaxRegistry;
import haxeon.ui.widgets.text.TextSelection;

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
	public var searchSelection(default, null):Null<TextSelection>;
	public var loading:Bool = false;
	public var loadError:Null<String>;
	public var contentReadyMs:Float = 0;
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

	/** Set the initial editor selection from a search result's UTF-8 coordinates. */
	public function selectSearchMatch(line:Int, byteColumn:Int, byteLength:Int):Void {
		if (line < 0 || byteColumn < 0 || byteLength < 0) return;
		var document = textModel.document();
		if (line >= document.paragraphCount()) return;
		var paragraph = document.paragraphRangeAtIndex(line);
		var lineStart = document.utf8OffsetForCodepoint(paragraph.start);
		var lineEnd = document.utf8OffsetForCodepoint(paragraph.end);
		var byteStart = lineStart + byteColumn;
		var byteEnd = byteStart + byteLength;
		if (byteStart < lineStart || byteEnd < byteStart || byteEnd > lineEnd) return;
		try {
			searchSelection = new TextSelection(document.codepointOffsetForUtf8(byteStart),
				document.codepointOffsetForUtf8(byteEnd));
		} catch (_:Dynamic) {
			searchSelection = null;
		}
	}

	public function clearSearchSelection():Void searchSelection = null;

	public function dispose():Void textModel.dispose();
}
