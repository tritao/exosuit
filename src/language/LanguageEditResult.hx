package language;

import editor.Document;

/** Edits stay in managed buffers, with one undo transaction per changed document. */
class LanguageEditResult {
	public final applied:Bool;
	public final error:String;
	public final documents:Array<Document>;
	public function new(applied:Bool, error:String = "", ?documents:Array<Document>) {
		this.applied = applied;
		this.error = error;
		this.documents = documents == null ? [] : documents;
	}
}
