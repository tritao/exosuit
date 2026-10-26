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
	final onTreeFocus:Null<Void->Void>;
	final runCommand:Null<String->Void>;
	final rename:Null<ExplorerRename>;

	public function new(tree:TreeView, model:ExplorerTreeModel, dark:Bool, ?events:NativeKitEvents, ?rename:ExplorerRename,
		?onTreeFocus:Void->Void, ?runCommand:String->Void) {
		this.tree = tree;
		this.model = model;
		this.dark = dark;
		this.events = events;
		this.rename = rename;
		this.onTreeFocus = onTreeFocus;
		this.runCommand = runCommand;
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
			tree.itemBuilder = function(key, expanded) {
				if (rename == null || rename.path != key) return model.buildItemWithIcons(key, expanded, atlas, dark);
				var style = new haxeon.ui.LayoutStyle();
				style.width = haxeon.ui.LayoutAxis.grow();
				style.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
				style.childGap = 2;
				var children:Array<haxeon.ui.widgets.KeyedView> = [];
				if (!rename.directory) children.push(new haxeon.ui.widgets.KeyedView("icon",
					new SetiFileIcon(atlas, haxe.io.Path.withoutDirectory(key), dark, true)));
				children.push(new haxeon.ui.widgets.KeyedView("name", rename));
				return new haxeon.ui.widgets.layout.Row("explorer-rename-row", children, style);
			};
			return new RetainedView("explorer-tree", function(buildContext) return new ExplorerTreeInput(tree, onTreeFocus, runCommand), function() {
				var scroll = tree.controller;
				return model.rootIdentity() + ":" + model.revision() + ":" + dark + ":" +
					(rename == null ? "" : rename.path + ":" + rename.revision) + ":" +
					scroll.offsetX + ":" + scroll.offsetY + ":" + scroll.viewportWidth + ":" + scroll.viewportHeight +
					":" + context.animations.revision;
			}).build(context);
		});
	}
}
