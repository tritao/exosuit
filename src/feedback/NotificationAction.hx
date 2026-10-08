package feedback;

/** An explicit recovery operation supplied by the notification's owner. */
class NotificationAction {
	public final label:String;
	public final run:Void->Void;
	public function new(label:String, run:Void->Void) {
		this.label = label;
		this.run = run;
	}
}
