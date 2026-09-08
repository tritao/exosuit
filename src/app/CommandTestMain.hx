package app;

import core.Application;
import platform.Native;
import platform.Platform;
import renderer.Renderer;
import commandview.CommandView;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;

class CommandTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		Platform.startHeadless();
		var window = Native.window_create("command-test", 320, 200), renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			application = new Application(renderer, 320, 200), registry = application.commands, keymap = application.keymap,
			context = application.context, performed = 0;
		registry.add("test:disabled", function(context) { performed = 1; }, context -> false);
		registry.add("test:fallback", function(context) { performed = 2; }, null, "Run the fallback command");
		var available = registry.availableCommands(context);
		var fallback = [for (command in available) if (command.name == "test:fallback") command][0];
		require(fallback.description == "Run the fallback command", "command description was not retained");
		var disabled = new command.Command("test:human-readable", function(context) {});
		require(disabled.description == "Test: Human Readable", "command description fallback was not human readable");
		application.workbench.openCommandView();
		var fallbackEntry = [for (entry in application.root.commandView.results) if (entry.value == "test:fallback") entry][0];
		require(fallbackEntry.label == "Run the fallback command" && fallbackEntry.searchText.indexOf("test:fallback") >= 0,
			"command palette did not show the human-readable description or retain the stable command ID for search");
		var paletteEntry = [for (entry in application.root.commandView.results) if (entry.value == "commands:open") entry][0];
		require(paletteEntry.trailing == "Ctrl+Shift+P", "command palette did not show the effective keyboard shortcut");
		application.root.commandView.close();
		application.workbench.openCommandView();
		application.root.commandView.setQuery("fallback");
		application.root.commandView.keyPressed(Platform.KEY_ENTER, 0);
		application.workbench.openCommandView();
		var recentEntry = [for (entry in application.root.commandView.results) if (entry.value == "test:fallback") entry][0];
		require(recentEntry.section == "Recently Used", "executed palette command was not promoted to the recent section");
		application.root.commandView.close();
		keymap.addDirect(100, 1, ["test:disabled", "test:fallback"]);
		require(keymap.onKeyPressed(100, 1, context) && performed == 2, "predicate fallback dispatch failed");
		registry.add("test:override", function(context) { performed = 3; });
		keymap.add(100, 1, ["test:override"]);
		performed = 0;
		require(keymap.onKeyPressed(100, 1, context) && performed == 3, "new binding did not take precedence");
		var ordered = keymap.commandsFor(100, 1);
		require(ordered.length == 3 && ordered[0] == "test:override", "binding precedence was not retained");
		registry.add("test:override", function(context) { performed = 4; });
		performed = 0;
		require(keymap.onKeyPressed(100, 1, context) && performed == 4, "duplicate command registration was not replaced");
		keymap.unbind(100, 1, "test:override");
		performed = 0;
		require(keymap.onKeyPressed(100, 1, context) && performed == 2, "command unbinding failed");
		keymap.addDirect(100, 1, ["test:disabled"]);
		require(!keymap.onKeyPressed(100, 1, context), "invalid command consumed key binding");
		var commandView = new CommandView(), accepted = "", entries = [
			new CommandViewEntry("src/foo.hx", "path", "path"),
			new CommandViewEntry("food", "prefix", "prefix"),
			new CommandViewEntry("foo", "exact", "exact")
		];
		commandView.open(new CommandViewProvider("> ", entries, function(query) {}, function(entry, query, backwards) {
			accepted = query;
		}));
		commandView.setComposition("日😀", 1, 1);
		require(commandView.query == "" && commandView.compositionText == "日😀"
			&& commandView.textInputArea(renderer, 320).height == 24,
			"command composition mutated its query or lacked candidate placement");
		renderer.begin();
		commandView.draw(renderer, application.theme, 320, 200);
		renderer.present();
		commandView.textInput("f");
		require(commandView.compositionText == "", "committed command input retained preedit text");
		commandView.keyPressed(Platform.KEY_DOWN, 0);
		var preserved = commandView.results[commandView.selected].value;
		commandView.textInput("o");
		require(commandView.results[commandView.selected].value == preserved, "provider refresh did not preserve the selected result");
		commandView.textInput("o");
		require(commandView.results.length == 3 && commandView.results[0].value == "exact",
			"exact command input match did not outrank prefix and path matches");
		commandView.keyPressed(Platform.KEY_LEFT, 0);
		commandView.keyPressed(Platform.KEY_BACKSPACE, 0);
		require(commandView.query == "fo", "command input caret editing failed");
		commandView.keyPressed(Platform.KEY_Z, Platform.MOD_CTRL);
		require(commandView.query == "foo", "command input undo failed");
		while (commandView.results[commandView.selected].value != "exact") commandView.keyPressed(Platform.KEY_UP, 0);
		commandView.keyPressed(Platform.KEY_TAB, 0);
		require(commandView.query == "foo", "command completion did not use the selected exact entry");
		commandView.keyPressed(Platform.KEY_ENTER, 0);
		require(accepted == "foo", "command input acceptance failed");
		commandView.close();
		commandView.open(new CommandViewProvider("", [], function(query) {}, function(entry, query, backwards) {}));
		commandView.keyPressed(Platform.KEY_UP, Platform.MOD_CTRL);
		require(commandView.query == "foo", "command input history did not restore the accepted query");
		commandView.setQuery("A😀B");
		commandView.keyPressed(Platform.KEY_LEFT, 0);
		commandView.keyPressed(Platform.KEY_BACKSPACE, 0);
		require(commandView.query == "AB", "command input split a Unicode surrogate pair");
		commandView.setQuery("a query that cannot possibly match 😀");
		require(commandView.results.length == 0, "long no-match command query retained stale results");
		commandView.keyPressed(Platform.KEY_ESCAPE, 0);
		require(!commandView.active, "command input cancellation failed");
		var scrollingEntries:Array<CommandViewEntry> = [];
		for (index in 0...12) scrollingEntries.push(new CommandViewEntry("command " + index, "", Std.string(index)));
		commandView.open(new CommandViewProvider("> ", scrollingEntries, function(query) {}, function(entry, query, backwards) {}));
		for (index in 0...10) commandView.keyPressed(Platform.KEY_DOWN, 0);
		require(commandView.selected == 10 && commandView.visibleStart(10) == 1,
			"command results did not scroll to keep a downward selection visible");
		commandView.keyPressed(Platform.KEY_DOWN, 0);
		commandView.keyPressed(Platform.KEY_DOWN, 0);
		require(commandView.selected == 0 && commandView.visibleStart(10) == 0,
			"wrapped command selection did not restore the top result window");
		var clicked = "";
		commandView.close();
		commandView.open(new CommandViewProvider("> ", scrollingEntries, function(query) {}, function(entry, query, backwards) {
			clicked = entry == null ? "" : entry.value;
		}));
		commandView.mouseMove(100, 89, 320, 200);
		require(commandView.selected == 1, "command pointer hover did not select its result row");
		commandView.wheel(-100);
		require(commandView.selected == 2, "command mouse wheel did not move the selection down");
		require(commandView.mouseDown(Platform.MOUSE_LEFT, 100, 117, 320, 200) && clicked == "2",
			"command pointer click did not accept its result row");
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy command test window");
		Native.shutdown();
		Sys.println("PASS: command predicates, replacement, binding precedence, and conflicts");
		return 0;
	}
}
