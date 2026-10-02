package ui;

import nativekit.ui.core.View;

/** Host-supplied terminal view and its owned session lifecycle. */
interface TerminalPanel extends View {
	public function poll():Void;
	public function close():Void;
	public function status():String;
	public function columns():Int;
	public function rows():Int;
}
