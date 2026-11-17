package ui;


import haxeon.ui.widgets.overlays.MenuItem;

import haxeon.ui.Path;

import haxeon.ui.Rect;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutStyle;
import sys.FileSystem;
import sys.io.File;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

/**
	The Files view: its tree of the window's folders (local, or through a workspace's service), its header actions and
	menus, creating and renaming entries. ExosuitApp owns one.
**/
@:allow(ui)
class ExplorerPanelController {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	function explorerHeaderActions():View {
		var remote = app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess();
		var available = app.explorerRoot != null;
		var style = new LayoutStyle();
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 2;
		style.padding = new Insets(2, 0, 6, 0);
		return new Row("explorer-header-actions", [
			new KeyedView("scope", explorerHeaderButton("Files scope and workspace", IconName.ChevronDown, app.showFilesScope, true, false,
				function(event) app.workbenchActions.showWorkbenchMenu(filesMenuItems(), event, function() return true))),
			new KeyedView("new-file", explorerHeaderButton("New File", IconName.NewFile,
				function() createExplorerEntry(false), available && !remote, remote)),
			new KeyedView("new-folder", explorerHeaderButton("New Folder", IconName.NewFolder,
				function() createExplorerEntry(true), available && !remote, remote)),
			new KeyedView("refresh", explorerHeaderButton("Refresh", IconName.Reset, function() {
				if (app.explorerModel != null) app.explorerModel.refreshAll();
				app.requestFrame();
			}, available)),
			new KeyedView("collapse", explorerHeaderButton("Collapse All", IconName.CollapseAll, function() {
				if (app.explorerTree != null) app.explorerTree.collapseAll(true);
				app.requestFrame();
			}, available))
		], style);
	}
	function explorerHeaderButton(label:String, icon:IconName, action:Void->Void, enabled:Bool, readOnly:Bool = false,
			?onEvent:UiEvent->Void):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(24);
		style.height = LayoutAxis.fixed(24);
		style.padding = new Insets(4, 4, 4, 4);
		style.childDistribution = haxeon.ui.LayoutDistribution.Center;
		style.childAlignY = LayoutAlignmentY.Center;
		var button = new Button("", style, action, "explorer-action:" + label, enabled, ButtonVariant.Navigation, null, null,
			icon, null, null, null, null, null, 16, label, onEvent);
		return new TabTooltip("explorer-action-tooltip:" + label, button,
			new Text(readOnly ? label + " (remote files are read-only)" : label),
			function() return new Rect(0, 0, app.viewportWidth, app.viewportHeight), app.application.settings.current.tabTooltipDelay);
	}
	/** Files header menu: the scope picker and the window's workspace actions (desktop only). */
	function filesMenuItems():Array<MenuItem> {
		var items:Array<MenuItem> = [new MenuItem("files-scope", "Files Scope…", app.showFilesScope)];
		for (item in [app.commandMenuItem("workspace:add-folder", "Add Folder to Workspace…", true),
				app.commandMenuItem("workspace:remove-folder", "Remove Folder from Workspace…"),
				app.commandMenuItem("workspace:close", "Close Workspace")])
			if (item != null) items.push(item);
		return items;
	}
	/** A workspace root row: folder creation plus workspace membership for that root, with no picker. */
	function workspaceRootMenuItems(root:String):Array<MenuItem> {
		var items:Array<MenuItem> = [];
		var available = controller.SavedWorkspaceController.available(root);
		for (item in [app.commandMenuItem("file:new", "New File…", false, available), app.commandMenuItem("folder:new", "New Folder…", false, available),
				app.commandMenuItem("workspace:add-folder", "Add Folder to Workspace…", true)])
			if (item != null) items.push(item);
		items.push(new MenuItem("workspace-remove-root", "Remove Folder from Workspace",
			function() app.application.savedWorkspaces.removeFolder(root), app.application.savedWorkspaces.hasRoot(root)));
		var close = app.commandMenuItem("workspace:close", "Close Workspace");
		if (close != null) items.push(close);
		return items;
	}
	/** Remote Files are read-only and owned by the workspace service: only view actions are offered. */
	function remoteExplorerMenuItems():Array<MenuItem> {
		return [
			new MenuItem("files-refresh", "Refresh", function() { if (app.explorerModel != null) app.explorerModel.refreshAll(); }),
			new MenuItem("files-collapse", "Collapse All", function() { if (app.explorerTree != null) app.explorerTree.collapseAll(true); })
		];
	}
	function createExplorerEntry(folder:Bool):Void {
		if (app.explorerRoot == null || (app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess())) return;
		var base = app.explorerRoot;
		var selected = app.explorerTree == null ? null : app.explorerTree.selectedKey;
		var model:Null<DirectoryTreeModel> = Std.isOfType(app.explorerModel, DirectoryTreeModel) ? cast app.explorerModel : null;
		if (selected != null && model != null && !model.isSyntheticRow(selected))
			base = model.isDirectoryPath(selected) ? selected : haxe.io.Path.directory(selected);
		var refresh = function() {
			if (model != null) model.refreshDirectory(base);
			app.requestFrame();
		};
		if (folder) app.application.files.openCreateFolder(base, refresh);
		else app.application.files.openCreateFile(base, refresh);
	}
	function beginExplorerRename(path:String, rename:String->Bool):Bool {
		if (!app.sidebar.visible || app.sidebar.activeId != "files") return false;
		var tree = app.explorerTree;
		var model:Null<DirectoryTreeModel> = Std.isOfType(app.explorerModel, DirectoryTreeModel) ? cast app.explorerModel : null;
		if (tree == null || model == null || tree.selectedKey != path || model.isSyntheticRow(path)) return false;
		if (app.application.savedWorkspaces.roots().indexOf(path) >= 0) { app.application.reportError("files", "Project roots cannot be renamed while open."); return true; }
		app.host.closeCommandView();
		tree.scrollIntoView(path);
		app.host.focusExplorer();
		app.explorerRename = new ExplorerRename(path, model.isDirectoryPath(path), rename, function(destination) {
			if (app.explorerRename == null || app.explorerRename.path != path) return;
			app.explorerRename = null;
			if (destination != null) {
				app.renamedExplorerPath = destination;
				app.host.setSelectedExplorerPath(destination);
				model.refreshDirectory(haxe.io.Path.directory(path));
			}
			app.requestFrame();
		}, app.requestFrame, function(message) app.application.reportError("files", message), app.application.settings.current.explorerFontSize);
		app.requestFrame();
		return true;
	}
	function localExplorerRoots():Array<String> {
		var roots = app.filesUseWorkspaceRoots ? app.application.savedWorkspaces.roots() : app.application.activeContext.roots;
		if (app.filesUseWorkspaceRoots) return roots;
		return roots.length == 0 && app.explorerRoot != null ? [app.explorerRoot] : roots;
	}
	function explorerPanel():View {
		if (app.explorerRoot == null) {
			var open = new Button("Open", null, app.openFolderDialog, "explorer-open-folder", null, ButtonVariant.Secondary, null, null,
				IconName.FolderOpen);
			var compact = new LayoutStyle();
			compact.width = LayoutAxis.grow();
			compact.padding = new Insets(4.0, 8.0, 4.0, 8.0);
			return new Column("explorer-empty", [new KeyedView("open", open)], compact);
		}
		var attachment = app.workspaceAttachment;
		var remoteFiles = attachment != null && !attachment.hasLocalFileAccess();
		var remoteScope:String = app.explorerRoot;
		var remoteWorkspace = attachment == null ? "" : attachment.fileWorkspace();
		if (attachment != null && attachment.fileScope() != null) remoteScope = attachment.fileScope();
		var remoteModelCurrent = app.explorerModel != null && Std.isOfType(app.explorerModel, WorkspaceFileTreeModel)
			&& (cast(app.explorerModel, WorkspaceFileTreeModel)).scopeId() == remoteScope
			&& (cast(app.explorerModel, WorkspaceFileTreeModel)).workspaceId() == remoteWorkspace;
		var localModelCurrent = app.explorerModel != null && Std.isOfType(app.explorerModel, DirectoryTreeModel)
			&& app.explorerModel.rootIdentity() == localExplorerRoots().join("\n");
		if (remoteFiles ? !remoteModelCurrent : !localModelCurrent) {
			app.clearExplorerModel();
			if (remoteFiles) {
				var rootName = remoteScope;
				var slash = rootName.lastIndexOf("/");
				if (slash >= 0 && slash + 1 < rootName.length) rootName = rootName.substring(slash + 1);
				app.explorerModel = new WorkspaceFileTreeModel(function()
					return app.workspaceAttachment == null ? null : app.workspaceAttachment.fileClient(),
					remoteWorkspace, remoteScope, rootName, app.theme, app.requestFrame,
					function(root) { app.workspaceFileLoader.clearCache(); app.host.markWorkspaceFilesChanged(remoteScope, root); },
					attachment == null || attachment.hasLocalFileAccess() ? null : attachment.sourceControlSource());
			} else app.explorerModel = new DirectoryTreeModel(app.explorerRoot, app.theme, localExplorerRoots());
		}
		if (app.explorerModel != null) app.explorerModel.setResourceDecorations(app.host.getResourceDecorations());
		var remoteModel:Null<WorkspaceFileTreeModel> = Std.isOfType(app.explorerModel, WorkspaceFileTreeModel)
			? cast app.explorerModel : null;
		var localModel:Null<DirectoryTreeModel> = Std.isOfType(app.explorerModel, DirectoryTreeModel)
			? cast app.explorerModel : null;
		if (remoteModel != null) remoteModel.fontSize = app.application.settings.current.explorerFontSize;
		if (localModel != null) localModel.fontSize = app.application.settings.current.explorerFontSize;
		if (app.explorerTree != null) {
			return new ExplorerTreeView(app.explorerTree, app.explorerModel, app.darkPalette, app.hostContext == null ? null : app.hostContext.events, app.explorerRename,
			app.host.focusExplorer, function(command) app.application.commands.perform(command, app.application.context));
		}
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.grow();
		viewportStyle.height = LayoutAxis.grow();
		viewportStyle.clipHorizontal = true;
		var tree = new TreeView("exosuit-explorer-tree", app.explorerModel, viewportStyle, app.filesScroll, 640.0,
			null, [for (index in 0...app.explorerModel.rootCount()) app.explorerModel.rootKeyAt(index)], function(key) {
				if (localModel == null || !localModel.isSyntheticRow(key)) app.host.setSelectedExplorerPath(key);
			}, function(key) {
				if (remoteModel != null) {
					if (remoteModel.isMoreKey(key) || remoteModel.isRetryKey(key)) remoteModel.activateSpecial(key);
					else if (!remoteModel.isDirectoryKey(key)) app.remoteFileTabs.openWorkspaceFile(remoteModel, key, true);
				} else if (localModel != null && !localModel.isSyntheticRow(key) && !localModel.isDirectoryPath(key)) app.application.openInBackground(key);
			}, null, null);
		tree.indentWidth = 10.0;
		tree.verticalGuidesOnly = true;
		tree.guidesOnInteraction = true;
		tree.compactLeafIndent = true;
		tree.expandOnSingleClick = true;
		if (remoteModel != null) {
			tree.hasChildrenHint = function(key) return remoteModel.isDirectoryKey(key);
			// After the tree's build, where expanding and selecting may write the tree's state.
			tree.onStateReady = function(current) app.remoteFileTabs.advanceWorkspaceFolderReveal(current, remoteModel);
		}
		if (localModel != null) {
			tree.onStateReady = function(current) {
				var path = app.renamedExplorerPath;
				if (path == null) return;
				var parent = haxe.io.Path.directory(path);
				for (index in 0...localModel.childCount(parent)) if (localModel.childKeyAt(parent, index) == path) {
					current.select(path);
					current.scrollIntoView(path);
					app.renamedExplorerPath = null;
					break;
				}
			};
			tree.hasChildrenHint = function(key) return localModel.hasChildrenHint(key);
			tree.onExpansionRequested = function(path, expanded, toggle) {
				var allowed = localModel.requestExpansion(path, expanded, toggle);
				app.requestFrame();
				return allowed;
			};
			tree.onCollapseAll = localModel.cancelRequestedExpansions;
			tree.onExpandedChanged = function(path, expanded) {
				localModel.setDirectoryExpanded(path, expanded);
				app.requestFrame();
			};
		}
		tree.onItemClicked = function(path, count) {
			if (remoteModel != null) {
				if (remoteModel.isMoreKey(path) || remoteModel.isRetryKey(path)) {
					if (count == 1) remoteModel.activateSpecial(path);
					return;
				}
				if (count == 1 && !remoteModel.isDirectoryKey(path)) app.remoteFileTabs.openWorkspaceFile(remoteModel, path, false);
				return;
			}
			if (localModel != null && localModel.isSyntheticRow(path)) {
				if (count == 1 && localModel.activateSyntheticRow(path)) app.requestFrame();
				return;
			}
			if (count != 1 || (localModel != null && localModel.isDirectoryPath(path))) return;
			try {
				app.application.openInBackground(path, true, false);
			} catch (error:Dynamic) app.application.reportError("files", "Could not open file: " + Std.string(error));
		};
		if (localModel != null) tree.onItemRename = function(path) {
			if (app.explorerRename != null || localModel.isSyntheticRow(path)) return;
			tree.select(path);
			app.host.setSelectedExplorerPath(path);
			app.application.files.openRenameFile();
		};
		tree.onItemContextMenu = function(path, event) {
			if (remoteModel != null) {
				if (path == remoteModel.rootKeyAt(0))
					app.workbenchActions.showWorkbenchMenu(remoteExplorerMenuItems(), event, function() return app.explorerModel == remoteModel);
				return;
			}
			if (localModel != null && localModel.isSyntheticRow(path)) return;
			var menuRoot = app.explorerRoot;
			app.host.setSelectedExplorerPath(path);
			if (app.application.savedWorkspaces.hasRoot(path)) {
				app.workbenchActions.showWorkbenchMenu(workspaceRootMenuItems(path), event,
					function() return app.explorerRoot == menuRoot && app.application.savedWorkspaces.hasRoot(path));
				return;
			}
			app.showContextMenu([
				new CommandMenuEntry("file:new", "New File…"),
				new CommandMenuEntry("folder:new", "New Folder…"),
				new CommandMenuEntry("file:rename", "Rename…"),
				new CommandMenuEntry("file:delete", "Delete…"),
				new CommandMenuEntry("workspace:remove-folder", "Remove Folder from Workspace…")
			], event, function() return app.explorerRoot == menuRoot && app.host.focusedFilePath() == path && FileSystem.exists(path));
		};
		app.explorerTree = tree;
		return new ExplorerTreeView(tree, app.explorerModel, app.darkPalette, app.hostContext == null ? null : app.hostContext.events, app.explorerRename,
			app.host.focusExplorer, function(command) app.application.commands.perform(command, app.application.context));
	}
}
