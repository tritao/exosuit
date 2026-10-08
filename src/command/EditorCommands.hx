package command;

import platform.Platform;
import view.LayoutKind;

class EditorCommands {
	public static function install(registry:CommandRegistry, keymap:Keymap, clipboard:Bool = true):Void {
		registry.add("doc:save", context -> context.requireDocument().save(), hasDocument);
		registry.add("doc:undo", context -> context.requireView().undo(), hasDocument);
		registry.add("doc:redo", context -> context.requireView().redo(), hasDocument);
		registry.add("doc:select-all", context -> context.requireView().selectAll(), hasDocument);
		registry.add("doc:backspace", context -> context.requireView().backspace(), hasDocument);
		registry.add("doc:delete", context -> context.requireView().deleteForward(), hasDocument);
		registry.add("doc:newline", context -> context.requireView().insertNewline(), hasDocument);
		registry.add("doc:tab", context -> context.requireView().tab(4, true), hasDocument);
		registry.add("doc:indent", context -> context.requireView().indent(4, true), hasDocument);
		if (clipboard) {
			registry.add("doc:copy", context -> context.requireView().copy(), hasDocument);
			registry.add("doc:cut", context -> context.requireView().cut(), hasDocument);
			registry.add("doc:paste", context -> context.requireView().paste(), hasDocument);
		}
		registry.add("doc:move-to-previous-char", context -> context.requireView().moveHorizontal(-1, false), hasDocument);
		registry.add("doc:move-to-next-char", context -> context.requireView().moveHorizontal(1, false), hasDocument);
		registry.add("doc:move-to-previous-line", context -> context.requireView().moveVertical(-1, false), hasDocument);
		registry.add("doc:move-to-next-line", context -> context.requireView().moveVertical(1, false), hasDocument);
		registry.add("doc:move-to-start-of-line", context -> context.requireView().moveHome(false), hasDocument);
		registry.add("doc:move-to-end-of-line", context -> context.requireView().moveEnd(false), hasDocument);
		registry.add("doc:select-to-previous-char", context -> context.requireView().moveHorizontal(-1, true), hasDocument);
		registry.add("doc:select-to-next-char", context -> context.requireView().moveHorizontal(1, true), hasDocument);
		registry.add("doc:select-to-previous-line", context -> context.requireView().moveVertical(-1, true), hasDocument);
		registry.add("doc:select-to-next-line", context -> context.requireView().moveVertical(1, true), hasDocument);
		registry.add("doc:select-to-start-of-line", context -> context.requireView().moveHome(true), hasDocument);
		registry.add("doc:select-to-end-of-line", context -> context.requireView().moveEnd(true), hasDocument);
		registry.add("doc:move-to-previous-word", context -> context.requireView().moveWord(-1, false), hasDocument);
		registry.add("doc:move-to-next-word", context -> context.requireView().moveWord(1, false), hasDocument);
		registry.add("doc:select-to-previous-word", context -> context.requireView().moveWord(-1, true), hasDocument);
		registry.add("doc:select-to-next-word", context -> context.requireView().moveWord(1, true), hasDocument);
		registry.add("doc:move-to-start-of-document", context -> context.requireView().moveDocumentStart(false), hasDocument);
		registry.add("doc:move-to-end-of-document", context -> context.requireView().moveDocumentEnd(false), hasDocument);
		registry.add("doc:select-to-start-of-document", context -> context.requireView().moveDocumentStart(true), hasDocument);
		registry.add("doc:select-to-end-of-document", context -> context.requireView().moveDocumentEnd(true), hasDocument);
		registry.add("doc:move-page-up", context -> context.requireView().movePage(-1, false), hasDocument);
		registry.add("doc:move-page-down", context -> context.requireView().movePage(1, false), hasDocument);
		registry.add("doc:select-page-up", context -> context.requireView().movePage(-1, true), hasDocument);
		registry.add("doc:select-page-down", context -> context.requireView().movePage(1, true), hasDocument);
		registry.add("doc:toggle-word-wrap", context -> context.requireView().toggleWordWrap(), hasDocument);
		registry.add("doc:toggle-fold", context -> context.requireView().toggleFold(), hasDocument);
		// Shared host operations support both document and terminal editor tabs.
		registry.add("root:switch-to-next-tab", context -> context.host.switchActiveTab(1), context -> context.host.canCloseActiveTab());
		registry.add("root:switch-to-previous-tab", context -> context.host.switchActiveTab(-1), context -> context.host.canCloseActiveTab());
		registry.add("root:close", context -> context.host.closeActiveTab(false),
			context -> context.host.canCloseActiveTab());
		registry.add("root:split-left", context -> context.host.splitActive(LayoutKind.Horizontal, true), hasDocument);
		registry.add("root:split-right", context -> context.host.splitActive(LayoutKind.Horizontal), hasDocument);
		registry.add("root:split-up", context -> context.host.splitActive(LayoutKind.Vertical, true), hasDocument);
		registry.add("root:split-down", context -> context.host.splitActive(LayoutKind.Vertical), hasDocument);
		registry.add("root:close-pane", context -> context.host.closeActivePane(false), hasRoot);
		registry.add("project:sidebar-next", context -> context.host.sidebarMove(1), hasRoot);
		registry.add("project:sidebar-previous", context -> context.host.sidebarMove(-1), hasRoot);
		registry.add("project:sidebar-open", context -> context.host.sidebarActivate(), hasRoot);

		keymap.addDirect(Platform.KEY_S, Platform.MOD_CTRL, ["doc:save"]);
		keymap.addDirect(Platform.KEY_Z, Platform.MOD_CTRL, ["doc:undo"]);
		keymap.addDirect(Platform.KEY_Y, Platform.MOD_CTRL, ["doc:redo"]);
		keymap.addDirect(Platform.KEY_A, Platform.MOD_CTRL, ["doc:select-all"]);
		keymap.addDirect(Platform.KEY_W, Platform.MOD_CTRL, ["root:close"]);
		keymap.addDirect(Platform.KEY_TAB, Platform.MOD_CTRL, ["root:switch-to-next-tab"]);
		keymap.addDirect(Platform.KEY_TAB, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["root:switch-to-previous-tab"]);
		keymap.addDirect(Platform.KEY_TAB, 0, ["doc:tab"]);
		keymap.addDirect(Platform.KEY_ENTER, 0, ["doc:newline"]);
		keymap.addDirect(Platform.KEY_BACKSPACE, 0, ["doc:backspace"]);
		keymap.addDirect(Platform.KEY_BACKSPACE, Platform.MOD_SHIFT, ["doc:backspace"]);
		keymap.addDirect(Platform.KEY_DELETE, 0, ["doc:delete"]);
		keymap.addDirect(Platform.KEY_DELETE, Platform.MOD_SHIFT, ["doc:delete"]);
		if (clipboard) {
			keymap.addDirect(Platform.KEY_C, Platform.MOD_CTRL, ["doc:copy"]);
			keymap.addDirect(Platform.KEY_X, Platform.MOD_CTRL, ["doc:cut"]);
			keymap.addDirect(Platform.KEY_V, Platform.MOD_CTRL, ["doc:paste"]);
		}
		bindMovement(keymap, Platform.KEY_LEFT, "previous-char");
		bindMovement(keymap, Platform.KEY_RIGHT, "next-char");
		bindMovement(keymap, Platform.KEY_UP, "previous-line");
		bindMovement(keymap, Platform.KEY_DOWN, "next-line");
		bindMovement(keymap, Platform.KEY_HOME, "start-of-line");
		bindMovement(keymap, Platform.KEY_END, "end-of-line");
		keymap.addDirect(Platform.KEY_LEFT, Platform.MOD_CTRL, ["doc:move-to-previous-word"]);
		keymap.addDirect(Platform.KEY_RIGHT, Platform.MOD_CTRL, ["doc:move-to-next-word"]);
		keymap.addDirect(Platform.KEY_LEFT, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["doc:select-to-previous-word"]);
		keymap.addDirect(Platform.KEY_RIGHT, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["doc:select-to-next-word"]);
		keymap.addDirect(Platform.KEY_HOME, Platform.MOD_CTRL, ["doc:move-to-start-of-document"]);
		keymap.addDirect(Platform.KEY_END, Platform.MOD_CTRL, ["doc:move-to-end-of-document"]);
		keymap.addDirect(Platform.KEY_HOME, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["doc:select-to-start-of-document"]);
		keymap.addDirect(Platform.KEY_END, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["doc:select-to-end-of-document"]);
		keymap.addDirect(Platform.KEY_PAGE_UP, 0, ["doc:move-page-up"]);
		keymap.addDirect(Platform.KEY_PAGE_DOWN, 0, ["doc:move-page-down"]);
		keymap.addDirect(Platform.KEY_PAGE_UP, Platform.MOD_SHIFT, ["doc:select-page-up"]);
		keymap.addDirect(Platform.KEY_PAGE_DOWN, Platform.MOD_SHIFT, ["doc:select-page-down"]);
	}

	static function hasDocument(context:CommandContext):Bool
		return context.focus.activeView != null && context.focus.activeView.getDocument() != null;

	static function hasRoot(context:CommandContext):Bool
		return true;

	static function bindMovement(keymap:Keymap, key:Int, suffix:String):Void {
		keymap.addDirect(key, 0, ["doc:move-to-" + suffix]);
		keymap.addDirect(key, Platform.MOD_SHIFT, ["doc:select-to-" + suffix]);
	}
}
