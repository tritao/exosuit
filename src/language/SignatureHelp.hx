package language;

class SignatureHelp {
	public final label:String;
	public final documentation:String;
	public final activeParameter:String;

	public function new(label:String, documentation:String, activeParameter:String) {
		this.label = label;
		this.documentation = documentation;
		this.activeParameter = activeParameter;
	}
}
