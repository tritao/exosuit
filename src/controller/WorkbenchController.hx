package controller;

import command.CommandContext;
import command.Command;
import command.CommandRegistry;
import command.Keymap;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import completion.CompletionRegistry;
import editor.Document;
import feedback.ErrorLog;
import platform.Platform;
import view.RootView;
import view.ProblemsView;
import workspace.Workspace;

class WorkbenchController {
	final workspace:Workspace;
	final root:RootView;
	final commands:CommandRegistry;
	final keymap:Keymap;
	final context:CommandContext;
	final completions:CompletionRegistry;
	final errors:ErrorLog;
	final search:SearchController;
	final openDocument:String->Void;
	public var openPath:String->Void = function(path) {};
	final recentCommands:Array<String> = [];

	public function new(workspace:Workspace, root:RootView, commands:CommandRegistry, keymap:Keymap, context:CommandContext,
		completions:CompletionRegistry, errors:ErrorLog, search:SearchController, openDocument:String->Void) {
		this.workspace = workspace;
		this.root = root;
		this.commands = commands;
		this.keymap = keymap;
		this.context = context;
		this.completions = completions;
		this.errors = errors;
		this.search = search;
		this.openDocument = openDocument;
		installCommands();
	}

	public function keyPressed(key:Int, modifiers:Int):Bool {
		if (root.commandView.active) return root.commandView.keyPressed(key, modifiers);
		if (root.languagePopup.keyPressed(key, modifiers)) return true;
		var handled = keymap.onKeyPressed(key, modifiers, context);
		if (handled) {
			root.cursorChanged();
			search.editorStateChanged();
		}
		return handled;
	}

	public function textInput(text:String):Void {
		if (root.languagePopup.visible) root.languagePopup.close();
		if (root.commandView.active) root.commandView.textInput(text); else {
			root.textInput(text);
			search.editorStateChanged();
		}
	}

	public function setComposition(text:String, start:Int, length:Int):Void
		root.setComposition(text, start, length);

	public function clearComposition():Void
		root.clearComposition();

	public function openFileCommandView():Void {
		var entries:Array<CommandViewEntry> = [];
		for (project in workspace.projects)
			for (node in project.files()) {
				var relative = node.path.substring(project.root.length + 1);
				entries.push(new CommandViewEntry(relative, project.name, node.path));
			}
		root.commandView.open(new CommandViewProvider("", entries, function(query) {}, function(entry, query, backwards) {
			if (entry != null) openDocument(entry.value);
			root.commandView.close();
		}, null, null, function(query, entry) {
			return entry == null ? query : entry.label;
		}));
	}

	public function openPathCommandView(directory:Bool):Void {
		root.commandView.open(new CommandViewProvider(directory ? "Open Project: " : "Open File: ", [], function(query) {},
			function(entry, path, backwards) {
				root.commandView.close();
				if (path.length > 0) openPath(path);
			}));
	}

	public function openCommandView():Void {
		var available = commands.availableCommands(context), entries:Array<CommandViewEntry> = [];
		for (name in recentCommands)
			for (command in available)
				if (command.name == name) entries.push(commandEntry(command, "Recently Used"));
		for (command in available)
			if (recentCommands.indexOf(command.name) < 0) entries.push(commandEntry(command, "Other Commands"));
		root.commandView.open(new CommandViewProvider("> ",
			entries,
			function(query) {}, function(entry, query, backwards) {
				root.commandView.close();
				if (entry != null) {
					rememberCommand(entry.value);
					commands.perform(entry.value, context);
				}
			}));
	}

	function commandEntry(command:Command, section:String):CommandViewEntry {
		var shortcuts = keymap.shortcutsFor(command.name);
		return new CommandViewEntry(command.description, "", command.name, shortcuts.join(", "),
			command.description + " " + command.name + " " + shortcuts.join(" "), section);
	}

	function rememberCommand(name:String):Void {
		recentCommands.remove(name);
		recentCommands.unshift(name);
		if (recentCommands.length > 5) recentCommands.pop();
	}

	public function openCompletionCommandView():Void {
		var view = context.activeView(), document = activeDocument(), selection = activeSelection();
		if (view == null || document == null || selection == null) return;
		var result = completions.request(document, selection.cursor), revision = document.buffer.stateId,
			entries = [for (item in result.items) new CommandViewEntry(item.label, item.detail, item.insertText)];
		if (entries.length == 0) return;
		root.commandView.open(new CommandViewProvider("Complete: ", entries, function(query) {}, function(entry, query, backwards) {
			root.commandView.close();
			if (entry == null || activeDocument() != document || document.buffer.stateId != revision
				|| !selection.cursor.equals(result.replaceTo)) return;
			if (view.replaceRange(result.replaceFrom, result.replaceTo, entry.value)) view.cursorChanged();
		}));
	}

	public function openGoToLine():Void {
		if (activeDocument() == null) return;
		root.commandView.open(new CommandViewProvider("Go to Line: ", [], function(query) {}, function(entry, query, backwards) {
			var fields = query.split(":"), line = fields.length > 0 ? Std.parseInt(fields[0]) : 0,
				column = fields.length > 1 ? Std.parseInt(fields[1]) : 1, view = context.activeView();
			if (view != null && line > 0 && column > 0) {
				view.restoreCursor(line - 1, column - 1);
				view.cursorChanged();
			}
			root.commandView.close();
		}));
	}

	public function openErrorLog():Void {
		var entries:Array<CommandViewEntry> = [];
		for (error in errors.entries)
			entries.unshift(new CommandViewEntry(error.source, error.message, error.source + ": " + error.message));
		root.commandView.open(new CommandViewProvider("Errors: ", entries, function(query) {}, function(entry, query, backwards) {
			root.commandView.close();
		}));
	}

	function installCommands():Void {
		commands.add("files:open", context -> openFileCommandView());
		commands.add("commands:open", context -> openCommandView());
		commands.add("navigation:go-to-line", context -> openGoToLine(), hasDocument);
		commands.add("doc:complete-word", context -> openCompletionCommandView(), hasDocument);
		commands.add("layout:focus-left", context -> root.focusPane(-1, 0));
		commands.add("layout:focus-right", context -> root.focusPane(1, 0));
		commands.add("layout:focus-up", context -> root.focusPane(0, -1));
		commands.add("layout:focus-down", context -> root.focusPane(0, 1));
		commands.add("layout:move-tab-left", context -> root.moveActiveTab(-1, 0));
		commands.add("layout:move-tab-right", context -> root.moveActiveTab(1, 0));
		commands.add("layout:move-tab-up", context -> root.moveActiveTab(0, -1));
		commands.add("layout:move-tab-down", context -> root.moveActiveTab(0, 1));
		commands.add("layout:reorder-tab-left", context -> root.reorderActiveTab(-1));
		commands.add("layout:reorder-tab-right", context -> root.reorderActiveTab(1));
		commands.add("workbench:toggle-sidebar", context -> root.toggleSidebar());
		commands.add("workbench:show-errors", context -> openErrorLog());
		commands.add("workbench:show-problems", context -> openProblems());
		commands.add("workbench:clear-notifications", context -> root.notifications.clear());
		commands.add("doc:newline", context -> context.requireView().insertNewline(), hasDocument);
		commands.add("doc:duplicate-line", context -> context.requireView().duplicateLines(), hasDocument);
		commands.add("doc:move-line-up", context -> context.requireView().moveLines(-1), hasDocument);
		commands.add("doc:move-line-down", context -> context.requireView().moveLines(1), hasDocument);
		commands.add("doc:delete-line", context -> context.requireView().deleteLines(), hasDocument);
		commands.add("doc:join-lines", context -> context.requireView().joinLines(), hasDocument);
		commands.add("doc:toggle-line-comment", context -> context.requireView().toggleLineComment(), hasDocument);
		commands.add("doc:select-next-occurrence", context -> context.requireView().selectNextOccurrence(), hasDocument);
		keymap.addDirect(Platform.KEY_TAB, Platform.MOD_SHIFT, ["doc:unindent"]);
		keymap.addDirect(Platform.KEY_DOWN, Platform.MOD_ALT + Platform.MOD_SHIFT, ["doc:duplicate-line"]);
		keymap.addDirect(Platform.KEY_UP, Platform.MOD_ALT, ["doc:move-line-up"]);
		keymap.addDirect(Platform.KEY_DOWN, Platform.MOD_ALT, ["doc:move-line-down"]);
		keymap.addDirect(Platform.KEY_K, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["doc:delete-line"]);
		keymap.addDirect(Platform.KEY_J, Platform.MOD_CTRL, ["doc:join-lines"]);
		keymap.addDirect(Platform.KEY_SLASH, Platform.MOD_CTRL, ["doc:toggle-line-comment"]);
		keymap.addDirect(Platform.KEY_D, Platform.MOD_CTRL, ["doc:select-next-occurrence"]);
		keymap.addDirect(Platform.KEY_P, Platform.MOD_CTRL, ["files:open"]);
		keymap.addDirect(Platform.KEY_P, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["commands:open"]);
		keymap.addDirect(Platform.KEY_G, Platform.MOD_CTRL, ["navigation:go-to-line"]);
		keymap.addDirect(Platform.KEY_SPACE, Platform.MOD_CTRL, ["doc:complete-word"]);
		keymap.addDirect(Platform.KEY_LEFT, Platform.MOD_CTRL + Platform.MOD_ALT, ["layout:focus-left"]);
		keymap.addDirect(Platform.KEY_RIGHT, Platform.MOD_CTRL + Platform.MOD_ALT, ["layout:focus-right"]);
		keymap.addDirect(Platform.KEY_UP, Platform.MOD_CTRL + Platform.MOD_ALT, ["layout:focus-up"]);
		keymap.addDirect(Platform.KEY_DOWN, Platform.MOD_CTRL + Platform.MOD_ALT, ["layout:focus-down"]);
		keymap.addDirect(Platform.KEY_LEFT, Platform.MOD_CTRL + Platform.MOD_SHIFT + Platform.MOD_ALT, ["layout:move-tab-left"]);
		keymap.addDirect(Platform.KEY_RIGHT, Platform.MOD_CTRL + Platform.MOD_SHIFT + Platform.MOD_ALT, ["layout:move-tab-right"]);
		keymap.addDirect(Platform.KEY_UP, Platform.MOD_CTRL + Platform.MOD_SHIFT + Platform.MOD_ALT, ["layout:move-tab-up"]);
		keymap.addDirect(Platform.KEY_DOWN, Platform.MOD_CTRL + Platform.MOD_SHIFT + Platform.MOD_ALT, ["layout:move-tab-down"]);
		keymap.addDirect(Platform.KEY_PAGE_UP, Platform.MOD_CTRL, ["layout:reorder-tab-left"]);
		keymap.addDirect(Platform.KEY_PAGE_DOWN, Platform.MOD_CTRL, ["layout:reorder-tab-right"]);
		keymap.addDirect(Platform.KEY_B, Platform.MOD_CTRL, ["workbench:toggle-sidebar"]);
	}

	public function openProblems():Void {
		root.openAuxiliary(new ProblemsView(root.problems, root.renderer, root.theme, root.activeLeaf.width, root.activeLeaf.height, problem -> {
			var view = root.openDocument(workspace.documents.open(problem.path));
			view.selectRange(new editor.BufferPosition(problem.line, problem.column), new editor.BufferPosition(problem.line, problem.endColumn));
			view.cursorChanged();
		}));
	}

	function hasDocument(context:CommandContext):Bool
		return context.activeView() != null && context.activeView().getDocument() != null;

	function activeDocument():Null<Document> {
		var view = context.activeView();
		return view == null ? null : view.getDocument();
	}

	function activeSelection():Null<editor.BufferSelection> {
		var view = context.activeView();
		return view == null ? null : view.getSelection();
	}
}
