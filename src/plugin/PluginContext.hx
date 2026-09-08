package plugin;

import command.CommandContext;
import command.CommandRegistry;
import command.Keymap;
import syntax.SyntaxDefinition;
import syntax.SyntaxRegistry;
import config.Settings;
import jobs.JobScheduler;
import completion.CompletionProvider;
import completion.CompletionRegistry;
import process.ProcessManager;

class PluginContext {
	public final id:String;
	public final editor:CommandContext;
	public final api:EditorApi;
	final commands:CommandRegistry;
	final keymap:Keymap;
	final syntaxes:SyntaxRegistry;
	final completions:CompletionRegistry;
	final commandNames:Array<String> = [];
	final bindings:Array<PluginBinding> = [];
	final owned:Array<Void->Void> = [];
	var active:Bool = true;

	public function new(id:String, commands:CommandRegistry, keymap:Keymap, editor:CommandContext, syntaxes:SyntaxRegistry,
			completions:CompletionRegistry, panels:PluginPanelRegistry, decorations:PluginDecorationRegistry,
			statusItems:PluginStatusRegistry, jobs:JobScheduler, processes:ProcessManager, settings:Void->Settings) {
		this.id = id;
		this.editor = editor;
		this.commands = commands;
		this.keymap = keymap;
		this.syntaxes = syntaxes;
		this.completions = completions;
		api = new EditorApi(id, editor, panels, decorations, statusItems, jobs, processes, settings, own);
	}

	public function addCompletionProvider(provider:CompletionProvider):Void {
		requireActive();
		completions.add(id, provider);
		own(function() {
			completions.remove(id, provider);
		});
	}

	public function addSyntax(definition:SyntaxDefinition):Void {
		requireActive();
		syntaxes.add(definition, id);
	}

	public function addCommand(name:String, perform:CommandContext->Void, ?predicate:CommandContext->Bool, ?description:String):Void {
		requireActive();
		if (!StringTools.startsWith(name, id + ":"))
			throw 'plugin "$id" command must use the "$id:" namespace';
		if (commands.contains(name))
			throw 'command "$name" is already registered';
		commands.add(name, perform, predicate, description);
		commandNames.push(name);
	}

	public function bind(key:Int, modifiers:Int, names:Array<String>):Void {
		requireActive();
		for (name in names) {
			if (commandNames.indexOf(name) < 0)
				throw 'plugin "$id" cannot bind command it does not own: "$name"';
			keymap.add(key, modifiers, [name]);
			bindings.push(new PluginBinding(key, modifiers, name));
		}
	}

	public function dispose():Void {
		if (!active) return;
		active = false;
		var resourceIndex = owned.length;
		while (resourceIndex > 0) {
			resourceIndex--;
			owned[resourceIndex]();
		}
		var index = bindings.length;
		while (index > 0) {
			index--;
			var binding = bindings[index];
			keymap.unbind(binding.key, binding.modifiers, binding.command);
		}
		for (name in commandNames) {
			keymap.removeCommand(name);
			commands.remove(name);
		}
		syntaxes.removeOwner(id);
		completions.removeOwner(id);
	}

	/** Starts a fresh ownership transaction while preserving this context identity. */
	public function reset():Void {
		if (active) throw 'plugin "$id" context is still active';
		commandNames.splice(0, commandNames.length);
		bindings.splice(0, bindings.length);
		owned.splice(0, owned.length);
		active = true;
	}

	public function own(dispose:Void->Void):Void {
		requireActive();
		owned.push(dispose);
	}

	function requireActive():Void {
		if (!active) throw 'plugin "$id" context is no longer active';
	}
}
