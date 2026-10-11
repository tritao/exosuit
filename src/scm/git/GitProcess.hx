package scm.git;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import jobs.JobHandle;
import jobs.JobScheduler;
import jobs.JobTask;
import process.OwnedProcess;
import process.ProcessManager;
import scm.ScmError;
import scm.ScmJob;
import scm.ScmJobResult;
import sys.FileSystem;

/** Asynchronous Git CLI runner with bounded capture and a stable error surface. */
class GitProcess {
	public static inline final MAX_STDERR = 8192;
	public static inline final DEFAULT_MAX_STDOUT = 16 * 1024 * 1024;

	final processes:ProcessManager;
	final scheduler:JobScheduler;
	final configuredPath:Null<String>;
	final emptyHooksPath:Null<String>;
	public var executable(default, null):Null<String>;
	public var version(default, null):Null<GitVersion>;

	public function new(processes:ProcessManager, scheduler:JobScheduler, ?configuredPath:String, ?emptyHooksPath:String) {
		this.processes = processes;
		this.scheduler = scheduler;
		this.configuredPath = configuredPath;
		this.emptyHooksPath = emptyHooksPath;
	}

	public function run(arguments:Array<String>, cwd:String, generation:Int, complete:ScmJobResult<GitCommandResult>->Void,
			readOnly:Bool = true, restricted:Bool = false, maxStdout:Int = DEFAULT_MAX_STDOUT,
			?disabledFilters:Array<String>, ?stdin:Bytes):ScmJob<GitCommandResult> {
		var task:Null<GitCommandTask> = null, handle:Null<JobHandle> = null;
		var job = new ScmJob<GitCommandResult>(generation, function() {
			if (handle != null) scheduler.cancel(handle); else if (task != null) task.cancel();
		});
		task = new GitCommandTask(processes, configuredPath, emptyHooksPath, arguments, cwd, readOnly, restricted, maxStdout, disabledFilters,
			stdin,
			function(result, error) {
				if (result != null) executable = result.executable;
				if (job.finish()) complete(new ScmJobResult<GitCommandResult>(generation, result, error));
			});
		handle = scheduler.schedule(task);
		return job;
	}

	public function probeVersion(generation:Int, complete:ScmJobResult<GitVersion>->Void):ScmJob<GitVersion> {
		version = null;
		var command:Null<ScmJob<GitCommandResult>> = null;
		var job = new ScmJob<GitVersion>(generation, function() {
			if (command != null) command.cancel();
		});
		command = run(["--version"], "", generation, function(result) {
			if (!job.finish()) return;
			var commandError = result.error;
			if (commandError != null) {
				complete(new ScmJobResult<GitVersion>(generation, null, commandError));
				return;
			}
			var commandResult = result.value;
			if (commandResult == null) {
				complete(new ScmJobResult<GitVersion>(generation, null, new ScmError("operation_failed", "Git version probe returned no output")));
				return;
			}
			var version = GitVersion.parse(commandResult.stdout.toString());
			if (version == null) {
				complete(new ScmJobResult<GitVersion>(generation, null, new ScmError("operation_failed", "Git returned an unrecognized version")));
			} else if (!version.supportsScm()) {
				complete(new ScmJobResult<GitVersion>(generation, null,
					new ScmError("git_too_old", 'Git 2.25 or newer is required; found ${version}')));
			} else {
				this.version = version;
				complete(new ScmJobResult<GitVersion>(generation, version));
			}
		}, false);
		return job;
	}

	/** Starts the reusable, length-framed raw-object protocol after version validation. */
	public function startBlobBatch(cwd:String, restricted:Bool):OwnedProcess {
		if (executable == null || version == null || !version.supportsScm())
			throw "Git must pass its version probe before reading blobs";
		if (restricted && (emptyHooksPath == null || emptyHooksPath.length == 0))
			throw "Restricted Git reads require an empty hooks directory";
		var arguments:Array<String> = [];
		if (restricted) {
			arguments.push("-c"); arguments.push("core.fsmonitor=");
			arguments.push("-c"); arguments.push("core.hooksPath=" + emptyHooksPath);
		}
		arguments.push("--no-pager");
		arguments.push("-c"); arguments.push("color.ui=false");
		arguments.push("--no-optional-locks");
		arguments.push("cat-file"); arguments.push("--batch");
		var environment:Map<String, String> = [];
		environment.set("GIT_TERMINAL_PROMPT", "0");
		environment.set("GIT_EDITOR", ":");
		environment.set("GIT_LITERAL_PATHSPECS", "1");
		environment.set("GIT_PAGER", "cat");
		environment.set("LC_ALL", "C");
		return processes.start(executable, arguments, cwd, environment);
	}

	static function locate(configuredPath:Null<String>, developerDirectory:Null<String>):Null<String> {
		var isMac = Sys.systemName() == "Mac";
		if (configuredPath != null && StringTools.trim(configuredPath).length > 0) {
			var requested = StringTools.trim(configuredPath);
			if (usable(requested) && (!isMac || normalize(requested) != "/usr/bin/git" || developerDirectory != null)) return requested;
		}
		var environmentPath = Sys.getEnv("PATH"), separator = Sys.systemName() == "Windows" ? ";" : ":";
		if (environmentPath != null)
			for (directory in environmentPath.split(separator)) {
				if (directory.length == 0) continue;
				var candidate = join(directory, Sys.systemName() == "Windows" ? "git.exe" : "git");
				if (isMac && normalize(candidate) == "/usr/bin/git") continue;
				if (usable(candidate)) return candidate;
			}
		if (Sys.systemName() == "Windows")
			for (candidate in ["C:/Program Files/Git/cmd/git.exe", "C:/Program Files/Git/bin/git.exe", "C:/Program Files (x86)/Git/cmd/git.exe"])
				if (usable(candidate)) return candidate;
		if (isMac && developerDirectory != null) {
			var candidate = join(join(developerDirectory, "usr/bin"), "git");
			if (usable(candidate)) return candidate;
		}
		return null;
	}

	static function usable(path:String):Bool {
		try return FileSystem.exists(path) && !FileSystem.isDirectory(path) catch (_:Dynamic) return false;
	}

	static function join(left:String, right:String):String
		return StringTools.endsWith(left, "/") || StringTools.endsWith(left, "\\") ? left + right : left + "/" + right;

	static function normalize(path:String):String return StringTools.replace(path, "\\", "/");
}

private class GitCommandTask implements JobTask {
	final processes:ProcessManager;
	final configuredPath:Null<String>;
	final emptyHooksPath:Null<String>;
	final arguments:Array<String>;
	final cwd:String;
	final readOnly:Bool;
	final restricted:Bool;
	final maxStdout:Int;
	final disabledFilters:Array<String>;
	final stdin:Null<Bytes>;
	final complete:(Null<GitCommandResult>, Null<ScmError>)->Void;
	final output:BytesBuffer = new BytesBuffer();
	var outputLength:Int = 0;
	var errorOutput:String = "";
	var child:Null<OwnedProcess>;
	var phase:String = "start";
	var xcodeOutput:String = "";
	var xcodeErrors:String = "";
	public var resolvedPath(default, null):Null<String>;
	var emptyPolls:Int = 0;
	var cancelled:Bool = false;
	var finished:Bool = false;
	var stdinOffset:Int = 0;
	var stdinClosed:Bool = false;

	public function new(processes:ProcessManager, configuredPath:Null<String>, emptyHooksPath:Null<String>, arguments:Array<String>, cwd:String,
			readOnly:Bool, restricted:Bool, maxStdout:Int, ?disabledFilters:Array<String>,
			?stdin:Bytes,
			complete:(Null<GitCommandResult>, Null<ScmError>)->Void) {
		this.processes = processes;
		this.configuredPath = configuredPath;
		this.emptyHooksPath = emptyHooksPath;
		this.arguments = arguments.copy();
		this.cwd = cwd;
		this.readOnly = readOnly;
		this.restricted = restricted;
		this.maxStdout = maxStdout < 1 ? 1 : maxStdout;
		this.disabledFilters = disabledFilters == null ? [] : disabledFilters.copy();
		this.stdin = stdin == null ? null : stdin.sub(0, stdin.length);
		this.complete = complete;
	}

	public function step():Bool {
		if (cancelled || finished) return true;
		if (phase == "start") {
			var path = GitProcess.locate(configuredPath, null);
			if (path != null) {
				startGit(path);
				return finished;
			}
			if (Sys.systemName() == "Mac") {
				try {
					child = processes.start("xcode-select", ["-p"]);
					phase = "xcode-select";
				} catch (_:Dynamic) finish(null, new ScmError("git_unavailable", "Git is unavailable and xcode-select could not be started"));
				return finished;
			}
			finish(null, new ScmError("git_unavailable", "Git was not found in scm.gitPath or PATH"));
			return true;
		}
		if (phase == "xcode-select") return pollXcodeSelect();
		return pollGit();
	}

	function pollXcodeSelect():Bool {
		var process = child;
		if (process == null) { finish(null, new ScmError("git_unavailable", "xcode-select process was lost")); return true; }
		for (_ in 0...4) {
			var text = process.readStdout();
			if (text.length == 0) break;
			if (xcodeOutput.length < 4096) xcodeOutput += text.substring(0, Std.int(Math.min(text.length, 4096 - xcodeOutput.length)));
		}
		for (_ in 0...2) {
			var text = process.readStderr();
			if (text.length == 0) break;
			if (xcodeErrors.length < GitProcess.MAX_STDERR) xcodeErrors += text.substring(0, Std.int(Math.min(text.length, GitProcess.MAX_STDERR - xcodeErrors.length)));
		}
		if (!process.exited()) return false;
		var exitCode = process.exitStatus();
		processes.release(process);
		child = null;
		if (exitCode != 0) {
			finish(null, new ScmError("git_unavailable", "Git is unavailable; xcode-select -p did not find an active toolchain"));
			return true;
		}
		var path = GitProcess.locate(configuredPath, StringTools.trim(xcodeOutput));
		if (path == null) {
			finish(null, new ScmError("git_unavailable", "Git was not found in scm.gitPath, PATH, or the selected Xcode toolchain"));
			return true;
		}
		startGit(path);
		return finished;
	}

	function startGit(path:String):Void {
		if (restricted && (emptyHooksPath == null || emptyHooksPath.length == 0)) {
			finish(null, new ScmError("untrusted", "Restricted Git reads require an empty hooks directory"));
			return;
		}
		resolvedPath = path;
		var launchArguments:Array<String> = [];
		if (restricted) {
			launchArguments.push("-c"); launchArguments.push("core.fsmonitor=");
			launchArguments.push("-c"); launchArguments.push("core.hooksPath=" + emptyHooksPath);
			for (filter in disabledFilters) {
				if (filter.length == 0 || filter.indexOf("\n") >= 0 || filter.indexOf("\r") >= 0) continue;
				for (suffix in ["process", "clean", "smudge", "required"]) {
					launchArguments.push("-c");
					launchArguments.push("filter." + filter + "." + suffix + "=" + (suffix == "required" ? "false" : ""));
				}
			}
		}
		launchArguments.push("--no-pager");
		launchArguments.push("-c"); launchArguments.push("color.ui=false");
		if (readOnly) launchArguments.push("--no-optional-locks");
		for (argument in arguments) launchArguments.push(argument);
		var environment:Map<String, String> = [];
		environment.set("GIT_TERMINAL_PROMPT", "0");
		environment.set("GIT_EDITOR", ":");
		environment.set("GIT_LITERAL_PATHSPECS", "1");
		environment.set("GIT_PAGER", "cat");
		environment.set("LC_ALL", "C");
		try {
			child = processes.start(path, launchArguments, cwd, environment);
			if (stdin == null || stdin.length == 0) {
				child.closeStdin();
				stdinClosed = true;
			}
			phase = "git";
		} catch (error:Dynamic) {
			finish(null, new ScmError("git_unavailable", "Could not start Git: " + bounded(Std.string(error), GitProcess.MAX_STDERR)));
		}
	}

	function pollGit():Bool {
		var process = child;
		if (process == null) { finish(null, new ScmError("git_unavailable", "Git process was lost")); return true; }
		var received = false;
		if (!stdinClosed) {
			var input = stdin;
			if (input == null || stdinOffset >= input.length) {
				process.closeStdin();
				stdinClosed = true;
			} else {
				var count = Std.int(Math.min(16 * 1024, input.length - stdinOffset));
				try {
					var written:Int = process.writeBytes(input, stdinOffset, count);
					if (written > 0) { stdinOffset += written; received = true; }
				} catch (failure:Dynamic) {
					if (process.exited()) {
						// Keep draining stderr below so signing and hook failures retain their useful message.
						stdinClosed = true;
					} else {
						process.cancel();
						processes.release(process);
						child = null;
						finish(null, new ScmError("stdin_failed", "Could not send input to Git: " + bounded(Std.string(failure), GitProcess.MAX_STDERR)));
						return true;
					}
				}
			}
		}
		for (_ in 0...4) {
			var bytes = process.readStdoutBytes();
			if (bytes.length == 0) break;
			if (outputLength + bytes.length > maxStdout) {
				processes.release(process);
				child = null;
				finish(null, new ScmError("output_too_large", 'Git output exceeded the $maxStdout byte limit'));
				return true;
			}
			output.add(bytes);
			outputLength += bytes.length;
			received = true;
		}
		for (_ in 0...4) {
			var text = process.readStderr();
			if (text.length == 0) break;
			if (errorOutput.length < GitProcess.MAX_STDERR)
				errorOutput += text.substring(0, Std.int(Math.min(text.length, GitProcess.MAX_STDERR - errorOutput.length)));
			received = true;
		}
		if (!process.exited()) { if (received) emptyPolls = 0; return false; }
		if (received) emptyPolls = 0; else emptyPolls++;
		if (emptyPolls < 2) return false;
		var exitCode = process.exitStatus(), result = new GitCommandResult(resolvedPath == null ? "" : resolvedPath, output.getBytes(), errorOutput, exitCode);
		processes.release(process);
		child = null;
		if (exitCode == 0) finish(result, null); else finish(null, mapError(errorOutput, exitCode));
		return true;
	}

	function mapError(stderr:String, exitCode:Int):ScmError {
		var message = StringTools.trim(stderr), lower = message.toLowerCase();
		if (lower.indexOf("is not a valid branch name") >= 0 || lower.indexOf("not a valid ref") >= 0)
			return new ScmError("invalid_reference", bounded(message, GitProcess.MAX_STDERR));
		if (lower.indexOf("not a git repository") >= 0)
			return new ScmError("not_a_repository", "The selected directory is not a Git repository");
		if (lower.indexOf("safe.directory") >= 0 || lower.indexOf("dubious ownership") >= 0)
			return new ScmError("safe_directory", "Git refused this repository because of its ownership; review safe.directory");
		if (lower.indexOf("gpg failed to sign") >= 0 || lower.indexOf("failed to sign the data") >= 0 ||
			lower.indexOf("pinentry") >= 0 || lower.indexOf("signing failed") >= 0)
			return new ScmError("signing_prompt_required", "Git signing failed. Configure a non-interactive GPG or SSH signing agent and retry: " + bounded(message, GitProcess.MAX_STDERR));
		if (lower.indexOf("terminal prompts disabled") >= 0 || lower.indexOf("could not read username") >= 0 ||
			lower.indexOf("authentication failed") >= 0 || lower.indexOf("permission denied (publickey)") >= 0)
			return new ScmError("authentication_required", "Git could not authenticate without an interactive prompt. Configure a credential helper or SSH agent and retry: " + bounded(message, GitProcess.MAX_STDERR));
		if (lower.indexOf("index.lock") >= 0 || (lower.indexOf("unable to create") >= 0 && lower.indexOf(".lock") >= 0))
			return new ScmError("lock_contention", bounded(message, GitProcess.MAX_STDERR), true);
		return new ScmError("operation_failed", message.length == 0 ? "Git command failed with status " + exitCode
			: bounded(message, GitProcess.MAX_STDERR));
	}

	static function bounded(value:String, max:Int):String return value.length <= max ? value : value.substring(0, max);

	function finish(result:Null<GitCommandResult>, error:Null<ScmError>):Void {
		if (finished || cancelled) return;
		finished = true;
		complete(result, error);
	}

	public function cancel():Void {
		if (cancelled || finished) return;
		cancelled = true;
		var process = child;
		child = null;
		if (process != null) processes.release(process);
	}
}
