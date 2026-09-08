package commandview;

class CommandViewEntry {
	public final label:String;
	public final detail:String;
	public final value:String;
	public final trailing:String;
	public final searchText:String;
	public final section:String;
	public var score:Int = 0;
	public var order:Int = 0;

	public function new(label:String, detail:String, value:String, ?trailing:String, ?searchText:String, ?section:String) {
		this.label = label;
		this.detail = detail;
		this.value = value;
		this.trailing = trailing == null ? "" : trailing;
		this.searchText = searchText == null ? label + " " + detail : searchText;
		this.section = section == null ? "" : section;
	}
}
