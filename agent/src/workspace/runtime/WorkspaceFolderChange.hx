package workspace.runtime;

import haxe.io.Path;
import sys.FileSystem;
import app.AgentStateIdentity;

/** What a folder change did: the folders now served and the requested ones that were left out, with why. */
typedef FolderChangeResult = {folders:Array<String>, skipped:Array<String>}

/** Changes the folders a running workspace service serves, and records them in the state's `workspace.json`. */
class WorkspaceFolderChange {
	/**
		Serves the usable folders of `requested` (see WorkspaceFolders.select: bad ones are skipped and reported, not
		fatal) instead of the current ones. Everything that can fail is checked first, and the identity file is written
		before any root changes, so a failure leaves the roots and their ids exactly as they were; nothing needs
		undoing but the file. With no usable folder the service falls back to `fallback` (the workspace's scratch
		folder) but still records the empty list.
	**/
	public static function apply(requested:Array<String>, stateDirectory:String, fallback:String, files:WorkspaceFileService,
			scm:WorkspaceScmService):FolderChangeResult {
		var selection = workspace.WorkspaceFolders.select(requested);
		var next = selection.folders;
		var path = Path.join([stateDirectory, "workspace.json"]);
		var identity = FileSystem.exists(path) ? AgentStateIdentity.read(path) : null;
		var served = next.length > 0 ? next : [fallback];
		scm.checkRoots(served);
		var id = identity == null ? null : identity.workspace;
		if (identity != null && id != null) AgentStateIdentity.forWorkspace(id, next, identity.scratch).write(path);
		try {
			files.setRoots(served);
		} catch (error:Dynamic) {
			if (identity != null && id != null) try identity.write(path) catch (_:Dynamic) {}
			throw error;
		}
		try {
			scm.setRoots(served);
		} catch (error:Dynamic) {
			// checkRoots refused nothing, so this should not happen; keep the file honest about what is served.
			if (identity != null && id != null) try identity.write(path) catch (_:Dynamic) {}
			throw error;
		}
		return {folders: next, skipped: selection.skipped};
	}
}
