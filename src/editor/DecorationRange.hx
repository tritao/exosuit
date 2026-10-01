package editor;

import plugin.PluginDecorationKind;

/** A measured-layout decoration in absolute codepoint coordinates. */
class DecorationRange {
	public final start:Int;
	public final end:Int;
	public final color:Int;
	public final kind:PluginDecorationKind;

	public function new(start:Int, end:Int, color:Int, kind:PluginDecorationKind) {
		this.start = start;
		this.end = end;
		this.color = color;
		this.kind = kind;
	}
}
