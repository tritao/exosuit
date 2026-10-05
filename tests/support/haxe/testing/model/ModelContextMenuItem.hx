package testing.model;

class ModelContextMenuItem {
	public final label:String;
	public final action:Void->Void;

	public function new(label:String, action:Void->Void) {
		this.label = label;
		this.action = action;
	}
}
