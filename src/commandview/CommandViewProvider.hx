package commandview;

class CommandViewProvider {
	public final prompt:String;
	public final entries:Array<CommandViewEntry>;
	public final onQuery:String->Void;
	public final onAccept:(entry:Null<CommandViewEntry>, query:String, backwards:Bool)->Void;
	public final onCancel:Void->Void;
	public final onMove:Int->Void;
	public final onComplete:(query:String, entry:Null<CommandViewEntry>)->String;
	/** Set by the view showing this provider: filters `entries` again after the provider changed them. */
	public var refresh:Void->Void = function() {};

	public function new(prompt:String, entries:Array<CommandViewEntry>, onQuery:String->Void,
			onAccept:(entry:Null<CommandViewEntry>, query:String, backwards:Bool)->Void, ?onCancel:Void->Void, ?onMove:Int->Void,
			?onComplete:(query:String, entry:Null<CommandViewEntry>)->String) {
		this.prompt = prompt;
		this.entries = entries;
		this.onQuery = onQuery;
		this.onAccept = onAccept;
		this.onCancel = onCancel == null ? function() {} : onCancel;
		this.onMove = onMove == null ? function(delta) {} : onMove;
		this.onComplete = onComplete == null ? function(query, entry) {
			return entry == null ? query : entry.label;
		} : onComplete;
	}
}
