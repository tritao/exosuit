package app;

import haxe.Json;
import suit.SuitActions;
import suit.SuitClient;
import suit.SuitControl;
import suit.SuitDaemon;
import suit.SuitInventory;
import suit.SuitPaths;
import suit.SuitReport;
import suit.SuitTerminator;

/** `suit`: the per-user daemon behind the Exosuit tray icon, and its command line. */
class SuitMain {
	static final USAGE:String = [
		"usage: suit <command>",
		"  status [--json]           daemon state and process counts",
		"  list [--json]             every exosuit process, grouped by editor; orphans last",
		"  watch [--relay] [--once]  the process viewer: list, refreshed every 2 s",
		"  kill <pid>...             stop exosuit processes (graceful first, then the tree)",
		"  kill --orphans            stop processes whose editor is gone",
		"  kill --all                stop every background process; editors keep running",
		"  relay list [--json]       workspaces hosting remote access, with devices",
		"  relay stop <workspace>    stop hosting one workspace (root or folder name); grants persist",
		"  relay stop --all          stop all hosting",
		"  quit                      quit Exosuit: stop everything, editors asked to close first",
		"  start                     start the daemon if it is not running",
		"  stop                      stop only the daemon",
		"  daemon                    run the daemon in this process",
		"environment: EXOSUIT_SUIT_HOME (isolated home and endpoint), EXOSUIT_SUIT_SCAN=0 (registered processes only)"
	].join("\n");

	static function main():Void {
		var args = Sys.args();
		var code = 0;
		try
			code = run(args)
		catch (error:Dynamic) {
			Sys.stderr().writeString("suit: " + Std.string(error) + "\n");
			code = 1;
		}
		Sys.stdout().flush();
		Sys.exit(code);
	}

	static function run(args:Array<String>):Int {
		var command = args.length > 0 ? args[0] : "status";
		var rest = args.slice(1);
		var json = rest.indexOf("--json") >= 0;
		switch command {
			case "daemon":
				return SuitDaemon.run();
			case "status":
				var reply = SuitControl.request({op: "status"});
				if (json) {
					print(Json.stringify(reply == null ? {ok: false, running: false, home: SuitPaths.home()} : reply));
					return 0;
				}
				if (reply == null) {
					print("suit daemon: not running (home " + SuitPaths.home() + ")");
					print(new SuitInventory().summary());
				} else
					print('suit daemon: running, pid ${reply.pid}${reply.tray == true ? ", tray icon shown" : ""}\n${reply.summary}');
				return 0;
			case "list":
				var running = SuitControl.request({op: "refresh"}, 1) != null;
				var inventory = new SuitInventory();
				print(json ? Json.stringify(SuitReport.json(inventory, running)) : SuitReport.text(inventory, running));
				return 0;
			case "watch":
				var relay = rest.indexOf("--relay") >= 0, once = rest.indexOf("--once") >= 0;
				while (true) {
					var inventory = new SuitInventory();
					var text = relay ? SuitReport.relayText(inventory) : SuitReport.text(inventory, null);
					if (!once)
						Sys.stdout().writeString("\x1b[2J\x1b[H");
					print(text + (once ? "" : "\n(refreshes every 2 s; use `suit kill` to stop processes; Ctrl+C closes)"));
					if (once)
						return 0;
					Sys.sleep(2);
				}
			case "kill":
				var inventory = new SuitInventory();
				var targets:Array<SuitInventory.SuitProcess> = [];
				if (rest.indexOf("--all") >= 0)
					targets = SuitActions.background(inventory);
				else if (rest.indexOf("--orphans") >= 0)
					targets = SuitActions.orphans(inventory);
				else {
					if (rest.length == 0)
						throw USAGE;
					for (value in rest) {
						var pid = Std.parseInt(value);
						var process = pid == null ? null : inventory.find(pid);
						if (process == null)
							throw '$value is not an exosuit process suit knows about (see `suit list`)';
						targets.push(process);
					}
				}
				print(StringTools.trim(SuitReport.results(new SuitTerminator(inventory, targets).run())));
				SuitControl.request({op: "refresh"}, 1);
				return 0;
			case "relay":
				var inventory = new SuitInventory();
				var verb = rest.length > 0 ? rest[0] : "list";
				if (verb == "list") {
					if (json)
						print(Json.stringify([for (process in inventory.hosted()) SuitReport.processJson(process)]));
					else
						print(StringTools.trim(SuitReport.relayText(inventory)));
					return 0;
				}
				if (verb != "stop" || rest.length < 2)
					throw USAGE;
				var all = rest[1] == "--all";
				var targets = SuitActions.hosting(inventory, all ? null : rest[1]);
				if (targets.length == 0 && !all)
					throw 'No hosted workspace matches ${rest[1]} (see `suit relay list`)';
				print(StringTools.trim(SuitReport.results(new SuitTerminator(inventory, targets).run())));
				return 0;
			case "quit":
				var reply = SuitControl.request({op: "quit"});
				if (reply != null) {
					print('Quitting Exosuit: stopping ${reply.terminating} process(es); the daemon exits when done.');
					return 0;
				}
				var inventory = new SuitInventory();
				print(StringTools.trim(SuitReport.results(new SuitTerminator(inventory, SuitActions.everything(inventory)).run())));
				return 0;
			case "start":
				if (SuitControl.request({op: "status"}, 1) != null) {
					print("suit daemon: already running");
					return 0;
				}
				var launcher = SuitClient.findLauncher();
				if (launcher == null)
					launcher = sys.FileSystem.fullPath(Sys.programPath());
				var child = sys.io.Process.spawn(Sys.executablePath(), [launcher, "daemon"], haxe.io.Path.directory(launcher),
					[SuitClient.libraryVariable()], [SuitClient.nativePath(launcher)], true);
				child.close();
				var deadline = Sys.time() + 10;
				while (Sys.time() < deadline) {
					if (SuitControl.request({op: "status"}, 1) != null) {
						print("suit daemon: started");
						return 0;
					}
					Sys.sleep(0.2);
				}
				throw "the daemon did not start; see daemon-error.txt in " + SuitPaths.home();
			case "stop":
				var reply = SuitControl.request({op: "stop"});
				print(reply == null ? "suit daemon: not running" : "suit daemon: stopped");
				return 0;
			case "help" | "--help" | "-h":
				print(USAGE);
				return 0;
			default:
				Sys.stderr().writeString(USAGE + "\n");
				return 2;
		}
	}

	static function print(text:String):Void
		Sys.stdout().writeString(text + "\n");
}
