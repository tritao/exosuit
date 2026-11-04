package app;

/** Terminal key encoding, headless; then real children behind a pseudoterminal. */
class TerminalKeysTestMain {
	/** The checkout root: the working directory, or the test project's folder two levels down. */
	static function root():String {
		for (prefix in ["", "../../", "../../../"])
			if (sys.FileSystem.exists(prefix + "tests/terminal-keys/fixtures")) return prefix;
		throw "Run from the checkout root";
	}

	static function main():Void {
		var prefix = root();
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add(sys.FileSystem.fullPath(prefix + "haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexMono-Regular.ttf"),
			haxeon.ui.FontFamily.Monospace);
		ui.TerminalSymbolFont.addTo(fonts);
		TerminalKeyTests.run(fonts);
		Sys.println("PASS: modified cursor and editing keys are encoded for the PTY");
		TerminalKeyTests.runChildren(fonts, sys.FileSystem.fullPath(prefix + "tests/terminal-keys/fixtures"));
		Sys.println("PASS: children see Ctrl, Shift and Alt on cursor keys");
		TerminalGlyphTests.run();
		Sys.println("PASS: symbols missing from Android fonts have single-character stand-ins");
		fonts.dispose();
	}
}
