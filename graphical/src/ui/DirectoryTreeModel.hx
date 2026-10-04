package ui;

import sys.FileSystem;
import LayoutStyle;
import LayoutAxis;
import LayoutAlignmentY;
import TextWrap;
import nativekit.ui.widgets.Icon;
import nativekit.ui.icons.IconName;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.core.View;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.theme.Theme;
import nativekit.ui.widgets.collections.TreeRootMetadata;
import nativekit.ui.widgets.collections.TreeViewModel;
import nativekit.ui.widgets.text.MiddleEllipsisText;

/** Synchronous, on-demand directory listing for the explorer's `TreeView`. */
class DirectoryTreeModel implements TreeViewModel {
	static final EmptyEntries:Array<String> = [];
	final root:String;
	final theme:Theme;
	var listRevision:Int = 0;
	var listings:Map<String, Array<String>> = [];
	var directories:Map<String, Bool> = [];
	var directoryKindsChanged:Bool = false;

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

	public function estimatedExtent():Float return 26.0;

	public function extentIsUniform():Bool return true;

	public function extentAt(key:String):Float return 26.0;

	public function buildItem(key:String):View
		return new MiddleEllipsisText("filename", baseName(key), false, new TextStyleOverride(null, 14.0, null, TextWrap.None, null, null, null, theme.tokens.text));

	public function buildItemWithIcons(key:String, expanded:Bool, atlas:SetiIconAtlas, dark:Bool):View {
		var name = baseName(key), directory = isDirectory(key);
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(26.0);
		style.clipHorizontal = true;
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 6.0;
		var icon:View = directory
			? new Icon("folder-icon", expanded ? IconName.FolderOpen : IconName.FolderClosed, 20.0, theme.tokens.textSecondary)
			: new SetiFileIcon(atlas, name, dark);
		return new Row("explorer-item", [
			new KeyedView("icon", icon),
			new KeyedView("name", new MiddleEllipsisText("filename", name, false, new TextStyleOverride(null, 14.0, null, TextWrap.None, null, null, null, theme.tokens.text)))
		], style);
	}

	public function revision():Int return listRevision;

	/** Invalidates cached listings after a filesystem change made outside the tree. */
	public function invalidate():Void {
		listings.clear();
		directories.clear();
		listRevision++;
	}

	/** Scan each previously visited directory once, rather than once per child lookup. */
	public function refresh():Void {
		var changed = false;
		directoryKindsChanged = false;
		for (directory => previous in listings) {
			var next = readEntries(directory);
			var equal = next.length == previous.length;
			if (equal) for (index in 0...next.length) if (next[index] != previous[index]) equal = false;
			if (!equal) { listings.set(directory, next); changed = true; }
		}
		if (changed || directoryKindsChanged) listRevision++;
	}

	function isDirectory(path:String):Bool {
		if (!directories.exists(path)) directories.set(path, safeIsDirectory(path));
		return directories.get(path);
	}

	function entries(directory:String):Array<String> {
		if (!isDirectory(directory)) return EmptyEntries;
		var cached = listings.get(directory);
		if (cached != null) return cached;
		var names = readEntries(directory);
		listings.set(directory, names);
		return names;
	}

	function readEntries(directory:String):Array<String> {
		var folder = safeIsDirectory(directory);
		directories.set(directory, folder);
		if (!folder) return EmptyEntries;
		var names:Array<String>;
		try {
			names = FileSystem.readDirectory(directory);
		} catch (_:Dynamic) {
			return [];
		}
		var directories:Array<String> = [], files:Array<String> = [];
		for (name in names) {
			if (StringTools.startsWith(name, ".")) continue;
			var path = directory + "/" + name, folder = safeIsDirectory(path);
			if (this.directories.exists(path) && this.directories.get(path) != folder) directoryKindsChanged = true;
			this.directories.set(path, folder);
			if (folder) directories.push(name); else files.push(name);
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
