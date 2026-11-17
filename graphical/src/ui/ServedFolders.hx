package ui;





import workspace.PathKey;

/**
	The folders the window's workspace service serves: its root listing, keeping file tabs keyed to the right root, and
	asking the service to serve the workspace's folders when they differ. ExosuitApp owns one.
**/
@:allow(ui)
class ServedFolders {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	var reconciledClient:Null<workspace.client.WorkspaceFileClient>;
	var reconciledWorkspace:Null<String>;
	/** exohost's catalog revision when the last reconcile started: until it changes, a settled reconcile still holds. */
	var reconciledRevision = -1;
	var reconcilePending = false;
	var reconcileRetryAt = 0.0;
	var reconcileBackoff = 5.0;
	var reconcileReported:Null<String>;
	var servedRefreshAt = 0.0;
	var servedRefreshDelay = 1.5;
	var servedRefreshUntil = 0.0;
	var servedRefreshPending = false;
	var reconcileKey:Null<String>;
	/** The folders the open workspace's service serves, as last listed, and the client that listed them. */
	var servedRoots:Array<{id:String, path:String}> = [];
	var servedRootsClient:Null<workspace.client.WorkspaceFileClient>;
	/** The folder behind the root id `root`: the first attached folder that is still there, which can change on detach. */
	function primaryScope(attachment:Null<workspace.client.WorkspaceAttachment>):Null<String> {
		if (attachment == null) return null;
		if (servedRootsClient != null && servedRootsClient == attachment.fileClient())
			for (root in servedRoots) if (root.id == "root") return root.path;
		return attachment.fileScope();
	}
	/**
		Finds the root the service serves `file`'s folder under, by path rather than by the id the tab was opened with,
		and re-keys the tab if that id changed. False when the folder is known not to be attached. Without a listing
		the tab keeps its id, as long as `root` still means the scope it was opened with.
	**/
	function resolveFileRoot(attachment:Null<workspace.client.WorkspaceAttachment>, file:UiWorkspaceFileTab):Bool {
		if (attachment == null) return false;
		var client = attachment.fileClient();
		if (client != null && servedRootsClient == client && servedRoots.length > 0) {
			for (root in servedRoots) if (PathKey.same(root.path, file.scope)) {
				if (root.id != file.root) file.rekey(root.id);
				return true;
			}
			return false;
		}
		var scope = attachment.fileScope();
		return scope == null || file.root != "root" || scope == file.scope;
	}
	/** Shows a failure or a skipped-folders note once per distinct text, so a retry cannot repeat the toast. */
	function reportOnce(text:Null<String>):Void {
		if (text == null || text == reconcileReported) return;
		reconcileReported = text;
		app.application.reportError("workspace", text);
	}
	/**
		Records the folders `listed` as served. Editor tabs follow their folder by path: one whose folder is now served
		under another id (it became `root`) takes that id, and one whose folder was detached closes.
	**/
	function noteServedRoots(fileClient:workspace.client.WorkspaceFileClient, workspaceId:String,
			listed:Array<workspace.service.WorkspaceFileProtocol.FileRootDescriptor>):Void {
		var before = servedRootsClient == fileClient ? servedRoots : [];
		var now:Array<{id:String, path:String}> = [];
		for (root in listed) if (root.path != null) now.push({id: root.id, path: root.path});
		servedRoots = now;
		servedRootsClient = fileClient;
		app.host.reconcileWorkspaceFiles(workspaceId, function(scope) {
			for (root in now) if (PathKey.same(root.path, scope)) return root.id;
			for (root in before) if (PathKey.same(root.path, scope)) return null;
			return "";
		});
	}
	/** The machine catalog's entry for the open workspace, when there is one. */
	function catalogEntry():Null<exohost.MachineCatalog.MachineWorkspace> {
		var machine = app.machineClient, current = app.application.savedWorkspaces.current;
		var state = machine == null ? null : machine.machine;
		if (current == null || state == null) return null;
		for (candidate in state.workspaces) if (candidate.id == current.id) return candidate;
		return null;
	}
	/** Asks the service which folders it serves now; `done` is told whether they are the catalog's usable folders. */
	function refreshServedRoots(attached:workspace.client.WorkspaceAttachment, ?done:Bool->Void):Void {
		var fileClient = attached.fileClient();
		if (fileClient == null) { if (done != null) done(false); return; }
		var workspaceId = attached.fileWorkspace();
		fileClient.roots(workspaceId, function(listed) {
			var ok = listed != null && listed.roots != null && attached.fileClient() == fileClient;
			if (ok) noteServedRoots(fileClient, workspaceId, listed.roots);
			var entry = catalogEntry();
			var matches = ok && (entry == null || servedMatchesCatalog(entry));
			if (done != null) done(matches);
		}, function(_) { if (done != null) done(false); });
	}
	/** Whether the folders last listed are the usable ones of the catalog entry. */
	function servedMatchesCatalog(entry:exohost.MachineCatalog.MachineWorkspace):Bool {
		var served = [for (root in servedRoots) root.path];
		return !workspace.client.FolderReconcile.differs(served, workspace.WorkspaceFolders.select(entry.folders).folders, entry.scratch);
	}
	/**
		After the catalog changes (here or in another window) the service follows a moment later, from whichever window
		made the change. Lists the served folders again, with a growing delay, until they are the catalog's or two
		minutes have passed, so the cached `root` cannot stay stale.
	**/
	function pollServedRoots(attached:workspace.client.WorkspaceAttachment):Void {
		if (servedRefreshAt <= 0 || servedRefreshPending || Sys.time() < servedRefreshAt) return;
		servedRefreshPending = true;
		refreshServedRoots(attached, function(matches) {
			servedRefreshPending = false;
			var now = Sys.time();
			if (matches || now > servedRefreshUntil) { servedRefreshAt = 0; return; }
			servedRefreshAt = now + servedRefreshDelay;
			servedRefreshDelay = Math.min(30.0, servedRefreshDelay * 2);
		});
	}
	function startServedRefresh():Void {
		servedRefreshDelay = 1.5;
		servedRefreshAt = Sys.time() + servedRefreshDelay;
		servedRefreshUntil = Sys.time() + 120;
	}
	/**
		A service that was already running when this window attached may serve other folders than the machine catalog
		gives its workspace (a folder attached or detached while no window was open, or a failed earlier change). Once per
		service, and again after a failure, the app asks it to serve the catalog's folders. Folders that cannot be served
		(nested, missing) are left out of the comparison and reported once, so one bad entry cannot keep this retrying;
		failures retry with a doubling delay, up to a minute.
	**/
	function reconcileServedFolders(attached:workspace.client.WorkspaceAttachment, fileClient:Null<workspace.client.WorkspaceFileClient>):Void {
		var machine = app.machineClient;
		if (reconcilePending || fileClient == null || machine == null || Sys.time() < reconcileRetryAt) return;
		var local = app.focus;
		if (local == null || attached != local) return;
		var current = app.application.savedWorkspaces.current;
		if (current == null) return;
		// Settled, and exohost's catalog unchanged since: nothing to look at on an idle window.
		if (reconciledClient == fileClient && reconciledWorkspace == current.id && reconciledRevision == machine.revision) return;
		var entry = catalogEntry();
		if (entry == null) return;
		// Another workspace, or other folders in the catalog, start over: nothing from the last try carries across.
		var key = current.id + "|" + entry.folders.join("|") + "|" + entry.scratch;
		if (key != reconcileKey) {
			reconcileKey = key;
			reconciledClient = null;
			reconcileReported = null;
			reconcileBackoff = 5.0;
			reconcileRetryAt = 0.0;
		}
		if (Sys.time() < reconcileRetryAt) return;
		if (reconciledClient == fileClient && reconciledWorkspace == current.id) {
			reconciledRevision = machine.revision;
			return;
		}
		var wanted = entry;
		var workspaceId = attached.fileWorkspace();
		reconcilePending = true;
		reconciledRevision = machine.revision;
		var settled = function(note:Null<String>):Void {
			reconcilePending = false;
			reconciledClient = fileClient;
			reconciledWorkspace = wanted.id;
			reconcileBackoff = 5.0;
			reportOnce(note);
		};
		var retry = function(failure:String):Void {
			reconcilePending = false;
			reconcileRetryAt = Sys.time() + reconcileBackoff;
			reconcileBackoff = workspace.client.FolderReconcile.nextDelay(reconcileBackoff);
			reportOnce(failure);
		};
		fileClient.roots(workspaceId, function(listed) {
			var served:Array<String> = [];
			var known = listed != null && listed.roots != null;
			if (known) for (root in listed.roots) if (root.path == null) known = false; else served.push(root.path);
			if (known) noteServedRoots(fileClient, workspaceId, listed.roots);
			var selection = workspace.WorkspaceFolders.select(wanted.folders);
			var skipped = selection.skipped.length == 0 ? null : "Folders not served: " + selection.skipped.join("; ");
			if (!known || !workspace.client.FolderReconcile.differs(served, selection.folders, wanted.scratch)) {
				settled(skipped);
				return;
			}
			local.setServedFolders(wanted.folders, function(failure) {
				if (failure == null) {
					settled(skipped);
					refreshServedRoots(attached);
				} else if (failure == workspace.client.WorkspaceLink.CANNOT_SET_FOLDERS) settled(failure);
				else retry(failure);
			});
		}, function(_) { retry("The workspace service did not list its folders."); });
	}
}
