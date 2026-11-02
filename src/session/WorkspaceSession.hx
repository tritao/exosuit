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
	public var savedWorkspace:Null<workspace.SavedWorkspace>;
	public var workspaceFile:String = "";
	public var groupId:String = "";
	public var groupLabel:String = "";
	public var groupDirectory:String = "";
	/** The machine id the saved contexts are keyed by; empty before the catalog ever named one. */
	public var machineId:String = "";
	/** Recently active contexts, newest first, so the quick switch knows cold ones after a restart. */
	public final recent:Array<workspace.ContextInfo> = [];
	public final layout:Array<String> = [];
	public final expanded:Array<String> = [];
	public final scmCommitDrafts:Map<String, String> = [];
	/** Layout lines of every context this window knows, the focused one included, by context key. Not in session.conf; see ContextSnapshotStore. */
	public final contexts:Map<String, Array<String>> = [];
	public var activeKey:String = "";

	public function new() {}

	static function contextLine(line:String):Bool return StringTools.startsWith(line, "Z\tcontext\t");

	public static function capture(application:Application):WorkspaceSession {
		var result = new WorkspaceSession();
		if (application.savedWorkspaces.current != null) result.savedWorkspace = application.savedWorkspaces.current.copy();
		result.workspaceFile = application.savedWorkspaces.path;
		if (application.activeContext.kind == workspace.ContextKind.Group) {
			result.groupId = application.activeContext.id; result.groupLabel = application.activeContext.label;
			result.groupDirectory = application.activeContext.cwd;
		}
		for (info in application.activeContext.recent) result.recent.push(info);
		if (application.activeContext.machineId != workspace.ContextKey.DEFAULT_MACHINE) result.machineId = application.activeContext.machineId;
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
		result.takeLayout(application.root.sessionLines());
		for (repositoryId in application.scmCommitDrafts.keys()) {
			var message = application.scmCommitDrafts.get(repositoryId);
			if (repositoryId != null && repositoryId.length > 0 && message != null)
				result.scmCommitDrafts.set(repositoryId, message);
		}
		return result;
	}

	/**
		Splits the host's session lines: per-context tabs (the focused context's included) go to `contexts`, to be
		written one file each; `layout` keeps the window chrome and the focused context, which is session.conf.
	**/
	public function takeLayout(lines:Array<String>):Void {
		var split = ContextLayoutStore.read(lines);
		if (split.activeKey != null) activeKey = split.activeKey;
		for (key in split.layouts.keys()) contexts.set(key, split.layouts.get(key));
		var active:Array<String> = [], dock = false, pane = false;
		for (line in lines) {
			if (contextLine(line)) continue;
			layout.push(line);
			if (StringTools.startsWith(line, "Z\t") || StringTools.startsWith(line, "M\t")) continue;
			active.push(line);
			if (StringTools.startsWith(line, "D\tdock\t1\t")) dock = true;
			if (StringTools.startsWith(line, "P\t")) pane = true;
		}
		if (activeKey.length > 0 && dock && pane) contexts.set(activeKey, active);
	}

	/**
		The layout lines to restore from: this file's own plus the context files. A context file wins over a context
		line in session.conf with the same key. Context lines in session.conf (written before the files existed) are
		migrated: kept when the folder has no files yet, or for keys no file has. The first save then writes them out.
	**/
	public function mergedLayout(store:Null<ContextSnapshotStore>):Array<String> {
		if (store == null) return layout;
		var snapshots = store.readAll(), byKey:Map<String, Bool> = [], result:Array<String> = [];
		for (snapshot in snapshots) byKey.set(snapshot.key, true);
		for (line in layout) {
			if (contextLine(line) && snapshots.length > 0) {
				var keys = [for (key in ContextLayoutStore.read([line]).layouts.keys()) key];
				// A key in an older scheme (workspace:/group:) cannot be compared to a file's; the files are newer.
				if (keys.length == 1 && (byKey.exists(keys[0]) || workspace.ContextKey.legacy(keys[0]))) continue;
			}
			result.push(line);
		}
		// Oldest first, so on a duplicate key the newest writer is read last.
		snapshots.sort(function(a, b) return a.written < b.written ? -1 : a.written > b.written ? 1 : 0);
		for (snapshot in snapshots) result.push(ContextLayoutStore.layoutLine(snapshot.key, snapshot.lines));
		return result;
	}

	public function restore(application:Application, ?recovery:RecoveryStore, ?store:ContextSnapshotStore):Void {
		for (repositoryId in [for (repositoryId in application.scmCommitDrafts.keys()) repositoryId])
			application.scmCommitDrafts.remove(repositoryId);
		for (repositoryId in scmCommitDrafts.keys()) {
			var message = scmCommitDrafts.get(repositoryId);
			if (message != null) application.scmCommitDrafts.set(repositoryId, message);
		}
		// Saved contexts are keyed by the machine id of the last run; adopt it before anything is keyed or restored.
		if (machineId.length > 0) application.activeContext.assignMachine(machineId);
		if (savedWorkspace != null) application.savedWorkspaces.restore(savedWorkspace, workspaceFile);
		else for (root in projects)
			if (FileSystem.exists(root) && FileSystem.isDirectory(root)) application.openArgument(root);
		application.activeContext.restoreRecent(recent);
		for (project in application.workspace.projects) project.restoreExpanded(expanded);
		if (groupId.length > 0 && groupDirectory.length > 0) application.activeContext.focusGroup(groupId, groupLabel, groupDirectory);
		// Populate the sidebar before restoring the saved dock selection and focus.
		application.root.showProjectSidebar();
		var merged = mergedLayout(store);
		if (merged.length > 0) {
			var snapshots:Map<String, RecoverySnapshot> = [], restored:Map<String, Document> = [];
			if (recovery != null)
				for (snapshot in recovery.load()) snapshots.set(snapshot.id, snapshot);
			application.root.restoreSessionLines(merged, function(kind, reference) {
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
	}

	public function encode():String {
		var output = "version=" + VERSION + "\n";
		if (savedWorkspace != null) {
			output += "workspace=" + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(savedWorkspace.encode())) + "\n";
			output += "workspaceFile=" + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(workspaceFile)) + "\n";
		}
		if (machineId.length > 0) output += "contextMachine=" + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(machineId)) + "
";
		for (info in recent) output += "contextRecent=" + [for (value in [info.machine, info.workspace, info.group, info.label, info.workspaceLabel, info.directory])
			haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(value))].join(":") + "\n";
		if (groupId.length > 0) output += "contextGroup=" + [for (value in [groupId, groupLabel, groupDirectory]) haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(value))].join(":") + "\n";
		for (project in projects) output += "project=" + clean(project) + "\n";
		for (document in documents) output += "document=" + clean(document) + "\n";
		output += "active=" + clean(activeDocument) + "\n";
		for (line in layout) output += "layout=" + clean(line) + "\n";
		for (path in expanded) output += "expanded=" + clean(path) + "\n";
		var repositoryIds = [for (repositoryId in scmCommitDrafts.keys()) repositoryId];
		repositoryIds.sort(Reflect.compare);
		for (repositoryId in repositoryIds) {
			var message = scmCommitDrafts.get(repositoryId);
			if (repositoryId.length > 0 && message != null)
				output += "scmCommitDraft=" + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(repositoryId)) + ":"
					+ haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(message)) + "\n";
		}
		return output;
	}

	public static function decode(content:String):WorkspaceSession {
		var result = new WorkspaceSession(), version = 0;
		for (raw in content.split("\n")) {
			var line = StringTools.endsWith(raw, "\r") ? raw.substring(0, raw.length - 1) : raw, separator = line.indexOf("=");
			if (line.length == 0 || separator < 0) continue;
			var key = line.substring(0, separator), value = line.substring(separator + 1);
			if (key == "version") version = Std.parseInt(value);
			else if (key == "workspace") result.savedWorkspace = workspace.SavedWorkspace.decode(haxe.crypto.Base64.decode(value).toString());
			else if (key == "workspaceFile") result.workspaceFile = haxe.crypto.Base64.decode(value).toString();
			else if (key == "contextRecent" && value.length <= 32768 && result.recent.length < workspace.ActiveContext.RECENT_LIMIT) {
				var fields = value.split(":");
				if (fields.length == 6) try {
					var values = [for (field in fields) haxe.crypto.Base64.decode(field).toString()];
					if (values[0].length > 0 && values[1].length > 0 && safeValue(values[0]) && safeValue(values[1]) && safeValue(values[2]) && safeValue(values[5]))
						result.recent.push(new workspace.ContextInfo(values[0], values[1], values[2], values[3], values[4], values[5]));
				} catch (_:Dynamic) {}
			}
			else if (key == "contextMachine" && value.length <= 8192) try {
				var id = haxe.crypto.Base64.decode(value).toString();
				if (id.length > 0 && id.length <= 4096 && safeValue(id)) result.machineId = id;
			} catch (_:Dynamic) {}
			else if (key == "contextGroup" && value.length <= 32768) {
				var fields = value.split(":");
				if (fields.length == 3) try {
					var id = haxe.crypto.Base64.decode(fields[0]).toString(), label = haxe.crypto.Base64.decode(fields[1]).toString(), directory = haxe.crypto.Base64.decode(fields[2]).toString();
					if (id.length > 0 && id.length <= 4096 && directory.length > 0 && directory.length <= 4096 && safeValue(id) && safeValue(directory)) {
						result.groupId = id; result.groupLabel = label; result.groupDirectory = directory;
					}
				} catch (_:Dynamic) {}
			}
			else if (key == "project" && value.length > 0) result.projects.push(value);
			else if (key == "document" && value.length > 0) result.documents.push(value);
			else if (key == "active") result.activeDocument = value;
			else if (key == "layout" && validLayout(value)) result.layout.push(value);
			else if (key == "expanded" && value.length > 0) result.expanded.push(value);
			else if (key == "scmCommitDraft") {
				var separator = value.indexOf(":");
				if (separator > 0) try {
					var repositoryId = haxe.crypto.Base64.decode(value.substring(0, separator)).toString();
					if (repositoryId.length > 0)
						result.scmCommitDrafts.set(repositoryId, haxe.crypto.Base64.decode(value.substring(separator + 1)).toString());
				} catch (_:Dynamic) {}
			}
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

	public static function validLayout(value:String):Bool {
		if (StringTools.startsWith(value, "Z\t")) return value.length <= ContextLayoutStore.MAX_RECORD;
		var fields = value.split("\t");
		if (fields.length == 4 && fields[0] == "M") return fields[1] == "layout-mode" && fields[2] == "1" && ["auto", "editor", "agents"].indexOf(fields[3]) >= 0;
		if (fields.length == 7 && fields[0] == "N") {
			if (fields[1] != "layout-mode" || fields[2] != "1" || ["", "editor", "agents"].indexOf(fields[3]) < 0) return false;
			for (i in 4...7) if (fields[i] != "0" && fields[i] != "1") return false;
			return true;
		}
		if (fields.length == 6 && fields[0] == "L") {
			var bottom = Std.parseFloat(fields[3]), right = Std.parseFloat(fields[4]);
			return fields[1] == "regions" && fields[2] == "1" && fields[5].length <= 1048576 &&
				Math.isFinite(bottom) && Math.isFinite(right) && bottom >= 0.05 && bottom <= 0.95 && right >= 0.05 && right <= 0.95;
		}
		if (fields.length == 4 && fields[0] == "B" && fields[1] == "sidebar")
			return fields[2] == "1" && fields[3].length <= 65536;
		if (fields.length == 4 && (fields[0] == "I" || fields[0] == "B"))
			return validPaneId(fields[1]) && (fields[2] == "0" || fields[2] == "1") && fields[3].length > 0 && fields[3].length <= 4096;
		if (fields.length == 6 && fields[0] == "C")
			return validPaneId(fields[1]) && (fields[2] == "0" || fields[2] == "1") && fields[3].length > 0 && fields[3].length <= 4096 &&
				validPaneId(fields[4]) && fields[5].length > 0 && fields[5].length <= 256;
		if ((fields.length == 6 || fields.length == 7 || fields.length == 8) && fields[0] == "X")
			return validPaneId(fields[1]) && (fields[2] == "0" || fields[2] == "1") &&
				(fields.length == 6 || fields[6] == "0" || fields[6] == "1") && (fields.length < 8 || fields[7].length > 0 && fields[7].length <= 4096) && validPaneId(fields[3]) && fields[4].length > 0 && fields[4].length <= 256 && fields[5].length > 0;
		if ((fields.length == 5 || fields.length == 6 || fields.length == 7) && fields[0] == "Y")
			return (fields[1] == "0" || fields[1] == "1") && (fields.length == 5 || fields[5] == "0" || fields[5] == "1") && (fields.length < 7 || fields[6].length > 0 && fields[6].length <= 4096) && validPaneId(fields[2]) &&
				fields[3].length > 0 && fields[3].length <= 256 && fields[4].length > 0;
		if (fields.length == 2 && (fields[0] == "P" || fields[0] == "Q")) return validPaneId(fields[1]);
		if (fields.length == 4 && fields[0] == "D")
			return fields[1] == "dock" && fields[2] == "1" && fields[3].length > 0 && fields[3].length <= 1048576;
		if (fields.length == 9 && fields[0] == "V") {
			if (!validPaneId(fields[1]) || (fields[2] != "0" && fields[2] != "1") || (fields[7] != "P" && fields[7] != "R") || fields[8].length == 0) return false;
			for (index in 3...7) if (!nonNegativeInteger(fields[index])) return false;
			return true;
		}
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

	/** Stable host-owned pane identity; document references remain separate fields. */
	static function validPaneId(value:String):Bool {
		if (value.length == 0 || value.length > 128) return false;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			if (!(code >= 97 && code <= 122 || code >= 65 && code <= 90 ||
				code >= 48 && code <= 57 || code == 45 || code == 95)) return false;
		}
		return true;
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
