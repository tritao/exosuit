package ui;

import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeViewModel;

/** Shared presentation contract for local and RPC-backed workspace trees. */
interface ExplorerTreeModel extends TreeViewModel {
	public function rootIdentity():String;
	public function watchesChanges():Bool;
	public function refresh():Void;
	public function dispose():Void;
	public function buildItemWithIcons(key:String, expanded:Bool, atlas:SetiIconAtlas, dark:Bool):View;
}
