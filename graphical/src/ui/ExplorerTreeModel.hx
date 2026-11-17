package ui;

import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeViewModel;
import plugin.PluginResourceDecorationRegistry;

/**
	Shared presentation contract for local and RPC-backed workspace trees.

	Every TreeViewModel method reads the model's change signal, so TreeView rebuilds its index when the listing changes.
	The signal is written on the UI thread only, outside builds; a change made during a build is published by
	`prepareBuild`.
**/
interface ExplorerTreeModel extends TreeViewModel {
	public function rootIdentity():String;
	/** Counts every change of the listing or of how rows look. A plain read: polls compare it before and after. */
	public function revision():Int;
	public function rootKeyAt(index:Int):String;
	/** UI thread, before each build: polls the decoration provider and publishes changes a build made. */
	public function prepareBuild():Void;
	public function watchesChanges():Bool;
	public function refresh():Void;
	/** Explicit user refresh; retain cached rows while replacing loaded listings. */
	public function refreshAll():Void;
	public function dispose():Void;
	public function setResourceDecorations(provider:Null<PluginResourceDecorationRegistry>):Void;
	public function buildItemWithIcons(key:String, expanded:Bool, atlas:SetiIconAtlas, dark:Bool):View;
}
