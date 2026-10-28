package suit;

import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;

/**
	"Start at login", opt-in and off by default.

	Windows: a value under the per-user Run key (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`),
	written and removed with `reg.exe`. The value runs
	`conhost.exe --headless cmd.exe /d /s /c ""%LOCALAPPDATA%\Exosuit\suit-login\<name>.cmd""`. The script
	sets the PATH HashLink needs for suit's native libraries (a Run command is limited to 260 characters,
	too short for that PATH) and starts `hl <suit> daemon --login`; `--headless` keeps a console window from
	appearing. The command names the script through `%LOCALAPPDATA%` and fixed names only, so a user or
	home path containing `&`, `(`, `^` or `%` never passes through cmd's quoting; inside the script every
	path is quoted and `%` is doubled. Elsewhere it is an XDG autostart entry running `start-at-login.sh`.

	`EXOSUIT_SUIT_LOGIN_KEY` (a registry key) and `EXOSUIT_SUIT_AUTOSTART_DIR` (a directory) move where the
	entry is written, so tests never touch the user's real Run key or autostart folder.

	The CLI uses the blocking calls. The daemon's tray uses `cached`, `refresh` and `toggleInBackground`
	with `poll` from its loop, so opening the menu never waits for `reg.exe`.
**/
class SuitLogin {
	public static inline var RUN_KEY:String = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
	static inline var REG_TIMEOUT_SECONDS:Float = 15;

	static var known:Null<Bool> = null;
	static var job:Null<RegJob> = null;
	static var queued:Array<Array<String>> = [];

	public static function supported():Bool
		return Sys.systemName() == "Windows" || Sys.systemName() == "Linux";

	public static function key():String {
		var configured = Sys.getEnv("EXOSUIT_SUIT_LOGIN_KEY");
		return configured != null && configured.length > 0 ? configured : RUN_KEY;
	}

	/** One entry per suit home, so an isolated suit (EXOSUIT_SUIT_HOME) never replaces the user's. */
	public static function valueName():String {
		var tag = homeTag();
		return tag == null ? "Exosuit suit" : "Exosuit suit " + tag;
	}

	static function homeTag():Null<String> {
		var home = Sys.getEnv("EXOSUIT_SUIT_HOME");
		return home != null && home.length > 0 ? Sha256.encode(home).substr(0, 12) : null;
	}

	/** The script the entry runs. On Windows it lives under %LOCALAPPDATA% with a fixed name (see above). */
	public static function scriptPath():String {
		if (Sys.systemName() != "Windows")
			return Path.join([SuitPaths.home(), "start-at-login.sh"]);
		return native(Path.join([localAppData(), "Exosuit", "suit-login", scriptName()]));
	}

	static function scriptName():String {
		var tag = homeTag();
		return "start-" + (tag == null ? "default" : tag) + ".cmd";
	}

	static function localAppData():String {
		var value = Sys.getEnv("LOCALAPPDATA");
		if (value == null || value.length == 0)
			throw "Start at login needs LOCALAPPDATA";
		return value;
	}

	/** Backslashes only: cmd.exe reads a forward slash in a path as a switch. */
	static function native(path:String):String
		return StringTools.replace(path, "/", "\\");

	/** Blocking: whether the entry exists (runs reg.exe on Windows). */
	public static function enabled():Bool {
		var result = Sys.systemName() == "Windows" ? reg(["query", key(), "/v", valueName()]) == 0 : FileSystem.exists(desktopPath());
		known = result;
		return result;
	}

	/** The command the Run value holds: system paths and %LOCALAPPDATA%, never a user path. */
	public static function command():String {
		var system = native(systemRoot()) + "\\System32\\";
		return '"' + system + 'conhost.exe" --headless "' + system + 'cmd.exe" /d /s /c ""%LOCALAPPDATA%\\Exosuit\\suit-login\\' + scriptName()
			+ '""';
	}

	/** Blocking. */
	public static function enable():Void {
		writeScript();
		if (Sys.systemName() == "Windows") {
			if (reg(addArguments()) != 0)
				throw "Could not write " + key() + "\\" + valueName();
			known = true;
			return;
		}
		writeDesktopEntry();
		known = true;
	}

	/** Blocking. */
	public static function disable():Void {
		if (Sys.systemName() == "Windows") {
			if (enabled() && reg(deleteArguments()) != 0)
				throw "Could not remove " + key() + "\\" + valueName();
		} else if (FileSystem.exists(desktopPath()))
			FileSystem.deleteFile(desktopPath());
		removeScript();
		known = false;
	}

	public static function toggle():Bool {
		if (enabled())
			disable();
		else
			enable();
		return enabled();
	}

	/** The last known state, without waiting; false until the first check finishes. */
	public static function cached():Bool
		return known == true;

	/** Checks the entry again in the background (see `poll`). */
	public static function refresh():Void {
		if (Sys.systemName() != "Windows") {
			known = FileSystem.exists(desktopPath());
			return;
		}
		if (job == null && queued.length == 0)
			queued.push(["query", key(), "/v", valueName()]);
		poll();
	}

	/** Turns the entry on or off in the background, from the last known state; the menu shows the result. */
	public static function toggleInBackground():Void {
		if (Sys.systemName() != "Windows") {
			toggle();
			return;
		}
		if (job != null || queued.length > 0)
			return; // a change is already running
		if (cached()) {
			queued.push(deleteArguments());
			removeScript();
		} else {
			writeScript();
			queued.push(addArguments());
		}
		queued.push(["query", key(), "/v", valueName()]);
		poll();
	}

	/** Advances background registry work; call from the daemon loop. True while work is running. */
	public static function poll():Bool {
		var current = job;
		if (current != null) {
			var status = current.child.pollExit();
			if (status < 0 && Sys.time() < current.deadline)
				return true;
			if (status < 0)
				try current.child.cancel() catch (_:Dynamic) {}
			current.child.close();
			job = null;
			if (current.arguments[0] == "query")
				known = status == 0;
		}
		if (queued.length == 0)
			return false;
		var next = queued.shift();
		try {
			job = {child: spawnReg(next), deadline: Sys.time() + REG_TIMEOUT_SECONDS, arguments: next};
		} catch (_:Dynamic) {
			job = null;
		}
		return job != null || queued.length > 0;
	}

	static function addArguments():Array<String>
		return ["add", key(), "/v", valueName(), "/t", "REG_SZ", "/d", command(), "/f"];

	static function deleteArguments():Array<String>
		return ["delete", key(), "/v", valueName(), "/f"];

	static function writeScript():Void {
		if (!supported())
			throw "Start at login is not supported on this system";
		var launcher = SuitClient.findLauncher();
		if (launcher == null)
			launcher = FileSystem.fullPath(Sys.programPath());
		if (!SuitPaths.prepare())
			throw "suit's home is not a private directory of this user";
		var directory = Path.directory(scriptPath());
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		AtomicFile.write(scriptPath(), script(launcher));
	}

	static function removeScript():Void
		try if (FileSystem.exists(scriptPath())) FileSystem.deleteFile(scriptPath()) catch (_:Dynamic) {}

	static function writeDesktopEntry():Void {
		var directory = Path.directory(desktopPath());
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		AtomicFile.write(desktopPath(), [
			"[Desktop Entry]", "Type=Application", "Name=Exosuit suit", "Comment=Exosuit background processes and remote access",
			"Exec=/bin/sh \"" + scriptPath() + "\"", "X-GNOME-Autostart-enabled=true", ""
		].join("\n"));
	}

	static function script(launcher:String):String {
		// suit's native directories, then whatever PATH the login session has (not this process's PATH).
		var path = SuitClient.nativePath(launcher);
		var inherited = Sys.getEnv(SuitClient.libraryVariable());
		var separator = Sys.systemName() == "Windows" ? ";" : ":";
		if (inherited != null && inherited.length > 0 && StringTools.endsWith(path, inherited))
			path = path.substr(0, path.length - inherited.length);
		while (StringTools.endsWith(path, separator))
			path = path.substr(0, path.length - 1);
		var home = Sys.getEnv("EXOSUIT_SUIT_HOME");
		if (Sys.systemName() == "Windows") {
			var lines = [
				"@echo off",
				"rem Written by suit (Exosuit) for Start at login. Turn it off from the tray or with `suit login off`.",
				'set "PATH=' + batchText(path) + ';%PATH%"',
				'set "EXOSUIT_SUIT_LAUNCHER=' + batchText(native(launcher)) + '"'
			];
			if (home != null && home.length > 0)
				lines.push('set "EXOSUIT_SUIT_HOME=' + batchText(home) + '"');
			lines.push('"' + batchText(native(Sys.executablePath())) + '" "' + batchText(native(launcher)) + '" daemon --login');
			return lines.join("\r\n") + "\r\n";
		}
		var lines = [
			"#!/bin/sh",
			"# Written by suit (Exosuit) for Start at login. Turn it off with `suit login off`.",
			"export " + SuitClient.libraryVariable() + "=" + shellQuote(path) + "\"${" + SuitClient.libraryVariable() + ":+:$" + SuitClient.libraryVariable() + "}\"",
			"export EXOSUIT_SUIT_LAUNCHER=" + shellQuote(launcher)
		];
		if (home != null && home.length > 0)
			lines.push("export EXOSUIT_SUIT_HOME=" + shellQuote(home));
		lines.push("exec " + shellQuote(Sys.executablePath()) + " " + shellQuote(launcher) + " daemon --login");
		return lines.join("\n") + "\n";
	}

	/**
		A path inside a double-quoted batch-file argument: `&`, `(`, `)` and `^` are literal there, and `%` is
		doubled so it is not expanded. Windows paths cannot contain `"`.
	**/
	static function batchText(value:String):String
		return StringTools.replace(value, "%", "%%");

	static function desktopPath():String {
		var directory = Sys.getEnv("EXOSUIT_SUIT_AUTOSTART_DIR");
		if (directory == null || directory.length == 0) {
			var config = Sys.getEnv("XDG_CONFIG_HOME");
			if (config == null || config.length == 0)
				config = Path.join([Sys.getEnv("HOME"), ".config"]);
			directory = Path.join([config, "autostart"]);
		}
		var tag = homeTag();
		return Path.join([directory, tag == null ? "exosuit-suit.desktop" : "exosuit-suit-" + tag + ".desktop"]);
	}

	static function shellQuote(value:String):String
		return "'" + StringTools.replace(value, "'", "'\\''") + "'";

	static function systemRoot():String {
		var root = Sys.getEnv("SystemRoot");
		return root != null && root.length > 0 ? root : "C:\\Windows";
	}

	static function spawnReg(arguments:Array<String>):sys.io.ChildProcess
		return sys.io.Process.spawn(native(systemRoot()) + "\\System32\\reg.exe", arguments, "", null, null, true);

	/** Blocking, for the CLI: runs reg.exe without a console window; its exit code, or -1 when it could not run or hung. */
	static function reg(arguments:Array<String>):Int {
		var child = spawnReg(arguments);
		var deadline = Sys.time() + REG_TIMEOUT_SECONDS;
		var status = -1;
		while (Sys.time() < deadline) {
			status = child.pollExit();
			if (status >= 0)
				break;
			Sys.sleep(0.02);
		}
		if (status < 0)
			try child.cancel() catch (_:Dynamic) {}
		child.close();
		return status;
	}
}

private typedef RegJob = {
	var child:sys.io.ChildProcess;
	var deadline:Float;
	var arguments:Array<String>;
}
