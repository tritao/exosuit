package app;

import haxeon.rpc.*;
import sys.FileSystem;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;

/** Group working directories resolve inside the workspace with the host's own path spelling (Windows included). */
class WorkspaceDirectoriesTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static function main():Void {
		containment();
		var base = Sys.args().length > 0 ? Sys.args()[0] : Sys.getCwd() + "/build/fixture";
		groupDirectories(base);
		Sys.println("PASS: workspace directory containment and group directory changes");
	}

	static function containment():Void {
		require(WorkspaceDirectories.contains("C:\\work", "C:\\work", true), "Windows root itself");
		require(WorkspaceDirectories.contains("C:\\work", "C:\\work\\docs", true), "Windows child with backslash");
		require(WorkspaceDirectories.contains("C:\\work", "C:\\work/docs", true), "Windows child with slash");
		require(WorkspaceDirectories.contains("C:\\work", "c:\\WORK\\docs", true), "Windows paths ignore case");
		require(WorkspaceDirectories.contains("C:\\", "C:\\work", true), "Windows drive root");
		require(!WorkspaceDirectories.contains("C:\\work", "C:\\workshop", true), "Windows sibling prefix");
		require(!WorkspaceDirectories.contains("C:\\work", "D:\\work\\docs", true), "Windows other drive");
		require(WorkspaceDirectories.contains("/work", "/work/docs", false), "POSIX child");
		require(WorkspaceDirectories.contains("/", "/work", false), "POSIX filesystem root");
		require(!WorkspaceDirectories.contains("/work", "/workshop", false), "POSIX sibling prefix");
		require(!WorkspaceDirectories.contains("/work", "/work\\docs", false), "POSIX backslash is a file name character");
		require(!WorkspaceDirectories.contains("/work", "/WORK/docs", false), "POSIX paths are case sensitive");
		require(!WorkspaceDirectories.contains("/work", null, false), "Missing path");
	}

	static function remove(path:String):Void {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (entry in FileSystem.readDirectory(path)) remove(path + "/" + entry);
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}

	static function groupDirectories(base:String):Void {
		remove(base);
		for (path in [base, base + "/root", base + "/root/resume", base + "/root/gone", base + "/outside"]) FileSystem.createDirectory(path);
		require(FileSystem.isDirectory(base + "/root"), "Fixture root was not created: " + FileSystem.fullPath(base + "/root"));
		var directories = new WorkspaceDirectories(base + "/root");
		var root = directories.root, windows = Sys.systemName() == "Windows";
		var resume = directories.resolve("resume");
		require(resume != null && directories.inside(resume) && resume != root, "Subdirectory did not resolve inside the workspace: " + resume);
		require(directories.resolve(root + "/resume") == resume, "Slash spelling resolved differently");
		if (windows) {
			require(directories.resolve(root + "\\resume") == resume, "Backslash spelling did not resolve");
			require(directories.resolve(root.toUpperCase() + "\\RESUME") != null, "Different case did not resolve");
		}
		require(directories.resolve(base + "/outside") == null, "Directory outside the workspace was authorized");
		require(directories.resolve(root + "/missing") == null, "Missing directory was authorized");

		var service = new WorkspaceService("w", "e", [{id: "work", name: "Work", cwd: null, revision: 1}], 32, 256, 16, null,
			directories.resolve);
		var clock = function() return Sys.time() * 1000;
		var pair = MemoryTransport.pair(), client = new RpcConnection(pair.client, clock), server = new RpcConnection(pair.server, clock);
		service.bind(server, [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE, WorkspaceProtocol.EVENTS]);
		function pump():Void for (_ in 0...4) { client.poll(); server.poll(); }
		pump();
		var counter = 0;
		function change(cwd:Null<String>, revision:Int, ?name:String):{result:Null<RenameResult>, code:String, message:String} {
			counter++;
			var result:Null<RenameResult> = null, code = "", message = "";
			client.call(WorkspaceProtocol.GROUP, {
				workspace: "w", epoch: "e", operation: "op-" + counter, group: "work", name: name == null ? "resume-2026" : name,
				expectedRevision: revision, action: "update", parent: null, cwd: cwd, order: 0
			}, 1000, function(r) result = r, function(e) { code = e.code; message = e.message; });
			pump();
			return {result: result, code: code, message: message};
		}
		var picked = change(windows ? StringTools.replace(resume, "/", "\\") : resume, 1);
		require(picked.result != null && picked.result.group.cwd == resume, "Picked subdirectory was not saved: " + picked.code);
		var typed = change(root + "/gone", 2);
		require(typed.result != null && typed.result.group.cwd == directories.resolve("gone"), "Typed directory was not canonicalized: " + typed.code);
		var outside = change(base + "/outside", 3);
		require(outside.result == null && outside.code == "invalid_directory" && outside.message.indexOf("inside the workspace") >= 0,
			"Outside directory was not rejected clearly: " + outside.code);
		remove(root + "/gone");
		var kept:RenameResult = cast typed.result;
		var renamed = change(kept.group.cwd, 3, "renamed");
		require(renamed.result != null, "Group with a vanished directory could not be renamed: " + renamed.code);
		var inherit = change(null, 4);
		require(inherit.result != null && inherit.result.group.cwd == null, "Group could not return to the inherited directory");
		var group = service.snapshot().groups[0];
		require(group.revision == 5 && group.cwd == null, "Service snapshot did not follow the changes");
		remove(base);
	}
}
