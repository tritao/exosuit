package ui;

import sys.FileSystem;
import LayoutStyle;
import nativekit.ui.core.View;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.theme.Theme;
import nativekit.ui.widgets.collections.TreeRootMetadata;
import nativekit.ui.widgets.collections.TreeViewModel;
import nativekit.ui.widgets.text.Text;

/** Synchronous, on-demand directory listing for the explorer's `TreeView`. */
class DirectoryTreeModel implements TreeViewModel {
	final root:String;
	final theme:Theme;
	var listRevision:Int = 0;

	public function new(root:String, theme:Theme) {
		this.root = root;
		this.theme = theme;
	}

	public function rootCount():Int return 1;

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return start > 0 || count <= 0 ? [] : [new TreeRootMetadata(root, true)];

	public function rootKeyAt(index:Int):String return root;

	public function childCount(parentKey:String):Int
		return entries(parentKey).length;

	public function childKeyAt(parentKey:String, index:Int):String {
		var list = entries(parentKey);
		return index >= 0 && index < list.length ? parentKey + "/" + list[index] : "";
	}

	public function initiallyExpanded(key:String):Bool return key == root;

	public function estimatedExtent():Float return 24.0;

	public function extentIsUniform():Bool return true;

	public function extentAt(key:String):Float return 24.0;

	public function buildItem(key:String):View {
		var name = baseName(key), directory = safeIsDirectory(key);
		var style = new LayoutStyle();
		var label = (directory ? "> " : "  ") + name;
		return new Text(label, style, directory ? theme.tokens.text : theme.tokens.textSecondary,
			TextStyleOverride.text(13.0));
	}

	public function revision():Int return listRevision;

	/** Invalidates cached listings after a filesystem change made outside the tree. */
	public function invalidate():Void listRevision++;

	function entries(directory:String):Array<String> {
		if (!safeIsDirectory(directory)) return [];
		var names:Array<String>;
		try {
			names = FileSystem.readDirectory(directory);
		} catch (_:Dynamic) {
			return [];
		}
		var directories:Array<String> = [], files:Array<String> = [];
		for (name in names) {
			if (StringTools.startsWith(name, ".")) continue;
			if (safeIsDirectory(directory + "/" + name)) directories.push(name); else files.push(name);
		}
		directories.sort(Reflect.compare);
		files.sort(Reflect.compare);
		return directories.concat(files);
	}

	static function safeIsDirectory(path:String):Bool {
		try {
			return FileSystem.exists(path) && FileSystem.isDirectory(path);
		} catch (_:Dynamic) {
			return false;
		}
	}

	static function baseName(path:String):String {
		var slash = path.lastIndexOf("/");
		return slash < 0 ? path : path.substring(slash + 1);
	}
}
