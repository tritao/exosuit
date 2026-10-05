package ui;

import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.RetainedView;
import nativekit.ui.core.View;
import nativekit.ui.widgets.collections.TreeView;

/** Owns the icon font for the lifetime of the mounted explorer tree. */
class ExplorerTreeView implements View {
	final tree:TreeView;
	final model:DirectoryTreeModel;
	final dark:Bool;
	final events:Null<NativeKitEvents>;

	public function new(tree:TreeView, model:DirectoryTreeModel, dark:Bool, ?events:NativeKitEvents) {
		this.tree = tree;
		this.model = model;
		this.dark = dark;
		this.events = events;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("explorer-icons"), function() {
			if (events != null) context.resourceState(context.id("directory-watch:" + model.rootKeyAt(0)),
				function() return new ExplorerDirectoryWatch(model, events), function(value) value.dispose());
			var atlas = context.resourceState(context.id("seti-atlas"), function() return new SetiIconAtlas(),
				function(value) value.dispose()).value;
			tree.itemBuilder = function(key, expanded) return model.buildItemWithIcons(key, expanded, atlas, dark);
			return new RetainedView("explorer-tree", function(_) return tree, function() {
				var scroll = tree.controller;
				return model.rootKeyAt(0) + ":" + model.revision() + ":" + dark + ":" +
					scroll.offsetX + ":" + scroll.offsetY + ":" + scroll.viewportWidth + ":" + scroll.viewportHeight +
					":" + context.animations.revision;
			}).build(context);
		});
	}
}
