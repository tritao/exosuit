package app;

import haxe.io.Bytes;

/** Commands typed into the shells the terminal tests spawn: a POSIX shell, or PowerShell on Windows. */
class TestShell {
  static inline function windows():Bool return Sys.systemName() == "Windows";

  /** Submits a command line the way a terminal sends the Enter key. */
  public static function line(command:String):Bytes return Bytes.ofString(command + (windows() ? "\r" : "\n"));

  /** Prints `prefix` followed by `count` zero-padded counters, one per line, e.g. `PROCESS_000`. */
  public static function counted(prefix:String, count:Int, suffix:String = ""):Bytes {
    return line(windows()
      ? "for ($i=0; $i -lt " + count + "; $i++) { '" + prefix + "{0:000}" + suffix + "' -f $i }"
      : "i=0; while [ $i -lt " + count + " ]; do printf '" + prefix + "%03d" + suffix + "\\n' $i; i=$((i+1)); done");
  }

  /** Prints `first` and `second` joined, so the typed command never contains the printed text. */
  public static function joined(first:String, second:String):Bytes {
    return line(windows() ? "Write-Output ('" + first + "'+'" + second + "')" : "printf '" + first + "%s\\n' " + second);
  }

  /** Prints the shell's variable `name` after `prefix`, or `unset`. */
  public static function variable(prefix:String, name:String):Bytes {
    return line(windows() ? "Write-Output ('" + prefix + "'+$(if ($" + name + ") { $" + name + " } else { 'unset' }))"
      : "printf '" + prefix + "%s\\n' \"${" + name + "-unset}\"");
  }

  /** A command that sets a shell variable which a fresh shell will not have. */
  public static function assign(name:String, value:String):String return windows() ? "$" + name + "='" + value + "'" : name + "=" + value;

  /** Clears the screen, then prints `first` and `second` joined. */
  public static function clearedJoined(first:String, second:String):Bytes {
    return line(windows() ? "Write-Host -NoNewline \"$([char]27)[2J$([char]27)[H\"; Write-Output ('" + first + "'+'" + second + "')"
      : "printf '\\033[2J\\033[H'; printf '" + first + "%s\\n' " + second);
  }

  /** Prints `prefix` followed by the working directory. */
  public static function workingDirectory(prefix:String):Bytes {
    return line(windows() ? "Write-Output ('" + prefix + "'+$PWD.Path)" : "printf '" + prefix + "'; pwd");
  }

  /** Sets `KEEP` and prints `DAEMON_PID:` and the shell's process id. */
  public static function identify():Bytes {
    return line(windows() ? "$KEEP='alive'; Write-Output ('DAEMON_'+'PID:'+$PID)" : "KEEP=alive; printf 'DAEMON_%s:%s\\n' PID $$");
  }

  /** Prints `DETACHED_OUTPUT` after a pause. */
  public static function delayed():Bytes {
    return line(windows() ? "Start-Sleep 3; Write-Output ('DETACHED_'+'OUTPUT')" : "sleep 3; printf 'DETACHED_%s\\n' OUTPUT");
  }

  /** Prints `REATTACHED_<KEEP>:<pid>`, then the terminal's rows and columns. */
  public static function reattached():Bytes {
    return line(windows()
      ? "Write-Output ('REATTACHED_'+$KEEP+':'+$PID); $s=$Host.UI.RawUI.WindowSize; Write-Output ('' + $s.Height + ' ' + $s.Width)"
      : "printf 'REATTACHED_%s:%s\\n' \"$KEEP\" $$; stty size");
  }

  /** Prints 150000`x` characters, then `DONE`. */
  public static function flood():Bytes {
    return line(windows() ? "[Console]::Out.Write('x' * 150000); 'DONE'" : "head -c 150000 /dev/zero | tr '\\000' x; printf DONE\\n");
  }
}
