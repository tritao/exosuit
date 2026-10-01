package command;

import core.DocumentManager;
import core.FocusManager;
import core.WorkbenchHost;
import editor.Document;
import view.RootView;
import view.View;

class CommandContext {
	public final host:WorkbenchHost;
	/** Non-null only when `host` happens to be the legacy split-pane `RootView` (the headless/native path). Layout-only `root:*`/`project:sidebar-*` commands are gated on this being present; the UIKit app never sets it. */
	public final root:Null<RootView>;
	public final focus:FocusManager;
	public final documents:DocumentManager;

	public function new(host:WorkbenchHost, focus:FocusManager, documents:DocumentManager) {
		this.host = host;
		this.root = host.asRootView();
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

	/** Unwraps `root` for the layout-only `root:*`/`project:sidebar-*` commands, which are only ever installed with a `hasRoot` predicate. */
	public function requireRoot():RootView {
		var current = root;
		if (current == null)
			throw "command requires the legacy split-pane view";
		return current;
	}
}
