package language;

/** Tokens belong to exactly one synchronized buffer revision. */
class LanguageSemanticSnapshot {
	public final documentId:Int;
	public final revision:Int;
	public final tokens:Array<LanguageSemanticToken>;

	public function new(documentId:Int, revision:Int, tokens:Array<LanguageSemanticToken>) {
		this.documentId = documentId; this.revision = revision; this.tokens = tokens;
	}
}
