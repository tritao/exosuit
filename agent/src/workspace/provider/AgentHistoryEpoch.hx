package workspace.provider;

/** Process-local uniqueness plus a fresh random/time component across restarts. */
class AgentHistoryEpoch {
 static var serial:Int = 0;
 public static function create():String
  return Std.string(Sys.time()) + "-" + Std.string(Std.random(0x3fffffff)) + "-" + Std.string(++serial);
}
