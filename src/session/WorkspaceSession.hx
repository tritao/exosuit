package session;

import core.Application;
import sys.FileSystem;
import sys.io.File;
import editor.Document;
import recovery.RecoverySnapshot;
import recovery.RecoveryStore;

class WorkspaceSession {
	public static inline final VERSION = 3;
	public final projects:Array<String> = [];
	public final documents:Array<String> = [];
	public var activeDocument:String = "";
	public final layout:Array<String> = [];
	public final expanded:Array<String> = [];

	public function new() {}

	public static function capture(application:Application):WorkspaceSession {
		var result = new WorkspaceSession();
		for (project in application.workspace.projects) {
			if (safeValue(project.root)) result.projects.push(project.root);
			for (path in project.expandedPaths()) if (safeValue(path)) result.expanded.push(path);
		}
		for (document in application.documents.documents)
			if (document.hasBackingPath() && FileSystem.exists(document.requirePath()) && !FileSystem.isDirectory(document.requirePath()))
				result.documents.push(document.requirePath());
		var view = application.context.activeView();
		if (view != null) {
			var active = view.getDocument();
			if (active != null && active.hasBackingPath()) result.activeDocument = active.requirePath();
		}
		for (line in application.root.sessionLines()) result.layout.push(line);
		return result;
	}

	public function restore(application:Application, ?recovery:RecoveryStore):Void {
		for (root in projects)
			if (FileSystem.exists(root) && FileSystem.isDirectory(root)) application.openArgument(root);
		for (project in application.workspace.projects) project.restoreExpanded(expanded);
		if (layout.length > 0) {
			var snapshots:Map<String, RecoverySnapshot> = [], restored:Map<String, Document> = [];
			if (recovery != null)
				for (snapshot in recovery.load()) snapshots.set(snapshot.id, snapshot);
			application.root.restoreSessionLines(layout, function(kind, reference) {
				var cached = restored.get(kind + ":" + reference);
				if (cached != null) return cached;
				var document:Null<Document> = null;
				if (kind == "P") {
					if (FileSystem.exists(reference) && !FileSystem.isDirectory(reference))
						try document = application.documents.open(reference) catch (error:Dynamic) {}
				} else if (kind == "R") {
					var snapshot = snapshots.get(reference);
					if (snapshot != null && (snapshot.path == null || FileSystem.exists(snapshot.path) && !FileSystem.isDirectory(snapshot.path)))
						document = application.documents.restoreRecovered(snapshot.id, snapshot.title, snapshot.path, snapshot.text);
				}
				if (document != null) restored.set(kind + ":" + reference, document);
				return document;
			});
		} else {
			for (path in documents)
				if (FileSystem.exists(path) && !FileSystem.isDirectory(path)) application.open(path);
			if (activeDocument.length > 0 && FileSystem.exists(activeDocument) && !FileSystem.isDirectory(activeDocument)) application.open(activeDocument);
		}
		application.root.showProjectSidebar();
	}

	public function encode():String {
		var output = "version=" + VERSION + "\n";
		for (project in projects) output += "project=" + clean(project) + "\n";
		for (document in documents) output += "document=" + clean(document) + "\n";
		output += "active=" + clean(activeDocument) + "\n";
		for (line in layout) output += "layout=" + clean(line) + "\n";
		for (path in expanded) output += "expanded=" + clean(path) + "\n";
		return output;
	}

	public static function decode(content:String):WorkspaceSession {
		var result = new WorkspaceSession(), version = 0;
		for (raw in content.split("\n")) {
			var line = StringTools.endsWith(raw, "\r") ? raw.substring(0, raw.length - 1) : raw, separator = line.indexOf("=");
			if (line.length == 0 || separator < 0) continue;
			var key = line.substring(0, separator), value = line.substring(separator + 1);
			if (key == "version") version = Std.parseInt(value);
			else if (key == "project" && value.length > 0) result.projects.push(value);
			else if (key == "document" && value.length > 0) result.documents.push(value);
			else if (key == "active") result.activeDocument = value;
			else if (key == "layout" && validLayout(value)) result.layout.push(value);
			else if (key == "expanded" && value.length > 0) result.expanded.push(value);
		}
		if (version != VERSION) throw "unsupported workspace session version";
		return result;
	}

	public static function load(path:String):Null<WorkspaceSession> {
		if (path.length == 0 || !FileSystem.exists(path) || FileSystem.isDirectory(path)) return null;
		try {
			return decode(File.getContent(path));
		} catch (error:Dynamic) {
			quarantine(path);
			return null;
		}
	}

	static function quarantine(path:String):Void {
		var candidate = path + ".incompatible", suffix = 1;
		while (FileSystem.exists(candidate)) candidate = path + ".incompatible-" + suffix++;
		try FileSystem.rename(path, candidate) catch (error:Dynamic) {}
	}

	public function save(path:String):Bool {
		if (path.length == 0 || !ensureParent(path)) return false;
		try {
			sys.io.AtomicFile.write(path, encode());
			return true;
		} catch (error:Dynamic) {
			return false;
		}
	}

	static function clean(value:String):String {
		if (value.indexOf("\n") >= 0 || value.indexOf("\r") >= 0) throw "session value contains a newline";
		return value;
	}

	static function safeValue(value:String):Bool
		return value.indexOf("\n") < 0 && value.indexOf("\r") < 0;

	static function validLayout(value:String):Bool {
		var fields = value.split("\t");
		if (fields.length == 2 && fields[0] == "A") return validRoute(fields[1]);
		if (fields.length == 4 && fields[0] == "S")
			return validRoute(fields[1]) && (fields[2] == "H" || fields[2] == "V") && nonNegativeInteger(fields[3]);
		if (fields.length == 9 && fields[0] == "T") {
			if (!validRoute(fields[1]) || (fields[2] != "0" && fields[2] != "1") || (fields[7] != "P" && fields[7] != "R")
				|| fields[8].length == 0) return false;
			for (index in 3...7) if (!nonNegativeInteger(fields[index])) return false;
			return true;
		}
		return false;
	}

	static function validRoute(value:String):Bool {
		if (value.length > 64) return false;
		for (index in 0...value.length) if (value.charAt(index) != "0" && value.charAt(index) != "1") return false;
		return true;
	}

	static function nonNegativeInteger(value:String):Bool {
		var parsed = Std.parseInt(value);
		return parsed >= 0 && Std.string(parsed) == value;
	}

	static function ensureParent(path:String):Bool {
		var separator = path.lastIndexOf("/");
		if (separator <= 0) return true;
		var parent = path.substring(0, separator);
		if (FileSystem.exists(parent)) return FileSystem.isDirectory(parent);
		if (!ensureParent(parent)) return false;
		FileSystem.createDirectory(parent);
		return FileSystem.exists(parent) && FileSystem.isDirectory(parent);
	}
}
