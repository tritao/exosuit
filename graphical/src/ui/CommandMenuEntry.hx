package ui;

/** Command identity and its concise context-menu label. */
class CommandMenuEntry {
	public final command:String;
	public final label:String;

	public function new(command:String, label:String) {
		this.command = command;
		this.label = label;
	}
}
