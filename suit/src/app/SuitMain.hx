package app;

import haxe.Json;
import suit.SuitActions;
import suit.SuitClient;
import suit.SuitControl;
import suit.SuitDaemon;
import suit.SuitInventory;
import suit.SuitLogin;
import suit.SuitMenuModel;
import suit.SuitPaths;
import suit.SuitReport;
import suit.SuitTerminator;
import suit.relay.SuitRelayHosting;
import suit.relay.SuitRelayHosts;
import suit.relay.SuitRelayMenu;

/** `suit`: the per-user daemon behind the Exosuit tray icon, and its command line. */
class SuitMain {
	static final USAGE:String = [
		"usage: suit <command>",
		"  status [--json]           daemon state and process counts",
		"  list [--json]             every exosuit process, grouped by editor; orphans last",
		"  menu                      print the tray menu as text (disabled items in brackets)",
		"  watch [--relay] [--once]  the process viewer: list, refreshed every 2 s",
		"  kill <pid>...             stop exosuit processes (graceful first, then the tree)",
		"  kill --orphans            stop processes whose editor is gone",
		"  kill --all                stop every background process; editors keep running",
		"  relay list [--json]       workspaces hosting remote access, with devices",
		"  relay stop <workspace>    stop hosting one workspace (root or folder name); grants persist",
		"  relay stop --all          stop all hosting",
		"  relay resume <workspace>|--all  host again what relay stop paused",
		"  login [on|off|status]     start suit at login (off by default; Windows Run key, XDG autostart elsewhere)",
		"  quit                      quit Exosuit: stop everything, editors asked to close first",
		"  start                     start the daemon if it is not running",
		"  stop                      stop only the daemon",
		"  daemon [--login]          run the daemon in this process (--login: stay resident)",
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
		// suit's home must be private before anything is written to it; editors create it the same way.
		try SuitPaths.prepare() catch (_:Dynamic) {}
		var rest = args.slice(1);
		var json = rest.indexOf("--json") >= 0;
		switch command {
			case "daemon":
				return SuitDaemon.run(rest.indexOf("--login") >= 0);
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
			case "menu":
				var menu = new suit.SuitMenuModel.SuitTextMenu();
				var ignore = function(_:Dynamic) {};
				SuitMenuModel.build(menu, new SuitInventory(), {terminate: ignore, openViewer: ignore, quit: function() {}});
				print(menu.toString());
				return 0;
			case "tray-check":
				// Creates the tray icon and builds the native menu without showing it, then removes both.
				var runtime = haxeon.platform.NativeKitRuntime.start();
				var inventory = new SuitInventory();
				var tray = new suit.SuitTray(inventory.summary(), null);
				var items = tray.build(function(menu) SuitMenuModel.build(menu, inventory,
					{terminate: function(_) {}, openViewer: function(_) {}, quit: function() {}}));
				tray.setTooltip(inventory.summary() + " ");
				tray.dispose();
				runtime.dispose();
				print('tray icon created and removed; native menu built with $items command items');
				return 0;
			case "watch":
				var relay = rest.indexOf("--relay") >= 0, once = rest.indexOf("--once") >= 0;
				while (true) {
					var inventory = new SuitInventory();
					var text = relay ? SuitRelayMenu.text(inventory, SuitRelayHosting.readViews()) : SuitReport.text(inventory, null);
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
					var hosts = SuitRelayHosting.readViews();
					if (json)
						print(Json.stringify(SuitRelayMenu.json(inventory, hosts)));
					else
						print(StringTools.trim(SuitRelayMenu.text(inventory, hosts)));
					return 0;
				}
				if ((verb != "stop" && verb != "resume") || rest.length < 2)
					throw USAGE;
				var all = rest[1] == "--all";
				var query:Null<String> = all ? null : rest[1];
				// The running daemon pauses or resumes its machine sockets; without it the settings are edited here.
				var reply = SuitControl.request({op: verb == "stop" ? "relay-pause" : "relay-resume", workspace: query}, 3);
				var roots:Array<String> = [];
				if (reply != null && Std.isOfType(Reflect.field(reply, "roots"), Array))
					roots = (Reflect.field(reply, "roots") : Array<String>);
				if (reply == null)
					for (host in SuitRelayHosts.load())
						if (SuitRelayHosts.matches(host, query) && SuitRelayHosts.setPaused(host.stateDir, verb == "stop"))
							roots.push(host.root);
				if (verb == "resume") {
					if (roots.length == 0 && !all)
						throw 'No paused workspace matches ${rest[1]} (see `suit relay list`)';
					for (root in roots)
						print("resumed hosting " + root + (reply == null ? " (suit is not running; it hosts again when it starts)" : ""));
					return 0;
				}
				var targets = SuitActions.hosting(inventory, query);
				for (process in targets)
					SuitRelayHosts.setPaused(process.stateDir, true);
				if (targets.length == 0 && roots.length == 0 && !all)
					throw 'No hosted workspace matches ${rest[1]} (see `suit relay list`)';
				for (root in roots)
					print("paused hosting " + root);
				print(StringTools.trim(SuitReport.results(new SuitTerminator(inventory, targets).run())));
				return 0;
			case "login":
				var verb = rest.length > 0 ? rest[0] : "status";
				switch verb {
					case "on":
						SuitLogin.enable();
					case "off":
						SuitLogin.disable();
					case "status":
					default:
						throw USAGE;
				}
				if (!SuitLogin.supported()) {
					print("start at login: not supported on this system");
					return 0;
				}
				print("start at login: " + (SuitLogin.enabled() ? "on" : "off") + (Sys.systemName() == "Windows" ? " (" + SuitLogin.key() + "\\" + SuitLogin.valueName() + ")" : ""));
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
