package ui;





import sys.io.File;
import haxeon.ui.widgets.collections.TreeView;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;

/**
	Files of a workspace the window reaches through its service (a remote or linked workspace): opening one in a tab,
	from the Files tree or a search result, loading it, refreshing it when it changes, and revealing a folder. ExosuitApp
	owns one.
**/
@:allow(ui)
class RemoteFileTabs {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	function advanceWorkspaceFolderReveal(tree:TreeView, model:WorkspaceFileTreeModel):Void {
		var path = app.pendingWorkspaceFolderReveal;
		if (path == null || path.length == 0) return;
		var parts = path.split("/"), parentKey = model.rootKeyAt(0), currentPath = "";
		for (index in 0...parts.length) {
			if (parts[index].length == 0) { app.pendingWorkspaceFolderReveal = null; return; }
			currentPath = currentPath.length == 0 ? parts[index] : currentPath + "/" + parts[index];
			var key = model.keyForPath(currentPath), visible = false;
			try { tree.scrollTo(key); visible = true; } catch (_:Dynamic) {}
			if (!visible) {
				if (!tree.isExpanded(parentKey) && tree.setExpanded(parentKey, true)) app.requestFrame();
				return;
			}
			if (index + 1 < parts.length) {
				if (!tree.isExpanded(key)) {
					if (!tree.setExpanded(key, true)) { app.pendingWorkspaceFolderReveal = null; return; }
					app.requestFrame();
				}
				parentKey = key;
				return;
			}
			if (model.isDirectoryKey(key) && !tree.isExpanded(key) && tree.setExpanded(key, true))
				app.requestFrame();
			tree.select(key);
			tree.scrollTo(key);
			app.pendingWorkspaceFolderReveal = null;
			app.requestFrame();
			return;
		}
	}
	function openWorkspaceFile(model:WorkspaceFileTreeModel, key:String, sticky:Bool):Void {
		var path = model.relativePath(key), entry = model.entryForKey(key);
		if (path == null || path.length == 0 || entry == null) return;
		openWorkspaceFileSnapshot(app.workspaceAttachment, model.workspaceId(), model.scopeId(), model.rootId(),
			model.rootDisplayName(), path, entry.revision, WorkspaceFileReader.previewSize(entry.size), sticky, null, sticky);
	}
	function openWorkspaceSearchResult(match:FileSearchMatch):Void {
		if (match == null || match.path == null || match.path.length == 0) return;
		if (match.kind == "directory") {
			app.pendingWorkspaceFolderReveal = match.path;
			app.showSidebarMode("files");
			return;
		}
		if (match.kind != "file") return;
		var attachment = app.workspaceAttachment;
		var client = attachment == null ? null : attachment.fileClient();
		if (attachment == null || client == null) {
			app.application.reportError("search", "Workspace file service is not connected");
			return;
		}
		var scope = app.servedFolders.primaryScope(attachment);
		var root = match.root == null ? "root" : match.root;
		// A result under another of the workspace's folders is scoped to that folder.
		var matchFolder = app.remoteFileSearch.rootPath(match);
		if (root != "root" && matchFolder != null) scope = matchFolder;
		if (scope == null || scope.length == 0) scope = app.explorerRoot;
		if (scope == null || scope.length == 0) scope = attachment.fileWorkspace();
		if (app.host.activateWorkspaceFile(scope, root, match.path, false)) {
			var existing = app.host.workspaceFile(scope, root, match.path);
			if (existing != null && match.line >= 0) existing.selectSearchMatch(match.line, match.column, match.length);
			app.requestFrame();
			return;
		}
		var workspace = attachment.fileWorkspace();
		client.stat(workspace, root, match.path, function(stat) {
			if (app.workspaceAttachment != attachment) return;
			if (stat == null || stat.workspace != workspace || stat.root != root || stat.path != match.path
				|| stat.entry == null || stat.entry.kind != "file" || stat.entry.revision == null) {
				app.application.reportError("search", "Workspace search result is no longer a file");
				return;
			}
			var rootName = scope;
			var slash = rootName.lastIndexOf("/");
			if (slash >= 0 && slash + 1 < rootName.length) rootName = rootName.substring(slash + 1);
			openWorkspaceFileSnapshot(attachment, workspace, scope, root, rootName, match.path, match.revision,
				WorkspaceFileReader.previewSize(stat.entry.size), false, match);
		}, function(error) {
			if (app.workspaceAttachment == attachment)
				app.application.reportError("search", error == null ? "Could not open workspace search result" : error.message);
		});
	}
	function openWorkspaceFileSnapshot(attachment:Null<workspace.client.WorkspaceAttachment>, workspace:String,
			scope:String, root:String, rootName:String, path:String, revision:Null<String>, sizeBytes:Null<Int>,
			sticky:Bool, match:Null<FileSearchMatch>, focusEditor:Bool = true):Void {
		if (app.host.activateWorkspaceFile(scope, root, path, sticky, focusEditor)) {
			var existing = app.host.workspaceFile(scope, root, path);
			if (existing != null && existing.loading)
				app.workspaceFileLoader.prioritize(workspaceFileKey(workspace, scope, root, path));
			if (existing != null && match != null && match.line >= 0)
				existing.selectSearchMatch(match.line, match.column, match.length);
			app.requestFrame();
			return;
		}
		if (sizeBytes == null) {
			app.application.reportError("files", "File exceeds the 16 MiB preview limit");
			return;
		}
		if (!app.host.canOpenWorkspaceFile(scope, root, path, sizeBytes)) {
			app.application.reportError("files", "Workspace file preview memory limit reached; close another file first");
			return;
		}
		var file = new UiWorkspaceFileTab(workspace, root, scope, rootName, path, revision == null ? "" : revision,
			"", sizeBytes, !sticky, app.application.syntaxes, app.editorPalette);
		file.loading = true;
		app.host.openWorkspaceFile(file, !sticky, focusEditor);
		if (focusEditor) app.host.focusActiveEditor();
		app.requestFrame();
		loadWorkspaceFile(file, attachment, revision, match);
	}
	function loadWorkspaceFile(file:UiWorkspaceFileTab, attachment:Null<workspace.client.WorkspaceAttachment>,
			revision:Null<String>, match:Null<FileSearchMatch>):Void {
		file.loading = true;
		file.loadError = null;
		var started = Sys.time();
		var key = workspaceFileKey(file.workspace, file.scope, file.root, file.path);
		app.workspaceFileLoader.load(key, revision, function(complete, wanted) {
			var client = attachment == null ? null : attachment.fileClient();
			if (app.workspaceAttachment != attachment || client == null || attachment.fileWorkspace() != file.workspace ||
				!app.servedFolders.resolveFileRoot(attachment, file)) {
				complete({contents: null, revision: null, sizeBytes: 0, error: "Workspace file service is not connected"});
				return;
			}
			WorkspaceFileReader.read(client, file.workspace, file.root, file.path, revision, complete, wanted);
		}, function() return app.host.hasWorkspaceFile(file), function(result) {
			file.loading = false;
			if (app.workspaceAttachment != attachment) {
				file.loadError = "Workspace is disconnected. Reconnect and retry.";
			} else if (result.error != null || result.contents == null || result.revision == null) {
				file.loadError = result.error == null ? "Could not read workspace file" : result.error;
			} else if (!app.host.canOpenWorkspaceFile(file.scope, file.root, file.path, result.sizeBytes)) {
				file.loadError = "Workspace file preview memory limit reached; close another file first";
			} else {
				var updated = new UiWorkspaceFileTab(file.workspace, file.root, file.scope, file.rootName,
					file.path, result.revision, result.contents, result.sizeBytes, file.preview, app.application.syntaxes, app.editorPalette);
				updated.contentReadyMs = (Sys.time() - started) * 1000;
				if (match != null && match.line >= 0) updated.selectSearchMatch(match.line, match.column, match.length);
				// Replace in place: an older response must never activate its tab again.
				app.host.replaceWorkspaceFileSnapshot(file, updated);
			}
			app.requestFrame();
		});
	}
	function refreshWorkspaceFile(file:UiWorkspaceFileTab):Void {
		if (file == null || file.loading || file.refreshing || !app.host.hasWorkspaceFile(file)) return;
		if (file.loadError != null) {
			loadWorkspaceFile(file, app.workspaceAttachment, null, null);
			app.requestFrame();
			return;
		}
		var key = workspaceFileKey(file.workspace, file.scope, file.root, file.path);
		if (app.workspaceFileRefreshPending.exists(key)) return;
		if (workspaceFileReadCount() >= 2) {
			file.refreshError = "Two workspace file reads are already in progress";
			app.requestFrame();
			return;
		}
		var attachment = app.workspaceAttachment;
		var client = attachment == null ? null : attachment.fileClient();
		if (client == null || attachment.fileWorkspace() != file.workspace
			|| !app.servedFolders.resolveFileRoot(attachment, file)) {
			file.refreshError = "Workspace is disconnected; showing the last loaded snapshot";
			app.requestFrame();
			return;
		}
		file.refreshing = true;
		file.refreshError = null;
		app.workspaceFileRefreshPending.set(key, true);
		app.requestFrame();
		var fail = function(message:String):Void {
			app.workspaceFileRefreshPending.remove(key);
			app.workspaceFileLoader.pump();
			file.refreshing = false;
			if (app.host.hasWorkspaceFile(file)) file.refreshError = message;
			app.requestFrame();
		};
		client.stat(file.workspace, file.root, file.path, function(stat) {
			if (!app.host.hasWorkspaceFile(file)) { fail(""); return; }
			if (stat == null || stat.workspace != file.workspace || stat.root != file.root || stat.path != file.path
				|| stat.entry == null || stat.entry.kind != "file" || stat.entry.revision == null) {
				fail("Workspace returned invalid file metadata; showing the last loaded snapshot");
				return;
			}
			var sizeBytes = WorkspaceFileReader.previewSize(stat.entry.size);
			if (sizeBytes == null) {
				fail("File is larger than the 16 MiB preview limit; showing the last loaded snapshot");
				return;
			}
			if (!app.host.canOpenWorkspaceFile(file.scope, file.root, file.path, sizeBytes)) {
				fail("Workspace file preview memory limit reached; showing the last loaded snapshot");
				return;
			}
			WorkspaceFileReader.read(client, file.workspace, file.root, file.path, stat.entry.revision,
				function(result:WorkspaceFileReadResult) {
					if (result.error != null || result.contents == null || result.revision == null) {
						fail((result.error == null ? "Could not refresh file" : result.error) + "; showing the last loaded snapshot");
						return;
					}
					if (!app.host.canOpenWorkspaceFile(file.scope, file.root, file.path, result.sizeBytes)) {
						fail("Workspace file preview memory limit reached; showing the last loaded snapshot");
						return;
					}
					var updated = new UiWorkspaceFileTab(file.workspace, file.root, file.scope, file.rootName, file.path,
						result.revision, result.contents, result.sizeBytes, file.preview, app.application.syntaxes, app.editorPalette);
					app.workspaceFileRefreshPending.remove(key);
					app.workspaceFileLoader.clearCache();
					app.workspaceFileLoader.pump();
					file.refreshing = false;
					if (app.host.replaceWorkspaceFileSnapshot(file, updated)) app.requestFrame();
				});
		}, function(error) fail((error == null ? "Could not refresh file" : error.message) +
			"; showing the last loaded snapshot"));
	}
	function workspaceFileReadCount():Int {
		var count = app.workspaceFileLoader.active;
		for (_ in app.workspaceFileRefreshPending.keys()) count++;
		return count;
	}
	static function workspaceFileKey(workspace:String, scope:String, root:String, path:String):String
		return workspace.length + ":" + workspace + scope.length + ":" + scope + root.length + ":" + root + path;
}
