package app;

/** The terminal host on its own (`terminal-host.hl --terminal-host DIR`): a small program that starts quickly. */
class TerminalHostEntry {
	static function main():Void {
		var args = Sys.args();
		Sys.exit(args.length > 0 && args[0] == "--terminal-host" ? TerminalHostMain.run(args.slice(1)) : 2);
	}
}
