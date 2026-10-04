package ui;

import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import nativekit.ui.widgets.collections.TreeView;

/** Owns the icon font for the lifetime of the mounted explorer tree. */
class ExplorerTreeView implements View {
	final tree:TreeView;
	final model:DirectoryTreeModel;
	final dark:Bool;

	public function new(tree:TreeView, model:DirectoryTreeModel, dark:Bool) {
		this.tree = tree;
		this.model = model;
		this.dark = dark;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("explorer-icons"), function() {
			var atlas = context.resourceState(context.id("seti-atlas"), function() return new SetiIconAtlas(),
				function(value) value.dispose()).value;
			tree.itemBuilder = function(key, expanded) return model.buildItemWithIcons(key, expanded, atlas, dark);
			return tree.build(context);
		});
	}
}
