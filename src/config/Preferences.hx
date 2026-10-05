package config;

import haxeon.ui.settings.SettingsStore;
import haxeon.ui.settings.SettingsRegistry;
import sys.FileSystem;

/** Application adapter: UIKit owns validation, storage and change notifications. */
class Preferences {
	public var current(default, null):Settings;
	public var store(default, null):SettingsStore;
	public final registry:SettingsRegistry;
	public final diagnostics:Array<String> = [];
	final listeners:Array<Settings->Void> = [];
	final parent:Null<Preferences>;
	final path:Null<String>;
	var releaseStore:Null<Void->Void>;
	var signature:String = "";
	var nextPoll:Float = 0;
	var previousParent:Null<Settings>;

	public function new(?userPath:String, ?projectPath:String, ?parent:Preferences) {
		this.parent = parent;
		path = projectPath == null ? userPath : projectPath;
		registry = PreferencesRegistry.create(parent != null);
		current = parent == null ? new Settings() : parent.current.copy();
		store = new SettingsStore(registry, path);
		attach();
		refresh();
		signature = diskSignature();
	}

	public function forProject(path:String):Preferences
		return new Preferences(null, path, this);

	public function subscribe(listener:Settings->Void):Void->Void {
		listeners.push(listener);
		listener(current);
		var active = true;
		return function() {
			if (!active) return;
			active = false;
			listeners.remove(listener);
		};
	}

	public function unsubscribe(listener:Settings->Void):Void listeners.remove(listener);

	/** Bounded polling for external JSON edits; UI edits apply immediately. */
	public function reload(force:Bool = false):Bool {
		if (store.lastError != null && diagnostics.indexOf(store.lastError) < 0) diagnostics.push(store.lastError);
		var parentChanged = parent != null && parent.current != previousParent && refresh();
		var now = Sys.time();
		if (!force && now < nextPoll) return parentChanged;
		nextPoll = now + 0.5;
		var next = diskSignature();
		if (!force && next == signature) return parentChanged;
		var candidate = new SettingsStore(registry, path);
		if (candidate.lastError != null) {
			diagnostics.resize(0); diagnostics.push(candidate.lastError);
			signature = next;
			return false;
		}
		try {
			var candidateValue = PreferencesRegistry.snapshot(candidate, parent == null ? null : parent.current);
			if (!force && haxe.Json.stringify(candidateValue) == haxe.Json.stringify(current)) {
				signature = next;
				diagnostics.resize(0);
				return parentChanged;
			}
		}
		catch (error:Dynamic) {
			diagnostics.resize(0); diagnostics.push(Std.string(error)); signature = next; return false;
		}
		var previousRelease = releaseStore;
		if (previousRelease != null) previousRelease();
		store = candidate;
		attach();
		signature = next;
		return refresh();
	}

	function attach():Void {
		releaseStore = store.onChanged("", function(_) { refresh(); });
	}

	function refresh():Bool {
		diagnostics.resize(0);
		if (store.lastError != null) diagnostics.push(store.lastError);
		try {
			var next = PreferencesRegistry.snapshot(store, parent == null ? null : parent.current);
			previousParent = parent == null ? null : parent.current;
			if (haxe.Json.stringify(next) == haxe.Json.stringify(current)) return false;
			current = next;
			for (listener in listeners.copy()) if (listeners.indexOf(listener) >= 0) listener(current);
			return true;
		} catch (error:Dynamic) { diagnostics.push(Std.string(error)); return false; }
	}

	function diskSignature():String {
		if (path == null) return "memory";
		try {
			if (!FileSystem.exists(path)) return "missing";
			return sys.io.File.getContent(path);
		} catch (error:Dynamic) { return Std.string(error); }
	}
}
