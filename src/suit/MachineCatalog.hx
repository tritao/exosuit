package suit;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import workspace.PathKey;

/** One workspace on this machine: a name and one or more folders. */
typedef MachineWorkspace = {
	var id:String;
	var name:String;
	var folders:Array<String>;
}

/** This machine and its workspaces, as suit keeps them and `machine` requests report them. */
typedef MachineState = {
	var id:String;
	var name:String;
	var workspaces:Array<MachineWorkspace>;
}

/**
	The machine suit runs on and its workspaces (docs/architecture/0005-machines-and-workspaces.md), kept in
	`machine.json` in suit's home. Only the daemon writes it. A workspace's work lives in its folders' own
	services; this list only says which folders make up which workspace.
**/
class MachineCatalog {
	public static inline final VERSION = 1;
	public static inline final FOLDER_LIMIT = 16;
	public static inline final NAME_LIMIT = 200;
	static inline final FILE_LIMIT = 1048576;

	final path:String;
	public var state(default, null):MachineState;

	/**
		Loads the catalog at `path`. A missing file starts a new machine: its workspaces are one per folder in
		`imported`, the folders that already have a workspace service (`existingFolders`).
	**/
	public function new(path:String, ?imported:Array<String>) {
		this.path = path;
		if (FileSystem.exists(path)) {
			state = decode(File.getContent(path));
			return;
		}
		state = {id: newId("machine"), name: hostName(), workspaces: []};
		if (imported != null)
			for (folder in imported)
				try {
					var normal = folderPath(folder);
					if (find(normal) == null)
						state.workspaces.push({id: newId("workspace"), name: folderName(normal), folders: [normal]});
				} catch (_:Dynamic) {}
		save();
	}

	public static function file():String
		return Path.join([SuitPaths.home(), "machine.json"]);

	/** The reply to a `machine` request. */
	public function json():Dynamic
		return {id: state.id, name: state.name, workspaces: [for (workspace in state.workspaces) copy(workspace)]};

	/** Adds a workspace with one folder; its name defaults to the folder's. */
	public function create(name:Null<String>, folder:String):MachineWorkspace {
		var normal = folderPath(folder);
		var workspace = {id: newId("workspace"), name: name == null || StringTools.trim(name).length == 0 ? folderName(normal) : validName(name),
			folders: [normal]};
		state.workspaces.push(workspace);
		save();
		return copy(workspace);
	}

	public function rename(id:String, name:String):MachineWorkspace {
		var workspace = require(id);
		workspace.name = validName(name);
		save();
		return copy(workspace);
	}

	/** Names this machine, as other machines' and devices' lists will show it. */
	public function renameMachine(name:String):Void {
		state.name = validName(name);
		save();
	}

	/** Removes the workspace from the list; its folders and their services are untouched. */
	public function delete(id:String):Void {
		state.workspaces.remove(require(id));
		save();
	}

	public function addFolder(id:String, folder:String):MachineWorkspace {
		var workspace = require(id), normal = folderPath(folder);
		for (existing in workspace.folders)
			if (PathKey.same(existing, normal))
				throw "The workspace already has this folder";
		if (workspace.folders.length >= FOLDER_LIMIT)
			throw 'A workspace has at most $FOLDER_LIMIT folders';
		workspace.folders.push(normal);
		save();
		return copy(workspace);
	}

	/** A workspace keeps at least one folder; delete it instead. */
	public function removeFolder(id:String, folder:String):MachineWorkspace {
		var workspace = require(id);
		var index = -1;
		for (i in 0...workspace.folders.length)
			if (PathKey.same(workspace.folders[i], folder))
				index = i;
		if (index < 0)
			throw "The workspace does not have this folder";
		if (workspace.folders.length == 1)
			throw "A workspace needs at least one folder; remove the workspace instead";
		workspace.folders.splice(index, 1);
		save();
		return copy(workspace);
	}

	/** The first workspace whose only folder is `folder`. */
	public function find(folder:String):Null<MachineWorkspace> {
		for (workspace in state.workspaces)
			if (workspace.folders.length == 1 && PathKey.same(workspace.folders[0], folder))
				return workspace;
		return null;
	}

	function require(id:Null<String>):MachineWorkspace {
		for (workspace in state.workspaces)
			if (workspace.id == id)
				return workspace;
		throw "No such workspace on this machine";
	}

	function save():Void {
		createDirectories(Path.directory(path));
		var content = Json.stringify({version: VERSION, id: state.id, name: state.name, workspaces: state.workspaces}, null, "\t") + "\n";
		if (FileSystem.exists(path)) sys.io.AtomicFile.write(path, content) else sys.io.AtomicFile.create(path, content);
	}

	/** Creates `directory` and any missing parents; createDirectory makes one level and does not report failure. */
	static function createDirectories(directory:String):Void {
		if (directory.length == 0 || FileSystem.exists(directory))
			return;
		createDirectories(Path.directory(directory));
		FileSystem.createDirectory(directory);
		if (!FileSystem.exists(directory))
			throw 'Could not create $directory';
	}

	static function copy(workspace:MachineWorkspace):MachineWorkspace
		return {id: workspace.id, name: workspace.name, folders: workspace.folders.copy()};

	/** Validates a stored catalog; a corrupt one is an error, never silently replaced. */
	public static function decode(text:String):MachineState {
		if (text.length > FILE_LIMIT)
			throw "machine.json is too large";
		var value:Dynamic = Json.parse(text);
		if (value == null || Reflect.field(value, "version") != VERSION)
			throw "Unsupported machine.json version";
		var id = SuitRecord.SuitRecords.stringField(value, "id"), name = SuitRecord.SuitRecords.stringField(value, "name");
		var entries:Dynamic = Reflect.field(value, "workspaces");
		if (id == null || id.length == 0 || name == null || !Std.isOfType(entries, Array))
			throw "Invalid machine.json";
		var workspaces:Array<MachineWorkspace> = [];
		for (entry in (entries : Array<Dynamic>)) {
			var workspaceId = SuitRecord.SuitRecords.stringField(entry, "id"), workspaceName = SuitRecord.SuitRecords.stringField(entry, "name");
			var folders:Dynamic = Reflect.field(entry, "folders");
			if (workspaceId == null || workspaceId.length == 0 || workspaceName == null || !Std.isOfType(folders, Array))
				throw "Invalid workspace in machine.json";
			var list = [for (folder in (folders : Array<Dynamic>)) if (Std.isOfType(folder, String)) (folder : String)];
			if (list.length == 0 || list.length > FOLDER_LIMIT)
				throw "Invalid workspace folders in machine.json";
			workspaces.push({id: workspaceId, name: workspaceName, folders: list});
		}
		return {id: id, name: name, workspaces: workspaces};
	}

	/** An existing folder's absolute, normalized path. A folder that is gone later stays listed, shown as missing. */
	public static function folderPath(folder:Null<String>):String {
		if (folder == null || StringTools.trim(folder).length == 0)
			throw "Choose a folder";
		if (!Path.isAbsolute(folder))
			throw "A workspace folder must be an absolute path";
		if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder))
			throw 'Folder not found: $folder';
		var full = Path.normalize(FileSystem.fullPath(folder));
		while (full.length > 3 && StringTools.endsWith(full, "/"))
			full = full.substr(0, full.length - 1);
		return Sys.systemName() == "Windows" ? StringTools.replace(full, "/", "\\") : full;
	}

	static function validName(name:String):String {
		var trimmed = StringTools.trim(name);
		if (trimmed.length == 0)
			throw "A workspace needs a name";
		if (trimmed.length > NAME_LIMIT || trimmed.indexOf("\n") >= 0 || trimmed.indexOf("\r") >= 0)
			throw "Workspace names are one line of at most " + NAME_LIMIT + " characters";
		return trimmed;
	}

	static function folderName(folder:String):String {
		var name = Path.withoutDirectory(StringTools.replace(folder, "\\", "/"));
		return name.length == 0 ? folder : name;
	}

	static function newId(kind:String):String
		return kind + "-" + haxe.crypto.Sha256.encode(Sys.time() + ":" + Math.random() + ":" + Sys.getPid()).substr(0, 32);

	/** The name people know this machine by: lower case on Windows, whose COMPUTERNAME is upper case. */
	public static function hostName():String {
		if (Sys.systemName() == "Windows") {
			var name = Sys.getEnv("COMPUTERNAME");
			return name == null || name.length == 0 ? "this machine" : name.toLowerCase();
		}
		// macOS does not export HOSTNAME and has no /etc/hostname: such a machine is named with `suit machine rename`.
		var name = Sys.getEnv("HOSTNAME");
		if (name == null || name.length == 0)
			try name = StringTools.trim(File.getContent("/etc/hostname")) catch (_:Dynamic) {}
		if (name != null && name.indexOf(".") > 0)
			name = name.substr(0, name.indexOf("."));
		return name == null || name.length == 0 ? "this machine" : name;
	}

	/**
		Folders that already have a workspace service on their default state, for a new machine's first
		workspaces. Temporary folders (tests, fixtures) and folders that are gone are left out.
	**/
	public static function existingFolders():Array<String> {
		var folders:Array<String> = [];
		var base = agentStateBase(), workspaces = Path.join([base, "workspaces"]);
		if (!FileSystem.exists(workspaces) || !FileSystem.isDirectory(workspaces))
			return folders;
		var names = FileSystem.readDirectory(workspaces);
		names.sort(Reflect.compare);
		for (name in names) {
			// Default state folders are 20 hex digits; per-build ones add a suffix and share the folder.
			if (!~/^[0-9a-f]{20}$/.match(name))
				continue;
			try {
				var record:Dynamic = Json.parse(File.getContent(Path.join([workspaces, name, "workspace.json"])));
				var root = SuitRecord.SuitRecords.stringField(record, "root");
				if (root != null && FileSystem.exists(root) && FileSystem.isDirectory(root) && !SuitClient.underTemp(root))
					folders.push(root);
			} catch (_:Dynamic) {}
		}
		return folders;
	}

	/** Where workspace services keep their state: the agent's `AgentManager.stateBase`. */
	static function agentStateBase():String {
		var configured = Sys.getEnv("EXOSUIT_AGENT_STATE_HOME");
		if (configured != null && configured.length > 0)
			return configured;
		if (Sys.systemName() == "Windows") {
			var local = Sys.getEnv("LOCALAPPDATA");
			if (local == null || local.length == 0)
				local = Sys.getEnv("APPDATA");
			if (local == null || local.length == 0)
				local = Path.join([Sys.getEnv("USERPROFILE"), "AppData", "Local"]);
			return Path.join([local, "Exosuit"]);
		}
		var state = Sys.getEnv("XDG_STATE_HOME");
		if (state == null || state.length == 0)
			state = Path.join([Sys.getEnv("HOME"), ".local", "state"]);
		return Path.join([state, "exosuit"]);
	}
}
