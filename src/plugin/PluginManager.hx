package plugin;

import command.CommandContext;
import command.CommandRegistry;
import command.Keymap;
import syntax.SyntaxRegistry;
import config.Settings;
import jobs.JobScheduler;
import completion.CompletionRegistry;
import process.ProcessManager;

class PluginManager {
	final commands:CommandRegistry;
	final keymap:Keymap;
	final commandContext:CommandContext;
	final syntaxes:SyntaxRegistry;
	final completions:CompletionRegistry;
	final panels:PluginPanelRegistry;
	final decorations:PluginDecorationRegistry;
	final statusItems:PluginStatusRegistry;
	final jobs:JobScheduler;
	final processes:ProcessManager;
	final settings:Void->Settings;
	final reportDiagnostic:String->Void;
	var ownedSourceLoader:Null<SourcePluginLoader>;
	final entries:Array<PluginEntry> = [];
	final reportedDiagnostics:Map<String, String> = [];

	public function new(commands:CommandRegistry, keymap:Keymap, commandContext:CommandContext, syntaxes:SyntaxRegistry,
			completions:CompletionRegistry, panels:PluginPanelRegistry, decorations:PluginDecorationRegistry,
			statusItems:PluginStatusRegistry, jobs:JobScheduler, processes:ProcessManager, settings:Void->Settings, ?reportDiagnostic:String->Void, dynamicHost:Bool = true, ?sourceLoader:SourcePluginLoader) {
		this.commands = commands;
		this.keymap = keymap;
		this.commandContext = commandContext;
		this.syntaxes = syntaxes;
		this.completions = completions;
		this.panels = panels;
		this.decorations = decorations;
		this.statusItems = statusItems;
		this.jobs = jobs;
		this.processes = processes;
		this.settings = settings;
		this.reportDiagnostic = reportDiagnostic == null ? function(message:String) {} : reportDiagnostic;
		var loader = sourceLoader;
		#if !wasm
		if (dynamicHost && loader == null) loader = new NativeSourcePluginLoader();
		#end
		if (dynamicHost && loader != null) {
			loader.initialize();
			ownedSourceLoader = loader;
		}
	}

	public function load(plugin:Plugin):Bool {
		var id = plugin.id();
		if (!validId(id))
			throw 'invalid plugin id "$id"';
		if (indexOf(id) >= 0)
			return false;
		var context = createContext(id);
		try {
			plugin.activate(context);
		} catch (error:Dynamic) {
			context.dispose();
			throw error;
		}
		entries.push(new PluginEntry(plugin, context));
		reportedDiagnostics.remove(id);
		return true;
	}

	public function unload(id:String):Bool {
		var index = indexOf(id);
		if (index < 0)
			return false;
		var entry = entries[index], failure:Null<String> = null;
		try disable(id) catch (error:Dynamic) failure = Std.string(error);
		entries.remove(entry);
		reportedDiagnostics.remove(id);
		entry.plugin.dispose();
		if (failure != null) throw failure;
		return true;
	}

	public function disable(id:String):Bool {
		var entry = entry(id);
		if (entry == null || entry.context == null) return false;
		var context:PluginContext = entry.context, failure:Null<String> = null;
		try entry.plugin.deactivate(context) catch (error:Dynamic) failure = Std.string(error);
		context.dispose();
		entry.context = null;
		if (failure != null) throw failure;
		return true;
	}

	public function enable(id:String):Bool {
		var entry = entry(id);
		if (entry == null || entry.context != null) return false;
		var context = createContext(id);
		try {
			entry.plugin.activate(context);
		} catch (error:Dynamic) {
			context.dispose();
			throw error;
		}
		entry.context = context;
		return true;
	}

	public function reload(id:String):Bool {
		var entry = entry(id);
		if (entry == null || entry.context == null) return false;
		if (entry.plugin.requestRefresh()) return true;
		if (entry.plugin.refresh()) {
			recordDiagnostic(entry.plugin);
			return true;
		}
		recordDiagnostic(entry.plugin);
		if (entry.plugin.diagnostic() != null) return false;
		disable(id);
		return enable(id);
	}

	public function update(now:Float):Void {
		for (entry in entries) {
			if (entry.context == null) continue;
			entry.plugin.update(now);
			recordDiagnostic(entry.plugin);
		}
	}

	public function diagnostics():Array<String> {
		var values:Array<String> = [];
		for (id => message in reportedDiagnostics) values.push('$id: $message');
		values.sort(Reflect.compare);
		return values;
	}

	public function shutdown():Void {
		var index = entries.length, failed = false, failure = "";
		while (index > 0) {
			index--;
			try {
				unload(entries[index].plugin.id());
			} catch (error:Dynamic) {
				if (!failed) {
					failed = true;
					failure = Std.string(error);
				}
			}
		}
		var loader = ownedSourceLoader;
		ownedSourceLoader = null;
		if (loader != null) loader.shutdown();
		if (failed)
			throw failure;
	}

	public function isLoaded(id:String):Bool {
		var found = entry(id);
		return found != null && found.context != null;
	}

	public function enabledIds():Array<String>
		return ids(true);

	public function disabledIds():Array<String>
		return ids(false);

	public function count():Int
		return entries.length;

	function indexOf(id:String):Int {
		for (index in 0...entries.length)
			if (entries[index].plugin.id() == id)
				return index;
		return -1;
	}

	function entry(id:String):Null<PluginEntry> {
		var index = indexOf(id);
		return index < 0 ? null : entries[index];
	}

	function createContext(id:String):PluginContext
		return new PluginContext(id, commands, keymap, commandContext, syntaxes, completions, panels, decorations, statusItems, jobs, processes, settings);

	function ids(enabled:Bool):Array<String> {
		var values:Array<String> = [];
		for (entry in entries)
			if ((entry.context != null) == enabled) values.push(entry.plugin.id());
		values.sort(Reflect.compare);
		return values;
	}

	function recordDiagnostic(plugin:Plugin):Void {
		var id = plugin.id(), diagnostic = plugin.diagnostic();
		if (diagnostic == null) {
			reportedDiagnostics.remove(id);
		} else if (!reportedDiagnostics.exists(id) || reportedDiagnostics.get(id) != diagnostic) {
			reportedDiagnostics.set(id, diagnostic);
			reportDiagnostic('Plugin "$id": $diagnostic');
		}
	}

	static function validId(id:String):Bool
		return id.length > 0 && id.indexOf(":") < 0 && id.indexOf(" ") < 0;
}
