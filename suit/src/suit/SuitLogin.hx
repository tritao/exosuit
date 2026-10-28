package suit;

import haxe.io.Path;
import sys.FileSystem;

/**
	"Start at login", opt-in and off by default.

	Windows: a value under the per-user Run key (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`),
	written and removed with `reg.exe`. The value runs
	`conhost.exe --headless cmd.exe /d /c "<suit home>\start-at-login.cmd"`: the script sets the PATH
	HashLink needs for suit's native libraries (a Run command is limited to 260 characters, too short
	for that PATH) and starts `hl <suit> daemon --login`; `--headless` keeps a console window from
	appearing. Elsewhere it is an XDG autostart entry running `start-at-login.sh`.

	`EXOSUIT_SUIT_LOGIN_KEY` (a registry key) and `EXOSUIT_SUIT_AUTOSTART_DIR` (a directory) move where the
	entry is written, so tests never touch the user's real Run key or autostart folder.
**/
class SuitLogin {
	public static inline var RUN_KEY:String = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";

	public static function supported():Bool
		return Sys.systemName() == "Windows" || Sys.systemName() == "Linux";

	public static function key():String {
		var configured = Sys.getEnv("EXOSUIT_SUIT_LOGIN_KEY");
		return configured != null && configured.length > 0 ? configured : RUN_KEY;
	}

	/** One entry per suit home, so an isolated suit (EXOSUIT_SUIT_HOME) never replaces the user's. */
	public static function valueName():String {
		var home = Sys.getEnv("EXOSUIT_SUIT_HOME");
		return home != null && home.length > 0 ? "Exosuit suit " + haxe.crypto.Sha256.encode(home).substr(0, 12) : "Exosuit suit";
	}

	public static function scriptPath():String
		return Sys.systemName() == "Windows" ? native(Path.join([SuitPaths.home(), "start-at-login.cmd"])) : Path.join([SuitPaths.home(), "start-at-login.sh"]);

	/** Backslashes only: cmd.exe reads a forward slash in a path as a switch. */
	static function native(path:String):String
		return StringTools.replace(path, "/", "\\");

	public static function enabled():Bool {
		if (Sys.systemName() == "Windows")
			return reg(["query", key(), "/v", valueName()]) == 0;
		return FileSystem.exists(desktopPath());
	}

	/** The command the Run value holds. */
	public static function command():String {
		var system = native(systemRoot()) + "\\System32\\";
		return '"' + system + 'conhost.exe" --headless "' + system + 'cmd.exe" /d /c "' + scriptPath() + '"';
	}

	public static function enable():Void {
		if (!supported())
			throw "Start at login is not supported on this system";
		var launcher = SuitClient.findLauncher();
		if (launcher == null)
			launcher = FileSystem.fullPath(Sys.programPath());
		if (!SuitPaths.prepare())
			throw "suit's home is not a private directory of this user";
		sys.io.AtomicFile.write(scriptPath(), script(launcher));
		if (Sys.systemName() == "Windows") {
			if (reg(["add", key(), "/v", valueName(), "/t", "REG_SZ", "/d", command(), "/f"]) != 0)
				throw "Could not write " + key() + "\\" + valueName();
			return;
		}
		var directory = Path.directory(desktopPath());
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		sys.io.AtomicFile.write(desktopPath(), [
			"[Desktop Entry]", "Type=Application", "Name=Exosuit suit", "Comment=Exosuit background processes and remote access",
			"Exec=/bin/sh \"" + scriptPath() + "\"", "X-GNOME-Autostart-enabled=true", ""
		].join("\n"));
	}

	public static function disable():Void {
		if (Sys.systemName() == "Windows") {
			if (enabled() && reg(["delete", key(), "/v", valueName(), "/f"]) != 0)
				throw "Could not remove " + key() + "\\" + valueName();
		} else if (FileSystem.exists(desktopPath()))
			FileSystem.deleteFile(desktopPath());
		try if (FileSystem.exists(scriptPath())) FileSystem.deleteFile(scriptPath()) catch (_:Dynamic) {}
	}

	public static function toggle():Bool {
		if (enabled())
			disable();
		else
			enable();
		return enabled();
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
				'set "PATH=' + path + ';%PATH%"',
				'set "EXOSUIT_SUIT_LAUNCHER=' + native(launcher) + '"'
			];
			if (home != null && home.length > 0)
				lines.push('set "EXOSUIT_SUIT_HOME=' + home + '"');
			lines.push('"' + native(Sys.executablePath()) + '" "' + native(launcher) + '" daemon --login');
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

	static function desktopPath():String {
		var directory = Sys.getEnv("EXOSUIT_SUIT_AUTOSTART_DIR");
		if (directory == null || directory.length == 0) {
			var config = Sys.getEnv("XDG_CONFIG_HOME");
			if (config == null || config.length == 0)
				config = Path.join([Sys.getEnv("HOME"), ".config"]);
			directory = Path.join([config, "autostart"]);
		}
		var home = Sys.getEnv("EXOSUIT_SUIT_HOME");
		return Path.join([directory, home != null && home.length > 0 ? "exosuit-suit-" + haxe.crypto.Sha256.encode(home).substr(0, 12) + ".desktop" : "exosuit-suit.desktop"]);
	}

	static function shellQuote(value:String):String
		return "'" + StringTools.replace(value, "'", "'\\''") + "'";

	static function systemRoot():String {
		var root = Sys.getEnv("SystemRoot");
		return root != null && root.length > 0 ? root : "C:\\Windows";
	}

	/** Runs reg.exe without a console window and returns its exit code (-1 when it could not run or hung). */
	static function reg(arguments:Array<String>):Int {
		var child = sys.io.Process.spawn(native(systemRoot()) + "\\System32\\reg.exe", arguments, "", null, null, true);
		var deadline = Sys.time() + 15;
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
