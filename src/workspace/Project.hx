package workspace;

import jobs.JobHandle;
import jobs.JobScheduler;

class Project {
	public final root:String;
	public final name:String;
	public var tree(default, null):ProjectNode;
	public var settings(default, null):Null<config.Preferences>;
	public final diagnostics:Array<String> = [];
	final fileSystem:FileSystemService;
	final scheduler:JobScheduler;
	var ignored:Map<String, Bool> = [];
	var indexedFiles:Array<ProjectNode> = [];
	var snapshot:String = "";
	var scan:Null<ProjectScan>;
	var scanHandle:Null<JobHandle>;
	var scanGeneration:Int = 0;
	var changedSincePoll:Bool = false;
	var requestedExpanded:Map<String, Bool> = [];
	var releaseSettings:Null<Void->Void>;

	public function new(path:String, fileSystem:FileSystemService, scheduler:JobScheduler, ?ignoredNames:Array<String>) {
		this.fileSystem = fileSystem;
		this.scheduler = scheduler;
		root = fileSystem.normalize(path);
		if (!fileSystem.exists(root) || !fileSystem.isDirectory(root)) throw 'project root is not a directory: "$root"';
		var separator = root.lastIndexOf("/");
		name = separator < 0 ? root : root.substring(separator + 1);
		tree = new ProjectNode(name, root, true, 0, true);
		requestedExpanded.set(root, true);
		setIgnored(ignoredNames == null ? [] : ignoredNames);
		if (scan != null) scan.step();
	}

	public function setIgnored(names:Array<String>):Void {
		ignored = [];
		for (name in [".git", ".hg", ".svn", ".devstack", ".pragtical", "build", "out", "node_modules"]) ignored.set(name, true);
		for (name in names) ignored.set(name, true);
		startScan();
	}

	public function setSettings(service:config.Preferences):Void {
		if (releaseSettings != null) releaseSettings();
		settings = service;
		releaseSettings = service.subscribe(value -> setIgnored(value.excludedNames));
	}

	function startScan():Void {
		scanGeneration++;
		var next = new ProjectScan(this, scanGeneration, fileSystem, ignored);
		scan = next;
		if (scanHandle == null) scanHandle = scheduler.schedule(next); else scanHandle = scheduler.replace(scanHandle, next);
	}

	public function publishScan(source:ProjectScan, finished:Bool):Void {
		if (source.generation != scanGeneration) return;
		if (tree != source.tree) {
			tree = source.tree;
			applyExpanded(tree);
		}
		indexedFiles = source.files.copy();
		if (finished) {
			applyExpanded(tree);
			changedSincePoll = source.snapshot != snapshot;
			snapshot = source.snapshot;
		}
	}

	public function scanFailed(generation:Int, path:String, detail:String):Void {
		if (generation == scanGeneration) diagnostics.push('Could not scan "$path": $detail');
	}

	public function pollChanges(directoryBudget:Int):Bool {
		if (settings != null) settings.reload();
		var changed = changedSincePoll;
		changedSincePoll = false;
		if (scan != null && scan.complete) startScan();
		return changed;
	}

	public function cancelIndex():Void {
		if (releaseSettings != null) releaseSettings();
		releaseSettings = null;
		if (scanHandle != null) scheduler.cancel(scanHandle);
		scan = null;
		scanHandle = null;
	}

	public function toggle(node:ProjectNode):Void {
		if (!node.directory) return;
		node.toggle();
		if (node.expanded) requestedExpanded.set(node.path, true); else requestedExpanded.remove(node.path);
	}

	public function visibleNodes():Array<ProjectNode> {
		var result:Array<ProjectNode> = [];
		appendVisible(tree, result);
		return result;
	}

	public function files():Array<ProjectNode> return indexedFiles.copy();
	public function indexGeneration():Int return scanGeneration;
	public function indexing():Bool return scan != null && !scan.complete;

	public function expandedPaths():Array<String> {
		var result:Array<String> = [];
		for (path in requestedExpanded.keys()) result.push(path);
		result.sort(Reflect.compare);
		return result;
	}

	public function restoreExpanded(paths:Array<String>):Void {
		for (path in paths) requestedExpanded.set(path, true);
		applyExpanded(tree);
	}

	function applyExpanded(node:ProjectNode):Void {
		if (node.directory && requestedExpanded.exists(node.path) && !node.expanded) node.toggle();
		for (child in node.children) applyExpanded(child);
	}

	function appendVisible(node:ProjectNode, result:Array<ProjectNode>):Void {
		result.push(node);
		if (node.directory && node.expanded)
			for (child in node.children) appendVisible(child, result);
	}
}
