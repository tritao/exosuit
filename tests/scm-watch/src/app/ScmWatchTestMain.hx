package app;

import haxeon.platform.NativeKitRuntime;
import jobs.JobScheduler;
import process.ProcessManager;
import scm.ScmGroupId;
import scm.ScmJobResult;
import scm.ScmRepository;
import scm.ScmService;
import scm.ScmSnapshot;
import scm.git.GitProcess;
import scm.git.GitVersion;
import sys.FileSystem;
import sys.io.File;
import ui.ScmDirectoryWatch;

class ScmWatchTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function pumpNative(runtime:NativeKitRuntime, service:Null<ScmService>, scheduler:JobScheduler,
			complete:Void->Bool, message:String, timeout:Float = 8.0):Void {
		var deadline = Sys.time() + timeout;
		while (!complete() && Sys.time() < deadline) {
			runtime.events.wait(0.005);
			for (_ in 0...128) if (!runtime.events.poll()) break;
			if (service != null) service.update(Sys.time());
			scheduler.update(32);
		}
		require(complete(), message);
	}

	static function runGit(git:GitProcess, runtime:NativeKitRuntime, scheduler:JobScheduler, args:Array<String>, cwd:String,
			generation:Int):scm.git.GitCommandResult {
		var result:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(args, cwd, generation, value -> result = value, false);
		pumpNative(runtime, null, scheduler, () -> result != null, "Git command timed out: " + args.join(" "));
		if (result == null || result.error != null || result.value == null)
			throw "Git command failed: " + (result == null || result.error == null ? args.join(" ") : result.error.message);
		return result.value;
	}

	static function contains(snapshot:Null<ScmSnapshot>, path:String):Bool {
		if (snapshot == null) return false;
		for (group in snapshot.groups) if (group.id == ScmGroupId.Untracked)
			for (resource in group.resources) if (resource.path == path) return true;
		return false;
	}

	static function main():Int {
		// Outside the working directory, which may itself be a Git work tree.
		var temporaryDirectory = Sys.getEnv("TEMP");
		if (temporaryDirectory == null || temporaryDirectory.length == 0) temporaryDirectory = Sys.getEnv("TMP");
		if (temporaryDirectory == null || temporaryDirectory.length == 0) temporaryDirectory = Sys.getEnv("TMPDIR");
		if (temporaryDirectory == null || temporaryDirectory.length == 0)
			temporaryDirectory = Sys.systemName() == "Windows" ? Sys.getCwd() : "/tmp";
		var fixtureId = Std.string(Std.int(Sys.time() * 1000000)) + "-" + Std.string(Std.random(1000000)),
			root = temporaryDirectory + "/exosuit-scm-watch-" + fixtureId;
		// fullPath resolves only an existing path on POSIX, so the directory is made first.
		FileSystem.createDirectory(root);
		root = FileSystem.fullPath(root);
		var hooks = root + "/empty-hooks";
		FileSystem.createDirectory(hooks);
		var scheduler = new JobScheduler(), processes = new ProcessManager(), git = new GitProcess(processes, scheduler),
			versionResult:Null<ScmJobResult<GitVersion>> = null;
		git.probeVersion(1, value -> versionResult = value);
		var probeDeadline = Sys.time() + 10.0;
		while (versionResult == null && Sys.time() < probeDeadline) { scheduler.update(32); Sys.sleep(0.001); }
		if (versionResult == null || versionResult.error != null || versionResult.value == null) {
			processes.shutdown();
			FileSystem.deleteDirectory(hooks);
			FileSystem.deleteDirectory(root);
			Sys.println("PENDING: SCM native-watch runtime test needs Git 2.25 or newer");
			return 0;
		}
		var runtime = NativeKitRuntime.start();
		var service:Null<ScmService> = null, watcher:Null<ScmDirectoryWatch> = null;
		try {
			runGit(git, runtime, scheduler, ["init"], root, 2);
			// Ignored build output is left out of the watch.
			File.saveContent(root + "/.gitignore", "build/\n");
			FileSystem.createDirectory(root + "/build");
			FileSystem.createDirectory(root + "/build/out");
			var trustPath = root + "/trust.json";
			service = new ScmService(processes, scheduler, git.executable, 1000, 0, true, trustPath, hooks);
			var discovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
			service.discover(root, value -> discovery = value);
			pumpNative(runtime, service, scheduler, () -> discovery != null, "SCM watch fixture discovery timed out");
			if (discovery == null || discovery.error != null || discovery.value == null || discovery.value.length != 1)
				throw "SCM watch fixture did not produce one repository";
			var repository = discovery.value[0];
			pumpNative(runtime, service, scheduler, () -> service.watchExclusions(root).length > 0,
				"SCM watch exclusions were not computed");
			var exclusions = service.watchExclusions(root);
			require(exclusions.indexOf(root + "/build") >= 0 && exclusions.indexOf(root + "/.git/objects") >= 0,
				"SCM watch exclusions miss the ignored build directory or the object store: " + exclusions);
			watcher = new ScmDirectoryWatch(service, runtime.events);
			watcher.update(root, service.watchDirectories(root), exclusions);
			require(watcher.isWatching(root), "NativeKit did not arm the SCM worktree watcher: " + watcher.lastError);
			pumpNative(runtime, service, scheduler, () -> service.isWatchAvailable(root),
				"The SCM watch did not become available once its directories were registered");
			pumpNative(runtime, service, scheduler, () -> service.snapshot(repository.id) != null,
				"SCM watch fixture initial status timed out");

			File.saveContent(root + "/watch-first.txt", "first\n");
			pumpNative(runtime, service, scheduler, () -> contains(service.snapshot(repository.id), "watch-first.txt"),
				"NativeKit file-change event did not refresh the SCM snapshot");
			require(watcher.isWatching(root), "SCM watcher was not re-armed after its first file event");

			File.saveContent(root + "/watch-second.txt", "second\n");
			pumpNative(runtime, service, scheduler, () -> contains(service.snapshot(repository.id), "watch-second.txt"),
				"SCM watcher did not deliver a second change after re-arming", 1.2);
			require(watcher.isWatching(root), "SCM watcher was lost after a second filesystem event");

			// A second root inside the repository watches the same directories, so it shares the native watch.
			var nested = root + "/nested-root";
			FileSystem.createDirectory(nested);
			watcher.update(nested, service.watchDirectories(root), exclusions);
			require(watcher.watchCount() == 1 && watcher.isWatching(nested),
				"Two roots of one repository did not share one native watch: " + watcher.watchCount());

			watcher.update(root, [root + "/missing-watch-directory"]);
			require(!watcher.isWatching(root), "An invalid watch target unexpectedly remained active");
			require(watcher.isWatching(nested) && watcher.watchCount() == 1,
				"A root leaving a shared watch stopped it for the other root");
			File.saveContent(root + "/poll-fallback.txt", "fallback\n");
			var fallbackStarted = Sys.time();
			pumpNative(runtime, service, scheduler, () -> contains(service.snapshot(repository.id), "poll-fallback.txt"),
				"SCM polling did not recover after NativeKit watch registration failed", 4.0);
			require(Sys.time() - fallbackStarted < 4.0,
				"SCM polling fallback exceeded its recovery bound after watch registration failed");

			watcher.dispose();
			watcher = null;
			service.dispose();
			service = null;
			processes.shutdown();
			runtime.dispose();
			deleteTree(root);
			Sys.println("PASS: NativeKit SCM watch delivery, re-arm and polling fallback recovery");
			return 0;
		} catch (error:Dynamic) {
			if (watcher != null) watcher.dispose();
			if (service != null) service.dispose();
			processes.shutdown();
			runtime.dispose();
			deleteTree(root);
			throw error;
		}
	}

	static function deleteTree(path:String):Void {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path)) deleteTree(path + "/" + name);
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}
}
