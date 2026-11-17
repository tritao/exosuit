package app;

import haxe.Json;
import haxe.io.Path;
import exohost.ExohostActions;
import exohost.ExohostClient;
import exohost.ExohostControl;
import exohost.ExohostDaemon;
import exohost.EditorDirectory;
import exohost.ExohostInventory;
import exohost.ExohostLogin;
import exohost.ExohostMenuModel;
import exohost.ExohostPaths;
import exohost.ExohostReport;
import exohost.ExohostTerminator;
import exohost.control.ExohostCtl;

/**
	`exohost`: the per-user daemon behind the Exosuit tray icon, and its command line. The same program is `exohostctl`, the
	control plane's command line (exohost.control.ExohostCtl), when run with `--ctl` or under that name (TDD Q7: one program,
	two names).
**/
class ExohostMain {
	static final USAGE:String = [
		"usage: exohost <command>",
		"  status [--json]           daemon state and process counts",
		"  list [--json]             every exosuit process, grouped by editor; orphans, then others found, last",
		"  list --all [--json]       also counts every kind (zero included), the daemon, remote access and paired devices",
		"  menu                      print the tray menu as text (disabled items in brackets)",
		"  watch [--once]            the process viewer: list, refreshed every 2 s",
		"  kill <pid>...             stop listed processes (graceful first, then the tree)",
		"  kill --orphans            stop exosuit's processes whose editor is gone",
		"  kill --all                stop exosuit's background processes, terminal hosts included; editors keep running",
		"  terminals [--json]        the terminals running in terminal hosts, with their workspaces",
		"  terminals end --all       end every terminal (its program too)",
		"  terminals end <workspace> end one workspace's terminals (id, root or folder name); add --dry-run to only print",
		"  kill ... --dry-run        print what a kill would stop, and stop nothing",
		"  remote [--json]           remote access: the relay connection, paired devices (name, paired, connected, workspaces), sessions",
		"  remote disconnect <device> end a device's live session now (id, a prefix of 4+ characters, or its name); it may reconnect",
		"  remote revoke <device>    revoke a device's pairing: it is cut off and cannot connect again",
		"  remote off                turn remote access off: ends every remote session and the relay connection",
		"  machine [--json]          this machine and its workspaces (the daemon must be running)",
		"  machine rename <name>     name this machine",
		"  workspace new [--name <name>] [<folder>...]  add a workspace; a name is needed when no folder is given",
		"  workspace scratch <id> [--json]              the workspace's scratch folder (~/Exosuit/<name>), created if needed",
		"  workspace rename <id> <name> | delete <id>   rename or remove a workspace (its folders are untouched)",
		"  workspace add-folder|remove-folder <id> <folder>  change a workspace's folders",
		"  login [on|off|status]     start exohost at login (off by default; Windows Run key, XDG autostart elsewhere)",
		"  quit                      quit Exosuit and end everything it started, terminals included (editors asked to close first)",
		"  quit --keep-terminals     the polite quit: end everything but terminals; the daemon stays up while any runs",
		"  start                     start the daemon if it is not running",
		"  stop                      stop only the daemon",
		"  daemon [--login]          run the daemon in this process (--login: stay resident)",
		"  open|focus|documents|save|project|call ...  the window commands of exohostctl (exohostctl --help)",
		"environment: EXOSUIT_EXOHOST_HOME (isolated home and endpoint), EXOSUIT_EXOHOST_SCAN=0 (registered processes only)",
		"bulk kills and quit stop only processes exosuit started (registered, or descended from one); see exohost/README.md"
	].join("\n");

	static function main():Void {
		var args = Sys.args();
		var code = 0;
		try
			code = run(args)
		catch (error:Dynamic) {
			Sys.stderr().writeString("exohost: " + Std.string(error) + "\n");
			code = 1;
		}
		Sys.stdout().flush();
		Sys.exit(code);
	}

	static function run(args:Array<String>):Int {
		if (args.length > 0 && args[0] == "--ctl")
			return ExohostCtl.run(args.slice(1));
		if (Path.withoutExtension(Path.withoutDirectory(Sys.programPath())) == "exohostctl")
			return ExohostCtl.run(args);
		var command = args.length > 0 ? args[0] : "status";
		// exohost's home must be private before anything is written to it; editors create it the same way.
		try ExohostPaths.prepare() catch (_:Dynamic) {}
		var rest = args.slice(1);
		var json = rest.indexOf("--json") >= 0;
		switch command {
			case "daemon":
				return ExohostDaemon.run(rest.indexOf("--login") >= 0);
			case "open" | "focus" | "documents" | "save" | "project" | "call":
				return ExohostCtl.run(args);
			case "status":
				var reply = ExohostControl.request({op: "status"});
				if (json) {
					print(Json.stringify(reply == null ? {ok: false, running: false, home: ExohostPaths.home()} : reply));
					return 0;
				}
				if (reply == null) {
					print("exohost daemon: not running (home " + ExohostPaths.home() + ")");
					print(new ExohostInventory().summary());
				} else
					print('exohost daemon: running, pid ${reply.pid}${reply.tray == true ? ", tray icon shown" : ""}\n${reply.summary}');
				return 0;
			case "list":
				var running = ExohostControl.request({op: "refresh"}, 1) != null;
				var inventory = new ExohostInventory(false, EditorDirectory.fromDaemon());
				if (rest.indexOf("--all") >= 0) {
					var daemon = running ? ExohostControl.request({op: "status"}, 3) : null;
					var counts = ExohostReport.kindsJson(inventory, daemon, running ? ExohostControl.request({op: "remote-status"}, 3) : null,
						running ? ExohostControl.request({op: "remote-devices"}, 3) : null);
					if (json) {
						var value:Dynamic = ExohostReport.json(inventory, running);
						Reflect.setField(value, "all", counts);
						print(Json.stringify(value));
					} else
						print(StringTools.trim(ExohostReport.kindsText(counts) + "
" + ExohostReport.text(inventory, running)));
					return 0;
				}
				print(json ? Json.stringify(ExohostReport.json(inventory, running)) : ExohostReport.text(inventory, running));
				return 0;
			case "menu":
				var menu = new exohost.ExohostMenuModel.ExohostTextMenu();
				var ignore = function(_:Dynamic) {};
				ExohostMenuModel.build(menu, new ExohostInventory(false, EditorDirectory.fromDaemon()), {terminate: ignore, openViewer: ignore, quit: function() {}, quitKeepingTerminals: function() {}});
				print(menu.toString());
				return 0;
			case "watch":
				var once = rest.indexOf("--once") >= 0;
				while (true) {
					var inventory = new ExohostInventory(false, EditorDirectory.fromDaemon());
					var text = ExohostReport.text(inventory, null);
					if (!once)
						Sys.stdout().writeString("\x1b[2J\x1b[H");
					print(text + (once ? "" : "\n(refreshes every 2 s; use `exohost kill` to stop processes; Ctrl+C closes)"));
					if (once)
						return 0;
					Sys.sleep(2);
				}
			case "kill":
				var inventory = new ExohostInventory(false, EditorDirectory.fromDaemon());
				var targets:Array<ExohostInventory.ExohostProcess> = [];
				var dryRun = rest.remove("--dry-run");
				if (rest.indexOf("--all") >= 0)
					targets = ExohostActions.background(inventory);
				else if (rest.indexOf("--orphans") >= 0)
					targets = ExohostActions.orphans(inventory);
				else {
					if (rest.length == 0)
						throw USAGE;
					// One process named by pid may be stopped even when exosuit did not start it.
					for (value in rest) {
						var pid = Std.parseInt(value);
						var process = pid == null ? null : inventory.find(pid);
						if (process == null)
							throw '$value is not an exosuit process exohost knows about (see `exohost list`)';
						targets.push(process);
					}
				}
				if (dryRun) {
					print(StringTools.trim(ExohostReport.plan(targets)));
					return 0;
				}
				stopTargets(inventory, targets);
				return 0;
			case "terminals":
				var inventory = new ExohostInventory(false, EditorDirectory.fromDaemon());
				var words = [for (word in rest) if (word != "--json" && word != "--dry-run") word];
				if (words.length == 0 || words[0] == "list") {
					print(json ? Json.stringify({version: 1, terminals: [for (process in inventory.terminals()) ExohostReport.processJson(inventory, process)]})
						: StringTools.trim(ExohostReport.terminalsText(inventory)));
					return 0;
				}
				if (words[0] != "end" || words.length != 2)
					throw USAGE;
				var chosen = ExohostActions.terminals(inventory, words[1] == "--all" ? null : words[1]);
				if (chosen.length == 0 && words[1] != "--all")
					throw 'No kept terminal belongs to ${words[1]} (see `exohost terminals`)';
				if (rest.indexOf("--dry-run") >= 0) {
					print(StringTools.trim(ExohostReport.plan(chosen)));
					return 0;
				}
				stopTargets(inventory, chosen);
				return 0;
			case "login":
				var verb = rest.length > 0 ? rest[0] : "status";
				switch verb {
					case "on":
						ExohostLogin.enable();
					case "off":
						ExohostLogin.disable();
					case "status":
					default:
						throw USAGE;
				}
				if (!ExohostLogin.supported()) {
					print("start at login: not supported on this system");
					return 0;
				}
				print("start at login: " + (ExohostLogin.enabled() ? "on" : "off") + (Sys.systemName() == "Windows" ? " (" + ExohostLogin.key() + "\\" + ExohostLogin.valueName() + ")" : ""));
				return 0;
			case "quit":
				var keepTerminals = rest.remove("--keep-terminals");
				var reply = ExohostControl.request({op: "quit", keepTerminals: keepTerminals});
				if (reply != null) {
					var terminals = exohost.ExohostRecord.ExohostRecords.intField(reply, "terminals");
					if (keepTerminals) {
						print('Quitting Exosuit, keeping terminals: stopping ${reply.terminating} process(es).');
						if (terminals != null && terminals > 0)
							print(ExohostReport.keptTerminals(terminals));
						else
							print("No terminal is running; the daemon exits when done.");
					} else
						print('Quitting Exosuit: ending ${reply.terminating} process(es)' + (terminals != null && terminals > 0 ? ' ($terminals terminal(s) among them)' : "")
							+ '; the daemon exits when nothing is left.');
					return 0;
				}
				var inventory = new ExohostInventory();
				stopTargets(inventory, ExohostActions.quit(inventory, keepTerminals));
				if (keepTerminals && inventory.terminals().length > 0)
					print(ExohostReport.keptTerminals(inventory.terminals().length));
				return 0;
			case "remote":
				var words = [for (word in rest) if (word != "--json") word];
				var verb = words.length > 0 ? words[0] : "list";
				var listing = ExohostControl.request({op: "remote-devices"}, 5);
				if (listing == null)
					throw "exohost is not running, so nothing is connected through it (remote access needs the daemon)";
				if (verb == "list") {
					var status = ExohostControl.request({op: "remote-status"}, 5);
					if (json) {
						print(Json.stringify({version: 1, status: status, devices: Reflect.field(listing, "devices"), pending: Reflect.field(listing, "pending")}));
						return 0;
					}
					print(StringTools.trim(ExohostReport.remoteText(status, listing)));
					return 0;
				}
				if (words.length != (verb == "off" ? 1 : 2))
					throw USAGE;
				if (verb == "off") {
					var reply = ExohostControl.request({op: "remote-disable"}, 10);
					if (reply == null || Reflect.field(reply, "ok") != true)
						throw "could not turn remote access off: " + (reply == null ? "no reply" : Std.string(Reflect.field(reply, "error")));
					print("remote access is off: every remote session and the relay connection are ended (turn it on again from Remote Access)");
					return 0;
				}
				if (verb != "disconnect" && verb != "revoke")
					throw USAGE;
				var device = ExohostReport.findDevice(listing, words[1]);
				if (device == null)
					throw 'No paired device matches ${words[1]} (see `exohost remote`)';
				var reply = ExohostControl.request({op: "remote-" + verb, deviceId: device}, 15);
				if (reply == null || Reflect.field(reply, "ok") != true)
					throw verb + " failed: " + (reply == null ? "no reply" : Std.string(Reflect.field(reply, "error")));
				print((verb == "revoke" ? "revoked " : "disconnected ") + device);
				return 0;
			case "machine":
				var renaming = args.length == 3 && args[1] == "rename";
				var reply = ExohostControl.request(renaming ? {op: "machine-rename", name: args[2]} : {op: "machine"});
				if (reply == null)
					throw "exohost daemon is not running (exohost start)";
				if (reply.ok != true)
					throw reply.error;
				if (json) {
					print(Json.stringify(reply.machine));
					return 0;
				}
				var lines = ['${reply.machine.name} · this machine'];
				for (workspace in (reply.machine.workspaces : Array<Dynamic>)) {
					lines.push('  ${workspace.name}  (${workspace.id})');
					var folders:Array<String> = workspace.folders;
					for (folder in folders)
						lines.push('    $folder');
					if (folders.length == 0)
						lines.push("    no folders");
					if (workspace.scratch != null)
						lines.push('    scratch: ${workspace.scratch}');
				}
				if ((reply.machine.workspaces : Array<Dynamic>).length == 0)
					lines.push("  no workspaces");
				print(lines.join("
"));
				return 0;
			case "workspace":
				rest = [for (word in rest) if (word != "--json") word];
				var request:Dynamic = switch rest.length > 0 ? rest[0] : "" {
					case "new": newWorkspace(rest.slice(1));
					case "scratch" if (rest.length == 2): {op: "workspace-scratch", workspace: rest[1]};
					case "rename" if (rest.length == 3): {op: "workspace-rename", workspace: rest[1], name: rest[2]};
					case "delete" if (rest.length == 2): {op: "workspace-delete", workspace: rest[1]};
					case "add-folder" if (rest.length == 3): {op: "workspace-add-folder", workspace: rest[1], folder: rest[2]};
					case "remove-folder" if (rest.length == 3): {op: "workspace-remove-folder", workspace: rest[1], folder: rest[2]};
					default: throw USAGE;
				}
				var reply = ExohostControl.request(request);
				if (reply == null)
					throw "exohost daemon is not running (exohost start)";
				if (reply.ok != true)
					throw reply.error;
				if (request.op == "workspace-scratch" && !json)
					print(reply.scratch);
				else
					print(Json.stringify(reply.workspace == null ? reply.machine : reply.workspace));
				return 0;
			case "start":
				if (ExohostControl.request({op: "status"}, 1) != null) {
					print("exohost daemon: already running");
					return 0;
				}
				var launcher = ExohostClient.findLauncher();
				if (launcher == null)
					launcher = sys.FileSystem.fullPath(Sys.programPath());
				ExohostClient.startDaemon(launcher);
				var deadline = Sys.time() + 10;
				while (Sys.time() < deadline) {
					if (ExohostControl.request({op: "status"}, 1) != null) {
						print("exohost daemon: started");
						return 0;
					}
					Sys.sleep(0.2);
				}
				throw "the daemon did not start; see daemon-error.txt in " + ExohostPaths.home();
			case "stop":
				var reply = ExohostControl.request({op: "stop"});
				print(reply == null ? "exohost daemon: not running" : "exohost daemon: stopped");
				return 0;
			case "help" | "--help" | "-h":
				print(USAGE);
				return 0;
			default:
				Sys.stderr().writeString(USAGE + "\n");
				return 2;
		}
	}

	/** `workspace new [--name <name>] [<folder>...]`; the older `workspace new <folder> --name <name>` still parses. */
	static function newWorkspace(words:Array<String>):Dynamic {
		var name:Null<String> = null;
		var folders:Array<String> = [];
		var i = 0;
		while (i < words.length) {
			if (words[i] == "--name") {
				if (i + 1 >= words.length || name != null)
					throw USAGE;
				name = words[i + 1];
				i += 2;
				continue;
			}
			folders.push(words[i]);
			i++;
		}
		if (name == null && folders.length == 0)
			throw USAGE;
		return {op: "workspace-create", name: name, folders: folders};
	}

	static function print(text:String):Void
		Sys.stdout().writeString(text + "\n");

	/**
		Stops `targets` and prints what happened. The terminal host this command runs in (exohost typed into an Exosuit
		terminal), when it is one of them, is ended last, after everything else is printed and the daemon told: ending it
		ends this command too, which would otherwise cut the rest of the stop short.
	**/
	static function stopTargets(inventory:ExohostInventory, targets:Array<ExohostInventory.ExohostProcess>):Void {
		var own = inventory.ownTerminal();
		var last = [for (target in targets) if (own != null && target.pid == own.pid) target];
		var first = [for (target in targets) if (last.indexOf(target) < 0) target];
		print(StringTools.trim(ExohostReport.results(new ExohostTerminator(inventory, first, ExohostTerminator.askThroughDaemon).run())));
		ExohostControl.request({op: "refresh"}, 1);
		if (own == null || last.length == 0)
			return;
		print('${own.pid} terminal-host: ending it now, the terminal this command runs in');
		Sys.stdout().flush();
		print(StringTools.trim(ExohostReport.results(new ExohostTerminator(inventory, last, ExohostTerminator.askThroughDaemon).run())));
	}
}
