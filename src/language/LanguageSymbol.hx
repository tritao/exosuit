package language;

class LanguageSymbol {
	public final name:String;
	public final detail:String;
	public final location:LanguageLocation;
	public function new(name:String, detail:String, location:LanguageLocation) {
		this.name = name;
		this.detail = detail;
		this.location = location;
	}
}
