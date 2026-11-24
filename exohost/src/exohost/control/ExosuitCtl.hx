package exohost.control;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.Runtime;
import haxeon.rpc.RpcConnectResult;
import exohost.ExohostControl;
import sys.FileSystem;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	`exosuitctl`, exohost's command line for the control plane (docs/design/exosuitctl/TDD-exosuit-ctl.md §8.2): Pragtical's
	command set (`list`, `status`, `focus`, `open`, `documents`, `save`, `project`, `call`) plus `quit` and `watch`, with
	Pragtical's options and exit codes. `exosuitctl` is exohost run with `--ctl` (scripts/exosuitctl.cmd); `exohost` itself takes
	`open`, `focus`, `documents`, `save`, `project` and `call` with the same meaning.

	Every command is a `control` request on exohost's main pipe; exohost routes it to a window (§6). exohost is always on, so a
	call that finds it down starts it and tries again for 2 s.
**/
class ExosuitCtl {
	public static final USAGE:String = [
		"usage: exosuitctl [options] <command>",
		"  list                         the Exosuit windows: id, pid, context and workspace folders",
		"  status                       the window's status (the most recently used, or --instance)",
		"  focus                        bring the window to the front",
		"  open PATH[:LINE[:COL]]...    open files (a tab) or folders (the workspace that holds it, or a new one named after it)",
		"  documents                    the window's open documents; * marks unsaved ones",
		"  save [PATH]                  save every document, or one",
		"  project add|change PATH      add a folder to the window's workspace, or open the workspace that holds it",
		"  call METHOD [JSON]           any control method with JSON params (e.g. exosuit.ui.snapshot, exosuit.state.get)",
		"  quit [--mode prompt|recover|save]  close the window (prompt asks about unsaved work)",
		"  watch [EVENT...]             print events as JSON lines until interrupted (all of them when none is named)",
		"  devices                      remote access: paired and pending devices, as JSON",
		"  approve [DEVICE [WORKSPACE...]]  approve the pending device (the only one when DEVICE is left out), granting the workspaces",
		"                               (isolated test hosts only: EXOSUIT_EXOHOST_HOME must be set; the owner approves in the editor)",
		"options: --instance ID, --new-window, --line N, --column N, --timeout N[s|ms] (default 5 s), --output text|json",
		"exit codes: 0 ok, 2 usage, 3 no such window, 4 connection or timeout, 5 the window refused, 6 protocol, 7 internal"
	].join("\n");

	static var json = false;
	static var timeout = 5.0;
	/** How long a call waits for an exohost it started. */
	static inline final START_SECONDS = 15.0;
	static var instance:Null<String> = null;

	public static function run(arguments:Array<String>):Int {
		var words:Array<String> = [];
		var line:Null<Int> = null, column:Null<Int> = null, newWindow = false, mode = "prompt";
		var index = 0;
		try {
			while (index < arguments.length) {
				var argument = arguments[index++];
				function value():String {
					if (index >= arguments.length)
						throw new Usage(argument + " needs a value");
					return arguments[index++];
				}
				switch argument {
					case "--instance":
						instance = value();
					case "--output":
						var output = value();
						if (output != "text" && output != "json")
							throw new Usage("--output is text or json");
						json = output == "json";
					case "--json":
						json = true;
					case "--timeout":
						timeout = seconds(value());
					case "--line":
						line = number(value());
					case "--column":
						column = number(value());
					case "--mode":
						mode = value();
					case "--new-window":
						newWindow = true;
					case "--project":
						value(); // Pragtical's project filter for routing; exohost routes by path itself.
					case "-h" | "--help" | "help":
						print(USAGE);
						return 0;
					default:
						words.push(argument);
				}
			}
			if (words.length == 0)
				throw new Usage("no command");
			var command = words.shift() ?? throw new Usage("no command");
			switch command {
				case "list":
					var result = call("exosuit.instances", {}, null);
					var instances:Array<Dynamic> = result.instances;
					if (json)
						print(Json.stringify(result));
					else if (instances.length == 0)
						print("no Exosuit window is open");
					else
						for (item in instances)
							print(item.instance_id + "  pid " + item.pid + "  " + (item.context == null ? "-" : item.context) + "  "
								+ (item.project_roots : Array<String>).join(", "));
				case "status":
					report(call("instance.status", {}, null));
				case "focus":
					report(call("window.focus", {}, null));
				case "open":
					if (words.length == 0)
						throw new Usage("open needs a path");
					var opened:Array<Dynamic> = [];
					for (word in words) {
						var target = location(word, line, column);
						if (newWindow) {
							opened.push(call("exosuit.window.new", {paths: [target.path]}, null));
							continue;
						}
						var params:Dynamic = {path: target.path};
						if (target.line != null)
							params.line = target.line;
						if (target.column != null)
							params.column = target.column;
						opened.push(call("editor.open", params, {path: target.path}));
					}
					if (!newWindow)
						call("window.focus", {}, {path: location(words[words.length - 1], null, null).path});
					report(opened.length == 1 ? opened[0] : {opened: opened});
				case "documents":
					var result = call("editor.documents", {}, null);
					if (json)
						print(Json.stringify(result));
					else
						for (document in (result.documents : Array<Dynamic>))
							print((document.modified == true ? "* " : "  ") + (document.path == null ? document.document_id : document.path));
				case "save":
					report(call("editor.save", words.length > 0 ? {path: FileSystem.absolutePath(words[0])} : {}, null));
				case "project":
					if (words.length != 2 || (words[0] != "add" && words[0] != "change"))
						throw new Usage("project add|change PATH");
					var path = FileSystem.absolutePath(words[1]);
					report(call("project." + words[0], {path: path}, {path: path}));
				case "call":
					if (words.length < 1 || words.length > 2)
						throw new Usage("call METHOD [JSON]");
					var params:Dynamic = {};
					if (words.length == 2)
						try params = Json.parse(words[1]) catch (_:Dynamic) throw new Usage("the params are not JSON");
					print(Json.stringify(call(words[0], params, null)));
				case "quit":
					if (mode != "prompt" && mode != "recover" && mode != "save")
						throw new Usage("--mode is prompt, recover or save");
					report(call("exosuit.quit", {mode: mode}, null));
				case "watch":
					return watch(words);
				case "devices":
					print(Json.stringify(remote({op: "remote-devices"})));
				case "approve":
					var home = Sys.getEnv("EXOSUIT_EXOHOST_HOME");
					if (home == null || home == "")
						throw new Usage("approve only runs against an isolated exohost (set EXOSUIT_EXOHOST_HOME)");
					var pending:Array<Dynamic> = remote({op: "remote-devices"}).pending ?? [];
					var device = words.shift() ?? (pending.length == 1 ? pending[0].deviceId : throw new Usage("approve needs a DEVICE (" + pending.length + " pending)"));
					print(Json.stringify(remote({op: "remote-approve", deviceId: device, workspaces: [for (id in words) {workspace: id, preset: "all"}]}, 60)));
				default:
					throw new Usage("unknown command " + command);
			}
			return 0;
		} catch (usage:Usage) {
			Sys.stderr().writeString("exosuitctl: " + usage.message + "\n" + USAGE + "\n");
			return 2;
		} catch (failure:Failed) {
			if (json)
				print(Json.stringify({error: failure.error.json()}));
			else
				Sys.stderr().writeString("exosuitctl: " + failure.error.code + ": " + failure.error.message + "\n");
			return failure.exit;
		}
	}

	/**
		`path:line[:col]` (Q16): the suffix counts only when it is digits and the whole string is not an existing file, so
		`C:\a.txt` is a path and `C:\a.txt:12` is line 12. `--line` and `--column` win over a suffix.
	**/
	public static function location(word:String, line:Null<Int>, column:Null<Int>):{path:String, line:Null<Int>, column:Null<Int>} {
		var path = word, foundLine:Null<Int> = null, foundColumn:Null<Int> = null;
		if (!FileSystem.exists(word)) {
			var suffix = ~/^(.+?):([0-9]+)(?::([0-9]+))?$/;
			if (suffix.match(word) && suffix.matched(1).length > 1) {
				path = suffix.matched(1);
				var columnText = suffix.matched(3);
				if (columnText != null)
					foundColumn = decimal(columnText);
				foundLine = decimal(suffix.matched(2));
			}
		}
		return {path: FileSystem.absolutePath(path), line: line != null ? line : foundLine, column: column != null ? column : foundColumn};
	}

	/** A decimal number; `Std.parseInt` reads a leading 0 as octal in haxeon (docs/haxeon-compiler-bugs.md). */
	static function decimal(text:String):Int {
		var result = 0;
		for (index in 0...text.length)
			result = result * 10 + (text.charCodeAt(index) - 48);
		return result;
	}

	static function number(text:String):Int {
		if (!~/^[0-9]+$/.match(text))
			throw new Usage("not a number: " + text);
		return decimal(text);
	}

	static function seconds(text:String):Float {
		var pattern = ~/^([0-9]+(?:\.[0-9]+)?)(ms|s)?$/;
		if (!pattern.match(text))
			throw new Usage("--timeout takes seconds, or a value with ms or s");
		var value = Std.parseFloat(pattern.matched(1));
		return pattern.matched(2) == "ms" ? value / 1000 : value;
	}

	static function report(result:Dynamic):Void
		print(json ? Json.stringify(result) : text(result));

	/** A result as `key: value` lines. */
	static function text(result:Dynamic):String {
		if (result == null || !Reflect.isObject(result))
			return Std.string(result);
		var lines = [for (field in Reflect.fields(result)) {
			var value:Dynamic = Reflect.field(result, field);
			field + ": " + (Std.isOfType(value, String) ? value : Json.stringify(value));
		}];
		return lines.join("\n");
	}

	/** One control call; throws Failed with its exit code. `target` adds routing to `--instance`. */
	static function call(method:String, params:Dynamic, target:Dynamic):Dynamic {
		var routing:Dynamic = target == null ? {} : target;
		if (instance != null)
			routing.instance_id = instance;
		var request = {op: "control", version: 1, client_id: "exohostctl:" + Sys.getPid(), method: method, params: params, target: routing};
		if (ExohostControl.request({op: "status"}, 0.5) == null) {
			// exohost is always on: a call that finds it down starts it and waits until it answers. A cold start (loading
			// the runtime, listening, the first machine read) takes a few seconds.
			startExohost();
			var deadline = Sys.time() + START_SECONDS;
			while (Sys.time() < deadline && ExohostControl.request({op: "status"}, 0.5) == null)
				Sys.sleep(0.2);
		}
		var reply = ExohostControl.request(request, timeout);
		if (reply == null)
			throw new Failed(ControlError.retry("timeout", "exohost did not answer within " + timeout + " s"), 4);
		if (Reflect.field(reply, "ok") != true) {
			var error = ControlError.read(Reflect.field(reply, "error"));
			throw new Failed(error, error.exitCode());
		}
		var result:Dynamic = Reflect.field(reply, "result");
		return result == null ? {} : result;
	}

	/** One exohost control request (`remote-*`); throws Failed (exit 4) when exohost does not answer, or its error. */
	static function remote(request:Dynamic, seconds:Float = 15):Dynamic {
		var reply = ExohostControl.request(request, seconds);
		if (reply == null)
			throw new Failed(ControlError.retry("timeout", "exohost did not answer within " + seconds + " s"), 4);
		if (Reflect.field(reply, "ok") != true)
			throw new Failed(ControlError.read(Reflect.field(reply, "error")), 5);
		return reply;
	}

	static function startExohost():Void {
		var launcher = ExohostClient.findLauncher();
		if (launcher == null)
			launcher = FileSystem.fullPath(Sys.programPath());
		try ExohostClient.startDaemon(launcher) catch (_:Dynamic) {}
	}

	/** `watch`: subscribes and prints every event as one JSON line until exohost closes the connection. */
	static function watch(names:Array<String>):Int {
		var runtime = Runtime.start();
		var hub = new NativeRpcHub(runtime.events, 4, 4, ExohostLink.MAX_MESSAGE_BYTES);
		var transport:Null<NativeRpcTransport> = null;
		var failed = false;
		hub.connect(NativeRpcHub.local(ExohostPaths.endpoint()), function(result:RpcConnectResult) {
			switch result {
				case Opened(opened):
					transport = cast opened;
				default:
					failed = true;
			}
		});
		var subscribed = false, sent = false;
		var deadline = Sys.time() + timeout;
		var params:Dynamic = {names: names};
		if (instance != null)
			params.instance = instance;
		while (!failed) {
			runtime.events.wait(0.2);
			for (_ in 0...64)
				if (!runtime.events.poll())
					break;
			var current = transport;
			if (current == null) {
				if (Sys.time() > deadline)
					break;
				continue;
			}
			if (!current.isOpen())
				break;
			if (!sent)
				sent = current.send(Bytes.ofString(Json.stringify({op: "control", version: 1, client_id: "exohostctl:" + Sys.getPid(),
					method: "exosuit.events.subscribe", params: params})));
			while (true) {
				var received = current.receive();
				if (received == null)
					break;
				if (!subscribed) {
					subscribed = true;
					continue;
				}
				Sys.stdout().writeString(received.toString() + "\n");
				Sys.stdout().flush();
			}
		}
		hub.dispose();
		runtime.dispose();
		if (!subscribed) {
			Sys.stderr().writeString("exosuitctl: timeout: exohost did not answer\n");
			return 4;
		}
		return 0;
	}

	static function print(text:String):Void
		Sys.stdout().writeString(text + "\n");
}

private class Usage {
	public final message:String;

	public function new(message:String)
		this.message = message;
}

private class Failed {
	public final error:ControlError;
	public final exit:Int;

	public function new(error:ControlError, exit:Int) {
		this.error = error;
		this.exit = exit;
	}
}
