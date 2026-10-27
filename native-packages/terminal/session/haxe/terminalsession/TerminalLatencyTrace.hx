package terminalsession;

/** Opt-in pipeline timestamps for correlation with profiler and external input captures. */
class TerminalLatencyTrace {
    static final enabled:Bool = Sys.getEnv("EXOSUIT_TERMINAL_LATENCY_TRACE") == "1";

    public static function mark(stage:String):Void {
        if (enabled) haxeon.ProfileCounter.set(stage, Sys.time());
    }
}
