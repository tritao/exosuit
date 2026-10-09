package commandview;

/** A host's live command catalog and matching dispatcher for the shared palette. */
class CommandPaletteSource {
	public final entries:Void->Array<CommandViewEntry>;
	public final perform:String->Void;

	public function new(entries:Void->Array<CommandViewEntry>, perform:String->Void) {
		this.entries = entries;
		this.perform = perform;
	}
}
