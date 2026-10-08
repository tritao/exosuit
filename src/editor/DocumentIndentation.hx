package editor;

/** Detection is a snapshot of the opened file; typing never changes the policy. */
class DocumentIndentation {
	public var cache(default, null):Indentation.IndentationCache;
	public final detectedWidth:Null<Int>;
	public final detectedSpaces:Null<Bool>;
	public var overrideWidth:Null<Int>;
	public var overrideSpaces:Null<Bool>;
	public var effective:Null<config.Settings>;
	public var base:Null<config.Settings>;
	public var source:String = "Defaults";
	public function updateSyntax(buffer:TextBuffer, highlighter:syntax.Highlighter):Void {
		cache.dispose(); cache = new Indentation.IndentationCache(buffer, highlighter);
	}
	public function new(buffer:TextBuffer, highlighter:syntax.Highlighter) {
		cache = new Indentation.IndentationCache(buffer, highlighter);
		var detected = Indentation.detect(buffer, highlighter);
		detectedWidth = detected.width;
		detectedSpaces = detected.spaces;
	}
}
