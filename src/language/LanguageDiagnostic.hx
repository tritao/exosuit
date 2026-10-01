package language;

import editor.BufferPosition;
import editor.BufferChange;

class LanguageDiagnostic {
	public final from:BufferPosition;
	public final to:BufferPosition;
	public final message:String;
	public final severity:Int;

	/** Keeps a pending diagnostic anchored until the server publishes its replacement. */
	public function afterEdit(change:BufferChange):Null<LanguageDiagnostic> {
		var start = change.transform(from);
		var end = change.transform(to);
		return from.equals(to) || start.before(end) ? new LanguageDiagnostic(start, end, message, severity) : null;
	}

	public function new(from:BufferPosition, to:BufferPosition, message:String, severity:Int) {
		this.from = from;
		this.to = to;
		this.message = message;
		this.severity = severity;
	}
}
