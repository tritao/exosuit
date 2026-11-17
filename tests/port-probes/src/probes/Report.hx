package probes;

/** PASS/FAIL lines that state the observed behaviour; a FAIL means the rule the port relies on no longer holds. */
class Report {
	public static var failures(default, null):Int = 0;

	/** `rule` says what the port relies on; `observed` says what this run saw. */
	public static function check(point:Int, rule:String, holds:Bool, observed:String):Void {
		if (!holds) failures++;
		Sys.println((holds ? "PASS " : "FAIL ") + point + ": " + rule + " -- observed: " + observed);
	}

	public static function info(point:Int, observed:String):Void Sys.println("INFO " + point + ": " + observed);

	/** Runs `run`; a throw is a FAIL of the whole point, with the error. */
	public static function guard(point:Int, name:String, run:Void->Void):Void {
		try run() catch (error:Dynamic) {
			failures++;
			Sys.println("FAIL " + point + ": " + name + " threw: " + Std.string(error));
		}
	}
}
