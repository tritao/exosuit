package ui.shell;

import ui.shell.Shell;

/** Picks the shell for the window's form factor (ADR 0007). The application re-evaluates it on every resize. */
class ShellSelector {
	/** Narrower than this, on a touch-primary device, is a phone. */
	public static inline var PHONE_BREAKPOINT:Float = 600.0;

	/**
		`override` is EXOSUIT_FORM_FACTOR: "phone" and "desktop" force a shell. Otherwise a touch-primary device narrower
		than the breakpoint is a phone; everything else, tablets and an unfolded Fold included, is the desktop.
	**/
	public static function choose(width:Float, touchPrimary:Bool, override:Null<String>):ShellKind {
		if (override == "phone") return Phone;
		if (override == "desktop") return Desktop;
		return touchPrimary && width < PHONE_BREAKPOINT ? Phone : Desktop;
	}
}
