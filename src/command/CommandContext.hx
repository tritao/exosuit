package command;

import core.DocumentManager;
import core.FocusManager;
import core.WorkbenchHost;
import editor.Document;
import view.View;

class CommandContext {
	public final host:WorkbenchHost;
	public final focus:FocusManager;
	public final documents:DocumentManager;

	public function new(host:WorkbenchHost, focus:FocusManager, documents:DocumentManager) {
		this.host = host;
		this.focus = focus;
		this.documents = documents;
	}

	public function activeView():Null<View>
		return focus.activeView;

	public function requireView():View {
		var current = focus.activeView;
		if (current == null)
			throw "command requires an active view";
		return current;
	}

	public function requireDocument():Document {
		var document = requireView().getDocument();
		if (document == null)
			throw "command requires an active document";
		return document;
	}

}
