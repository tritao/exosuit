package plugin;

import command.CommandContext;
import config.Settings;
import jobs.JobHandle;
import jobs.JobScheduler;
import jobs.JobTask;
import process.OwnedProcess;
import process.ProcessManager;

/** Versioned host capabilities available for the lifetime of one plugin context. */
class EditorApi {
	public static inline final VERSION = 2;
	public final owner:String;
	final editor:CommandContext;
	final panels:PluginPanelRegistry;
	final decorations:PluginDecorationRegistry;
	final statusItems:PluginStatusRegistry;
	final jobs:JobScheduler;
	final processes:ProcessManager;
	final settings:Void->Settings;
	final own:(Void->Void)->Void;

	public function new(owner:String, editor:CommandContext, panels:PluginPanelRegistry, decorations:PluginDecorationRegistry,
			statusItems:PluginStatusRegistry, jobs:JobScheduler, processes:ProcessManager, settings:Void->Settings,
			own:(Void->Void)->Void) {
		this.owner = owner;
		this.editor = editor;
		this.panels = panels;
		this.decorations = decorations;
		this.statusItems = statusItems;
		this.jobs = jobs;
		this.processes = processes;
		this.settings = settings;
		this.own = own;
	}

	public function activeDocumentText():String
		return editor.requireDocument().buffer.text;

	/** Replaces every active selection as one document transaction. */
	public function replaceSelections(text:String):Bool {
		var view = editor.requireView(), document = editor.requireDocument(), selection = view.getSelection();
		if (selection == null) return false;
		return document.buffer.replaceSelections(selection, [text]);
	}

	public function configuration():Settings
		return settings().copy();

	public function addPanel(id:String, title:String, text:String):PluginPanel {
		var panel = panels.add(owner, id, title, text);
		ownSafely(function() {
			panels.remove(panel);
		});
		return panel;
	}

	public function addDecoration(id:String, line:Int, startColumn:Int, endColumn:Int, color:Int):PluginDecoration {
		var decoration = decorations.add(owner, id, editor.requireDocument(), line, startColumn, endColumn, color);
		ownSafely(function() {
			decorations.remove(decoration);
		});
		return decoration;
	}

	public function addStatusItem(id:String, text:String, priority:Int = 0):PluginStatusItem {
		var item = statusItems.add(owner, id, text, priority);
		ownSafely(function() {
			statusItems.remove(item);
		});
		return item;
	}

	public function setStatusItemText(id:String, text:String):Bool {
		var item = statusItems.find(owner, id);
		if (item == null) return false;
		if (item.text != text) { item.text = text; statusItems.changed(); }
		return true;
	}

	public function setPanelText(id:String, text:String):Bool {
		var panel = panels.find(owner, id);
		if (panel == null) return false;
		if (panel.text != text) { panel.text = text; panels.changed(); }
		return true;
	}

	/** Observes the active document at registration time until plugin unload. */
	public function onDocumentChanged(listener:PluginDocumentEvent->Void):Void {
		var document = editor.requireDocument(), subscription = document.buffer.subscribe(change -> listener(new PluginDocumentEvent(document, change)));
		ownSafely(subscription.release);
	}

	public function schedule(task:JobTask):JobHandle {
		var handle = jobs.schedule(task);
		ownSafely(function() {
			jobs.cancel(handle);
		});
		return handle;
	}

	public function startProcess(executable:String, arguments:Array<String>, cwd:String = "", ?environment:Map<String, String>):OwnedProcess {
		var process = processes.start(executable, arguments, cwd, environment);
		ownSafely(function() {
			processes.release(process);
		});
		return process;
	}

	function ownSafely(dispose:Void->Void):Void {
		try {
			own(dispose);
		} catch (error:Dynamic) {
			dispose();
			throw error;
		}
	}
}
