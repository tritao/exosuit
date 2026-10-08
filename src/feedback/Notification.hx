package feedback;

class Notification {
	public final id:Int;
	public final message:String;
	public final kind:NotificationKind;
	public final createdAt:Float;
	public final source:String;
	public final actions:Array<NotificationAction>;
	public var read(default, null):Bool = false;

	public function new(message:String, kind:NotificationKind, createdAt:Float, id:Int = 0, source:String = "", ?actions:Array<NotificationAction>) {
		this.id = id;
		this.message = message;
		this.kind = kind;
		this.createdAt = createdAt;
		this.source = source;
		this.actions = actions == null ? [] : actions.copy();
	}

	@:allow(feedback.NotificationCenter)
	function markRead():Void read = true;
}
