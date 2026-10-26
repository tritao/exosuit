package ui;

import haxeon.ui.core.View;

/** Host-supplied terminal view and its owned session lifecycle. */
interface TerminalPanel extends View {
	public function poll():Void;
	/** Explicit runtime termination; close only releases the panel attachment. */
	public function terminate(force:Bool):Void;
	public function close():Void;
	public function status():String;
	/** Workspace metadata received on attachment, or null for local/older hosts. */
	public function workspaceName():Null<String>;
	public function columns():Int;
	public function rows():Int;
}
