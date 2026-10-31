package app;

import haxe.Json;
import sys.FileSystem;
import sys.io.AtomicFile;

/**
	A state folder's `workspace.json`: whose state it holds.

	- Version 1, `{root}`: a folder's service, keyed by that folder (before M19 Phase 4).
	- Version 2, `{workspace, folders, scratch}`: a workspace's service, keyed by the workspace's id in suit's machine
	  catalog (docs/architecture/0006-workspaces-without-folders.md). Its folders are rewritten at each start.
	- Version 2, `{root, migratedTo}`: a folder's old state, moved into workspace `migratedTo`. Older builds read
	  any version but 1 as a mismatch, so they refuse it rather than start an empty service there.
**/
class AgentStateIdentity {
	public static inline final FOLDER_VERSION = 1;
	public static inline final WORKSPACE_VERSION = 2;

	public final workspace:Null<String>;
	public final root:Null<String>;
	public final folders:Array<String>;
	public final scratch:Null<String>;
	public final migratedTo:Null<String>;

	function new(workspace:Null<String>, root:Null<String>, folders:Array<String>, scratch:Null<String>, migratedTo:Null<String>) {
		this.workspace = workspace;
		this.root = root;
		this.folders = folders;
		this.scratch = scratch;
		this.migratedTo = migratedTo;
	}

	public static function forFolder(root:String):AgentStateIdentity
		return new AgentStateIdentity(null, root, [root], null, null);

	public static function forWorkspace(workspace:String, folders:Array<String>, scratch:Null<String>):AgentStateIdentity
		return new AgentStateIdentity(workspace, null, folders.copy(), scratch, null);

	/** The key a service's pipe, registry record and discovery check use: the workspace's id, or the folder. */
	public function key():String {
		var id = workspace;
		if (id != null) return id;
		var folder = root;
		if (folder != null) return folder;
		throw "Workspace state identity has no key";
	}

	/** The folder a workspace service starts in and seeds its first group with: its first folder, else its scratch folder. */
	public function primaryRoot():String {
		if (folders.length > 0) return folders[0];
		var folder = scratch;
		if (folder == null) throw "A workspace service needs a folder or a scratch folder";
		return folder;
	}

	/** A workspace catalog's owner, as `workspace_meta.root` records it; a folder's catalog records the folder. */
	public static function catalogOwner(workspace:String):String
		return "workspace:" + workspace;

	/**
		A workspace id as it may appear in a state folder's name (`workspaces/<id>`). suit generates
		`workspace-<32 lowercase hex>` (MachineCatalog.newId). The id names a folder on file systems that ignore case
		(Windows, macOS by default), so two ids differing only in case would share a state. Only the lower-case spelling
		is accepted, which makes such a pair impossible rather than something to detect. Windows device names (CON,
		NUL, COM1, ...) cannot name a folder there. The character set has no dot, so a name with an extension cannot occur;
		the bare names are refused everywhere.
	**/
	public static function validWorkspaceId(id:Null<String>):Bool
		return id != null && ~/^[a-z0-9_-]{1,128}$/.match(id) && !~/^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/.match(id);

	public static function read(path:String):AgentStateIdentity {
		var value = AgentManager.readPrivateJson(path, 16384);
		if (!AgentManager.isObject(value)) throw "Workspace state directory identity mismatch";
		var version = AgentManager.intField(value, "version");
		if (version == FOLDER_VERSION) {
			var root = AgentManager.stringField(value, "root");
			if (root == "") throw "Workspace state directory identity mismatch";
			return forFolder(root);
		}
		if (version != WORKSPACE_VERSION) throw "Workspace state directory identity mismatch";
		var migratedTo = AgentManager.stringField(value, "migratedTo");
		if (migratedTo != "") {
			if (!validWorkspaceId(migratedTo)) throw "Workspace state directory identity mismatch";
			return new AgentStateIdentity(null, AgentManager.stringField(value, "root"), [], null, migratedTo);
		}
		var workspace = AgentManager.stringField(value, "workspace");
		if (!validWorkspaceId(workspace)) throw "Workspace state directory identity mismatch";
		var listed:Dynamic = Reflect.field(value, "folders");
		if (!Std.isOfType(listed, Array)) throw "Workspace state directory identity mismatch";
		var folders = [for (folder in (listed : Array<Dynamic>)) if (Std.isOfType(folder, String)) (folder : String)];
		var scratch = AgentManager.stringField(value, "scratch");
		return forWorkspace(workspace, folders, scratch == "" ? null : scratch);
	}

	public function write(path:String):Void {
		var content = Json.stringify(json()) + "\n";
		if (FileSystem.exists(path)) AtomicFile.write(path, content) else AtomicFile.create(path, content);
	}

	/** Marks a folder's old state as moved into workspace `id`. */
	public static function markMigrated(path:String, root:String, id:String):Void
		AtomicFile.write(path, Json.stringify({version: WORKSPACE_VERSION, root: root, migratedTo: id}) + "\n");

	function json():Dynamic {
		var id = workspace;
		if (id == null) return {version: FOLDER_VERSION, root: root};
		return {version: WORKSPACE_VERSION, workspace: id, folders: folders, scratch: scratch};
	}
}
