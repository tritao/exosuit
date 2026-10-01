package controller;

import command.CommandContext;
import command.CommandRegistry;
import command.Keymap;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import config.Settings;
import core.WorkbenchHost;
import editor.Document;
import feedback.ConfirmationService;
import platform.Platform;
import search.DocumentSearch;
import search.ReplacementBackupStore;
import search.ReplacementPreview;
import search.ReplacementResult;
import search.SearchMatch;
import search.SearchOptions;
import search.WorkspaceReplacement;
import search.WorkspaceSearch;
import workspace.Workspace;

class SearchController {
	public final options:SearchOptions;
	public final workspaceSearch:WorkspaceSearch;
	public final workspaceReplacement:WorkspaceReplacement;
	public final documentMatches:Array<SearchMatch> = [];
	public var documentSearchQuery(default, null):String = "";
	public var replacementPreview(default, null):Null<ReplacementPreview>;
	public var replacementResult(default, null):Null<ReplacementResult>;

	final workspace:Workspace;
	final root:WorkbenchHost;
	final context:CommandContext;
	final commands:CommandRegistry;
	final keymap:Keymap;
	final confirmations:ConfirmationService;
	final effectiveSettings:Void->Settings;
	final reportError:(String, String)->Void;
	final reportInformation:String->Void;
	var documentMatchIndex:Int = -1;
	var documentSearchDocument:Null<Document>;
	var documentSearchRevision:Int = -1;

	public function new(workspace:Workspace, root:WorkbenchHost, context:CommandContext, commands:CommandRegistry, keymap:Keymap,
		confirmations:ConfirmationService, effectiveSettings:Void->Settings, reportError:(String, String)->Void,
		reportInformation:String->Void, replacementBackupPath:String) {
		this.workspace = workspace;
		this.root = root;
		this.context = context;
		this.commands = commands;
		this.keymap = keymap;
		this.confirmations = confirmations;
		this.effectiveSettings = effectiveSettings;
		this.reportError = reportError;
		this.reportInformation = reportInformation;
		options = new SearchOptions();
		workspaceSearch = new WorkspaceSearch(workspace, workspace.jobs, workspaceSearchChanged);
		workspaceReplacement = new WorkspaceReplacement(workspace, new ReplacementBackupStore(replacementBackupPath));
		installCommands();
	}

	public function editorStateChanged():Void {
		if (documentSearchQuery.length > 0) ensureDocumentSearchFresh();
	}

	public function update(now:Float):Void
		workspaceSearch.update(now);

	public function applySettings(value:Settings):Void {
		options.caseSensitive = value.searchCaseSensitive;
		options.wholeWord = value.searchWholeWord;
	}

	public function openDocumentFind():Void {
		if (activeDocument() == null) return;
		root.openCommandView(new CommandViewProvider("Find: ", [], refreshDocumentSearch, function(entry, query, backwards) {
			navigateDocumentMatch(backwards ? -1 : 1);
		}, function() {
			root.setDocumentSearchMatches([]);
		}, navigateDocumentMatch));
	}

	public function openWorkspaceFind():Void {
		root.openCommandView(new CommandViewProvider("Search: ", [], function(query) {
			workspaceSearch.request(query, options, effectiveSettings().searchMaxResults);
		}, function(entry, query, backwards) {
			if (backwards) root.searchMove(-1);
			root.searchActivate();
			root.closeCommandView();
		}, function() {
			workspaceSearch.cancel();
		}, function(delta) {
			root.searchMove(delta);
		}));
	}

	public function previewWorkspaceReplacement(replacement:String):Bool {
		try {
			replacementPreview = workspaceReplacement.preview(workspaceSearch, replacement);
			return true;
		} catch (error:Dynamic) {
			reportError("search", 'Could not preview replacement: ' + Std.string(error));
			return false;
		}
	}

	public function applyWorkspaceReplacement():Bool {
		var preview = replacementPreview;
		if (preview == null) return false;
		try {
			var result = workspaceReplacement.apply(preview);
			replacementResult = result;
			replacementPreview = null;
			reportInformation('Replaced ${result.appliedMatches} matches in ${result.appliedFiles} files; '
				+ '${result.conflicts} conflicts, ${result.failures} failures');
			return result.failures == 0 && result.conflicts == 0;
		} catch (error:Dynamic) {
			reportError("search", 'Could not apply replacement: ' + Std.string(error));
			return false;
		}
	}

	public function replaceCurrent(replacement:String):Bool {
		var document = activeDocument(), match = currentDocumentMatch(), selection = activeSelection();
		if (document == null || match == null || selection == null) return false;
		if (!DocumentSearch.replaceCurrent(document, selection, match, replacement)) return false;
		refreshDocumentSearch(documentSearchQuery);
		return true;
	}

	public function replaceAll(replacement:String):Int {
		var document = activeDocument(), selection = activeSelection();
		if (document == null || selection == null) return 0;
		var count = DocumentSearch.replaceAll(document, selection, documentSearchQuery, replacement, options);
		refreshDocumentSearch(documentSearchQuery);
		return count;
	}

	function workspaceSearchChanged():Void {
		root.showSearchResults(workspaceSearch.query, workspaceSearch.results);
		root.setWorkspaceSearchStatus(workspaceSearch.complete, workspaceSearch.capped, workspaceSearch.errors.length);
	}

	function openWorkspaceReplace():Void {
		root.openCommandView(new CommandViewProvider("Replace in Projects: ", [], function(query) {}, function(entry, replacement, backwards) {
			if (!previewWorkspaceReplacement(replacement)) return;
			var preview = replacementPreview;
			if (preview == null) return;
			confirmations.choose('Preview: ${preview.matchCount} matches in ${preview.files.length} files. Type apply to continue: ', ["apply"],
				function(answer) {
					applyWorkspaceReplacement();
					root.closeCommandView();
				}, function() {
					replacementPreview = null;
				});
		}));
	}

	function restoreLastWorkspaceReplacement():Void {
		confirmations.choose("Restore the latest disk replacement backup file by file? Type restore: ", ["restore"], function(answer) {
			var result = workspaceReplacement.restoreLastBackup();
			replacementResult = result;
			reportInformation('Restored ${result.appliedFiles} files; ${result.conflicts} conflicts, ${result.failures} failures');
			root.closeCommandView();
		});
	}

	function openReplace(all:Bool):Void {
		if (documentSearchQuery.length == 0) {
			openDocumentFind();
			return;
		}
		root.openCommandView(new CommandViewProvider(all ? "Replace All: " : "Replace: ", [], function(query) {}, function(entry, replacement, backwards) {
			if (all) replaceAll(replacement); else replaceCurrent(replacement);
			root.closeCommandView();
		}));
	}

	function refreshDocumentSearch(query:String):Void {
		documentSearchQuery = query;
		documentMatches.resize(0);
		var document = activeDocument();
		documentSearchDocument = document;
		documentSearchRevision = document == null ? -1 : document.buffer.stateId;
		if (document != null)
			try {
				for (match in DocumentSearch.find(document, query, options)) documentMatches.push(match);
			} catch (error:Dynamic) {
				reportError("search", 'Invalid search pattern: ' + Std.string(error));
			}
		documentMatchIndex = documentMatches.length == 0 ? -1 : 0;
		root.setDocumentSearchMatches(documentMatches);
		if (documentMatchIndex >= 0) selectDocumentMatch();
	}

	function navigateDocumentMatch(delta:Int):Void {
		ensureDocumentSearchFresh();
		if (documentMatches.length == 0) return;
		documentMatchIndex += delta;
		if (documentMatchIndex < 0) documentMatchIndex = documentMatches.length - 1;
		if (documentMatchIndex >= documentMatches.length) documentMatchIndex = 0;
		selectDocumentMatch();
	}

	function selectDocumentMatch():Void {
		var document = activeDocument(), match = currentDocumentMatch(), selection = activeSelection();
		if (document != null && match != null && selection != null)
			if (DocumentSearch.select(document, selection, match)) root.cursorChanged();
	}

	function ensureDocumentSearchFresh():Void {
		var document = activeDocument();
		if (document != documentSearchDocument || document != null && document.buffer.stateId != documentSearchRevision)
			refreshDocumentSearch(documentSearchQuery);
	}

	function activeDocument():Null<Document> {
		var view = context.activeView();
		return view == null ? null : view.getDocument();
	}

	function activeSelection():Null<editor.BufferSelection> {
		var view = context.activeView();
		return view == null ? null : view.getSelection();
	}

	function currentDocumentMatch():Null<SearchMatch>
		return documentMatchIndex < 0 || documentMatchIndex >= documentMatches.length ? null : documentMatches[documentMatchIndex];

	function installCommands():Void {
		var hasDocument = (context:CommandContext) -> context.activeView() != null && context.activeView().getDocument() != null;
		commands.add("find:open", context -> openDocumentFind(), hasDocument);
		commands.add("find:next", context -> navigateDocumentMatch(1), hasDocument);
		commands.add("find:previous", context -> navigateDocumentMatch(-1), hasDocument);
		commands.add("find:replace", context -> openReplace(false), hasDocument);
		commands.add("find:replace-all", context -> openReplace(true), hasDocument);
		commands.add("find:toggle-case-sensitive", function(context) {
			options.caseSensitive = !options.caseSensitive;
			refreshDocumentSearch(documentSearchQuery);
		}, hasDocument);
		commands.add("find:toggle-whole-word", function(context) {
			options.wholeWord = !options.wholeWord;
			refreshDocumentSearch(documentSearchQuery);
		}, hasDocument);
		commands.add("find:toggle-regular-expression", function(context) {
			options.regularExpression = !options.regularExpression;
			refreshDocumentSearch(documentSearchQuery);
		}, hasDocument);
		commands.add("workspace:search", context -> openWorkspaceFind());
		commands.add("workspace:search-next", context -> root.searchMove(1));
		commands.add("workspace:search-previous", context -> root.searchMove(-1));
		commands.add("workspace:replace", context -> openWorkspaceReplace(),
			context -> workspaceSearch.complete && !workspaceSearch.capped && workspaceSearch.results.length > 0);
		commands.add("workspace:restore-last-replacement", context -> restoreLastWorkspaceReplacement());
		commands.add("project:show-sidebar", context -> root.showProjectSidebar());
		keymap.addDirect(Platform.KEY_F, Platform.MOD_CTRL, ["find:open"]);
		keymap.addDirect(Platform.KEY_F, Platform.MOD_CTRL + Platform.MOD_SHIFT, ["workspace:search"]);
		keymap.addDirect(Platform.KEY_H, Platform.MOD_CTRL, ["find:replace"]);
	}
}
