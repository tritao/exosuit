package language;

import editor.BufferSubscription;
import editor.Document;

class LanguageDocumentState {
	public final document:Document;
	public var uri:String;
	public var version:Int;
	public var revision:Int;
	public var subscription:Null<BufferSubscription>;
	public var semanticSnapshot:Null<LanguageSemanticSnapshot>;
	public var semanticWanted:Bool = true;
	public var semanticDue:Float = 0;
	public var semanticRequest:Int = -1;
	public var semanticEpoch:Int = 0;

	public function new(document:Document, uri:String) {
		this.document = document;
		this.uri = uri;
		version = 1;
		revision = document.buffer.stateId;
	}

	public function release():Void {
		if (subscription != null) subscription.release();
		subscription = null;
	}
}
