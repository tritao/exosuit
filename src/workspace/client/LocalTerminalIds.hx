package workspace.client;

/** Linux-managed resource identity, never an authorization credential. */
class LocalTerminalIds {
  static var process:String;
  public static function create(number:Int):String {
    if (process == null) {
      var stat = sys.io.File.getContent("/proc/self/stat");
      process = stat.substring(0, stat.indexOf(" "));
      if (Std.parseInt(process) == null) throw "Unable to identify terminal client process";
    }
    // PID separates simultaneous editors; time separates reused PIDs; counter separates tabs.
    var time = StringTools.replace(Std.string(Sys.time()), ".", "-");
    return "workspace-terminal-" + number + "-" + process + "-" + time;
  }
}
