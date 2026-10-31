package app;

import sys.FileSystem;
import workspace.client.MachineWorkspaces;
import workspace.client.WorkspaceServiceTarget;

/** How the editor names a machine workspace's service to the agent, and which discovery descriptors it accepts. */
class WorkspaceTargetTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function main():Void {
		var base = haxe.io.Path.join([Sys.getEnv("TEMP") == null ? "/tmp" : Sys.getEnv("TEMP"), "exosuit-target-" + Std.string(Std.int(Sys.time()))]);
		var one = base + "/one", two = base + "/two", scratch = base + "/scratch";
		FileSystem.createDirectory(base);
		for (folder in [one, two, scratch]) FileSystem.createDirectory(folder);
		try run(one, two, scratch) catch (failure:Dynamic) { cleanup(base); throw failure; }
		cleanup(base);
		Sys.println("PASS: a machine workspace is named to the agent by its id with its existing folders; descriptors of another service are refused");
	}

	static function cleanup(base:String):Void {
		for (name in ["one", "two", "scratch"]) FileSystem.deleteDirectory(base + "/" + name);
		FileSystem.deleteDirectory(base);
	}

	static function run(one:String, two:String, scratch:String):Void {
		var gone = one + "/missing";
		var target = WorkspaceServiceTarget.forWorkspace("w1", [one, gone, two, one], scratch);
		require(target.folders.length == 2, "missing and repeated folders stay in the target: " + target.folders.length + " " + one + " " + FileSystem.exists(one) + " " + FileSystem.isDirectory(one));
		var arguments = target.managerArguments();
		require(arguments.slice(0, 3).join(" ") == "--manager --workspace w1", "workspace arguments: " + arguments.join(" "));
		require(arguments.indexOf("--folder") == 3 && arguments.lastIndexOf("--folder") == 5 && arguments.indexOf("--scratch") == 7,
			"folders then scratch: " + arguments.join(" "));
		require(target.root() == target.folders[0], "the service starts in the first folder");
		require(target.signature() != WorkspaceServiceTarget.forWorkspace("w1", [two, one], scratch).signature(), "folder order is part of the signature");

		var folderless = WorkspaceServiceTarget.forWorkspace("w2", [], scratch);
		require(folderless.root() != null && folderless.managerArguments().indexOf("--folder") < 0, "a folderless workspace starts in its scratch folder");
		require(WorkspaceServiceTarget.forWorkspace("w3", [gone], null).root() == null, "nothing to start in");
		require(target.choiceKey() == "workspace:w1" && WorkspaceServiceTarget.choiceKeyOf("", one) == one, "choice keys");

		// A workspace's service names the workspace and may be rooted in any folder; a folder's names only its folder.
		require(WorkspaceServiceTarget.endpointProblem(target, one, "w1", two) == null, "the workspace's own service was refused");
		require(WorkspaceServiceTarget.endpointProblem(target, one, "w9", one) != null, "another workspace's service was accepted");
		require(WorkspaceServiceTarget.endpointProblem(target, one, null, one) != null, "a folder's service was accepted for a workspace");
		require(WorkspaceServiceTarget.endpointProblem(null, one, null, one) == null, "the folder's own service was refused");
		require(WorkspaceServiceTarget.endpointProblem(null, one, "w1", one) != null, "a workspace's service was accepted for a folder");
		require(WorkspaceServiceTarget.endpointProblem(null, one, "", two) != null, "another folder's service was accepted");

		// A workspace's own state next to its default state, per build.
		var listing = MachineWorkspaces.parse('{"version":1,"machine":"m","launcher":"/l/main.hl","stateBase":"/s","managers":['
			+ '{"workspace":"w1","root":"/a","stateDir":"/s/workspaces/w1","defaultState":true,"managerPid":5,"generation":"g","launcher":"/l/main.hl"},'
			+ '{"root":"/a","stateDir":"/s/workspaces/h","defaultState":true,"managerPid":6,"generation":"h","launcher":"/l/main.hl"}]}');
		require(listing.managers[0].workspace == "w1" && listing.managers[1].workspace == "", "listing workspace ids");
		var own = MachineWorkspaces.ownState(listing, "/a", "/l/main.hl", "w1");
		require(own == "/s/workspaces/w1-" + MachineWorkspaces.launcherKey("/l/main.hl"), "workspace own state: " + own);
		require(MachineWorkspaces.ownState(listing, "/a", "/l/main.hl") != own, "folder own state differs");
	}
}
