package ui;

import haxeon.ui.core.View;

/** Host-supplied terminal view and its owned session lifecycle. */
interface TerminalPanel extends View {
	public function poll():Void;
	/** Explicit runtime termination; close only releases the panel attachment. */
	public function terminate(force:Bool):Void;
	public function close():Void;
	public function status():String;
	public function columns():Int;
	public function rows():Int;
}
