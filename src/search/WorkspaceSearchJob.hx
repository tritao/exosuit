package search;

import editor.Document;
import jobs.JobTask;
import workspace.ProjectNode;
import workspace.Workspace;

class WorkspaceSearchJob implements JobTask {
	public static inline final MAX_FILE_UNITS = 4 * 1024 * 1024;
	public static inline final MAX_PREVIEW_UNITS = 240;
	final owner:WorkspaceSearch;
	final generation:Int;
	final workspace:Workspace;
	final query:String;
	final options:SearchOptions;
	final maximum:Int;
	final pattern:SearchPattern;
	final files:Array<ProjectNode> = [];
	var cursor:Int = 0;
	var retained:Int = 0;
	var cancelled:Bool = false;

	public function new(owner:WorkspaceSearch, generation:Int, workspace:Workspace, query:String, options:SearchOptions, maximum:Int) {
		this.owner = owner;
		this.generation = generation;
		this.workspace = workspace;
		this.query = query;
		this.options = options;
		this.maximum = maximum < 1 ? 1 : maximum;
		pattern = new SearchPattern(query, options);
		for (project in workspace.scopedProjects())
			for (file in project.files()) files.push(file);
	}

	public function step():Bool {
		if (cancelled) return true;
		if (cursor >= files.length) {
			owner.publish(generation, [], null, true);
			return true;
		}
		var file = files[cursor++];
		if (options.pathFilter.length > 0 && file.path.toLowerCase().indexOf(options.pathFilter.toLowerCase()) < 0)
			return finishIfDone();
		var text:Null<String> = null, document:Null<Document> = null;
		for (candidate in workspace.documents.documents)
			if (candidate.path == file.path) {
				document = candidate;
				text = candidate.buffer.text;
				break;
			}
		if (text == null) {
			try {
				var bytes = workspace.fileSystem.readBytes(file.path);
				if (bytes.length > MAX_FILE_UNITS) {
					owner.publish(generation, [], 'Skipped oversized file: "' + file.path + '"');
					return finishIfDone();
				}
				for (index in 0...bytes.length)
					if (bytes.get(index) == 0) {
						owner.publish(generation, [], 'Skipped binary file: "' + file.path + '"');
						return finishIfDone();
					}
				text = bytes.toString();
			} catch (error:Dynamic) {
				owner.publish(generation, [], 'Unreadable file: "' + file.path + '"');
				return finishIfDone();
			}
		}
		if (text.length > MAX_FILE_UNITS) {
			owner.publish(generation, [], 'Skipped oversized file: "' + file.path + '"');
			return finishIfDone();
		}
		var found = pattern.findText(file.path, text, document, document == null ? -1 : document.buffer.stateId),
			batch:Array<SearchMatch> = [];
		for (match in found) {
			var preview = match.preview.length > MAX_PREVIEW_UNITS ? match.preview.substring(0, MAX_PREVIEW_UNITS) : match.preview;
			batch.push(new SearchMatch(match.path, match.line, match.column, match.length, preview, match.matchedText,
				match.document, match.revision, match.captures, match.regularExpression));
			retained++;
			if (retained >= maximum) {
				owner.publish(generation, batch, null, true, true);
				return true;
			}
		}
		if (batch.length > 0) owner.publish(generation, batch);
		return finishIfDone();
	}

	function finishIfDone():Bool {
		if (cursor < files.length) return false;
		owner.publish(generation, [], null, true);
		return true;
	}

	public function cancel():Void cancelled = true;
}
