package app;

import sys.FileSystem;
import workspace.client.WorkspaceServiceTarget;

/** How a machine workspace's service is named to the agent: its id, the folders that exist, and its scratch folder. */
class WorkspaceTargetTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function main():Void {
		var base = haxe.io.Path.join([Sys.getEnv("TEMP") == null ? "/tmp" : Sys.getEnv("TEMP"), "exosuit-target-" + Std.string(Std.int(Sys.time()))]);
		var one = base + "/one", two = base + "/two", scratch = base + "/scratch";
		FileSystem.createDirectory(base);
		for (folder in [one, two, scratch]) FileSystem.createDirectory(folder);
		try run(one, two, scratch) catch (failure:Dynamic) { cleanup(base); throw failure; }
		cleanup(base);
		sharedFirstFolder();
		Sys.println("PASS: a machine workspace is named to the agent by its id with its existing folders and scratch folder");
	}

	/** Two workspaces with the same first folder: a terminal made in the second must not be found in the first. */
	static function sharedFirstFolder():Void {
		var alpha:exohost.MachineCatalog.MachineWorkspace = {id: "alpha", name: "Alpha", folders: ["C:/src/shared", "C:/src/a"], scratch: null, revision: 1};
		var beta:exohost.MachineCatalog.MachineWorkspace = {id: "beta", name: "Beta", folders: ["C:/src/shared"], scratch: null, revision: 1};
		var none:exohost.MachineCatalog.MachineWorkspace->Null<String> = function(_) return null;
		var both = [alpha, beta];
		require(workspace.client.MachineClient.holdingIn(both, "C:/src/shared", none, "beta") == beta, "a terminal of Beta was given to another workspace's service");
		require(workspace.client.MachineClient.holdingIn(both, "C:/src/shared", none, "alpha") == alpha, "a terminal of Alpha was not given to Alpha");
		require(workspace.client.MachineClient.holdingIn(both, "C:/src/shared", none) == alpha, "without a workspace id the first holder is used");
		require(workspace.client.MachineClient.holdingIn(both, "C:/src/shared", none, "gone") == alpha, "an unknown workspace id did not fall back to the folder");
		require(workspace.client.MachineClient.holdingIn(both, "C:/elsewhere", none, null) == null, "a folder nobody holds was given a workspace");
	}

	static function cleanup(base:String):Void {
		for (name in ["one", "two", "scratch"]) FileSystem.deleteDirectory(base + "/" + name);
		FileSystem.deleteDirectory(base);
	}

	static function run(one:String, two:String, scratch:String):Void {
		var gone = one + "/missing";
		var target = WorkspaceServiceTarget.forWorkspace("w1", [one, gone, two, one], scratch);
		require(target.folders.length == 2, "missing and repeated folders stay in the target: " + target.folders.join(", "));
		var arguments = target.serviceArguments();
		require(arguments.slice(0, 2).join(" ") == "--workspace w1", "workspace arguments: " + arguments.join(" "));
		require(arguments.indexOf("--folder") == 2 && arguments.lastIndexOf("--folder") == 4 && arguments.indexOf("--scratch") == 6
			&& arguments.length == 8, "folders then scratch: " + arguments.join(" "));
		require(arguments[3] == target.folders[0] && arguments[5] == target.folders[1] && arguments[7] == target.scratch, "argument values");
		require(target.root() == target.folders[0], "the service starts in the first folder");
		require(target.signature() != WorkspaceServiceTarget.forWorkspace("w1", [two, one], scratch).signature(), "folder order is part of the signature");
		require(target.signature() != WorkspaceServiceTarget.forWorkspace("w1", [one, two], null).signature(), "the scratch folder is part of the signature");
		require(target.signature() == WorkspaceServiceTarget.forWorkspace("w1", [one, two, gone], scratch).signature(), "a missing folder changed the signature");

		var folderless = WorkspaceServiceTarget.forWorkspace("w2", [], scratch);
		require(folderless.root() == folderless.scratch && folderless.serviceArguments().indexOf("--folder") < 0,
			"a folderless workspace starts in its scratch folder");
		require(WorkspaceServiceTarget.forWorkspace("w3", [gone], null).root() == null, "nothing to start in");
		require(WorkspaceServiceTarget.forWorkspace("w3", [gone], null).serviceArguments().join(" ") == "--workspace w3", "no folders, no scratch");
	}
}
