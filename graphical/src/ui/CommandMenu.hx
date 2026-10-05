package ui;

import command.CommandContext;
import command.CommandRegistry;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.overlays.Menu;
import haxeon.ui.widgets.overlays.MenuItem;

/** A contextual command surface whose target and predicates stay live. */
class CommandMenu implements View {
	final registry:CommandRegistry;
	final commandContext:CommandContext;
	final entries:Array<CommandMenuEntry>;
	final targetIsCurrent:Void->Bool;
	final dismiss:Void->Void;
	final x:Float;
	final y:Float;
	final customItems:Null<Array<MenuItem>>;

	public function new(registry:CommandRegistry, commandContext:CommandContext,
			entries:Array<CommandMenuEntry>, x:Float, y:Float,
			targetIsCurrent:Void->Bool, dismiss:Void->Void, ?customItems:Array<MenuItem>) {
		this.customItems = customItems;
		this.registry = registry;
		this.commandContext = commandContext;
		this.entries = entries.copy();
		this.x = x;
		this.y = y;
		this.targetIsCurrent = targetIsCurrent;
		this.dismiss = dismiss;
	}

	public function isCurrent():Bool return targetIsCurrent();

	public function build(context:BuildContext):RenderNode {
		var items:Array<MenuItem> = customItems == null ? [] : customItems.copy();
		var targetValid = isCurrent();
		for (entry in entries) {
			if (!registry.contains(entry.command)) continue;
			items.push(new MenuItem(entry.command, entry.label, function() {
				dismiss();
				if (isCurrent()) registry.perform(entry.command, commandContext);
			}, targetValid && registry.isValid(entry.command, commandContext)));
		}
		return new Menu("command-context-menu", items, x, y, dismiss).build(context);
	}
}
