package ui;

import haxeon.platform.NativeKitEvents;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeView;

/** Owns the icon font for the lifetime of the mounted explorer tree. */
class ExplorerTreeView implements View {
	final tree:TreeView;
	final model:ExplorerTreeModel;
	final dark:Bool;
	final events:Null<NativeKitEvents>;

	public function new(tree:TreeView, model:ExplorerTreeModel, dark:Bool, ?events:NativeKitEvents) {
		this.tree = tree;
		this.model = model;
		this.dark = dark;
		this.events = events;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("explorer-icons"), function() {
			if (events != null && Std.isOfType(model, DirectoryTreeModel)) {
				var localModel:DirectoryTreeModel = cast model;
				context.resourceState(context.id("directory-watch:" + model.rootIdentity()),
					function() return new ExplorerDirectoryWatch(localModel, events), function(value) value.dispose());
			}
			var atlas = context.resourceState(context.id("seti-atlas"), function() return new SetiIconAtlas(),
				function(value) value.dispose()).value;
			tree.itemBuilder = function(key, expanded) return model.buildItemWithIcons(key, expanded, atlas, dark);
			return new RetainedView("explorer-tree", function(_) return tree, function() {
				var scroll = tree.controller;
				return model.rootIdentity() + ":" + model.revision() + ":" + dark + ":" +
					scroll.offsetX + ":" + scroll.offsetY + ":" + scroll.viewportWidth + ":" + scroll.viewportHeight +
					":" + context.animations.revision;
			}).build(context);
		});
	}
}
