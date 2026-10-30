package app;

import commandview.CommandView;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityRole;
import ui.QuickPickView;

class QuickPickerTestMain {
	static function check(value:Bool, message:String):Void if (!value) throw message;
	static function result(root:RenderNode, label:String):RenderNode {
		var found:RenderNode = null;
		root.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.CollectionItem && node.semantics.label == label) found = node;
		});
		if (found == null) throw "Missing result " + label;
		return found;
	}
	static function descendantText(root:RenderNode, value:String):RenderNode {
		var found:RenderNode = null;
		root.walk(function(node) { if (node.layout.text == value) found = node; });
		if (found == null) throw "Missing text " + value;
		return found;
	}
	static function commandHover(fonts:FontCollection):Void {
		var ui = new UiContext(null, fonts);
		var model = new CommandView();
		var provider = new CommandViewProvider("> ", [
			new CommandViewEntry("First command", "", "first", "Ctrl+A"),
			new CommandViewEntry("Second command", "", "second", "Ctrl+Shift+B")
		], function(_) {}, function(_, _, _) {});
		model.open(provider);
		var changes = 0;
		var picker = new QuickPickView(model, provider, function() {}, function() changes++, function(_) {});
		var frame = new LayoutFrame(800, 600);
		var root = ui.submit(picker, frame);
		root = ui.submit(picker, frame);
		var row = result(root, "Second command");
		var bounds = row.globalBounds();
		ui.pointerMove(bounds.x + 10, bounds.y + bounds.height / 2);
		root = ui.submit(picker, frame);
		var plus = descendantText(result(root, "Second command"), "+").globalBounds();
		ui.pointerMove(plus.x + plus.width / 2, plus.y + plus.height / 2);
		root = ui.submit(picker, frame);
		var settledChanges = changes;
		for (_ in 0...8) root = ui.submit(picker, frame);
		check(changes == settledChanges, "Stationary shortcut hover kept rebuilding the picker");
		var label = descendantText(result(root, "Second command"), "Shift").globalBounds();
		ui.pointerMove(label.x + label.width / 2, label.y + label.height / 2);
		root = ui.submit(picker, frame);
		check(changes == settledChanges, "Moving between shortcut children changed row hover");
		var gearFound = false;
		result(root, "Second command").walk(function(node) {
			if (node.semantics != null && node.semantics.label == "Configure Keybinding") gearFound = true;
		});
		check(gearFound, "Hovering shortcut children hid the row action");
		ui.pointerMove(0, 590);
		root = ui.submit(picker, frame);
		gearFound = false;
		result(root, "Second command").walk(function(node) {
			if (node.semantics != null && node.semantics.label == "Configure Keybinding") gearFound = true;
		});
		check(!gearFound, "Leaving the command row retained its hover action");
		ui.dispose();
	}
	static function main():Int {
		var fonts = FontCollection.create(); fonts.addSystemFallbacks();
		var ui = new UiContext(null, fonts);
		var model = new CommandView();
		var entries:Array<CommandViewEntry> = [];
		for (index in 0...50000) entries.push(new CommandViewEntry("folder/file-" + index + ".hx", "", Std.string(index)));
		var accepted = "";
		var provider = new CommandViewProvider("", entries, function(_) {}, function(entry, _, _) {
			accepted = entry == null ? "" : entry.value;
			model.close();
		});
		model.open(provider);
		var picker = new QuickPickView(model, provider, function() model.close(true), function() {});
		var frame = new LayoutFrame(800, 600);
		var root = ui.submit(picker, frame);
		var rows = 0;
		root.walk(function(node) { if (node.semantics != null && node.semantics.role == AccessibilityRole.CollectionItem) rows++; });
		check(rows > 1 && rows < 40, "File picker did not virtualize its results");
		ui.key(UiEventKind.KeyDown, UiKey.Up);
		root = ui.submit(picker, frame);
		root = ui.submit(picker, frame);
		check(model.selected == 49999, "File picker navigation did not reach the last result");
		var bounds = result(root, "folder/file-49999.hx").globalBounds();
		check(bounds.y >= 40 && bounds.y + bounds.height <= 430, "File picker did not reveal selection");
		ui.text(UiEventKind.TextInput, "file-49999");
		root = ui.submit(picker, new LayoutFrame(420, 300));
		root = ui.submit(picker, new LayoutFrame(420, 300));
		check(model.query == "file-49999" && model.results.length == 1, "File picker did not filter from its focused input");
		bounds = result(root, "folder/file-49999.hx").globalBounds();
		ui.pointerDown(bounds.x + 30, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + 30, bounds.y + bounds.height / 2, 0);
		check(accepted == "49999" && !model.active, "Filtered file activation did not reach the app model");
		ui.dispose();
		commandHover(fonts);
		fonts.dispose();
		Sys.println("PASS: Exosuit picker virtualization, query/navigation, resize/reveal, activation and stable shortcut hover");
		return 0;
	}
}
