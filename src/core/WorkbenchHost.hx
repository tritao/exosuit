package core;

import build.BuildDiagnostic;
import build.BuildOutput;
import commandview.CommandViewProvider;
import completion.CompletionItem;
import config.Settings;
import editor.Document;
import feedback.NotificationCenter;
import feedback.Problem;
import feedback.ProblemRegistry;
import language.SignatureHelp;
import platform.TextInputArea;
import plugin.PluginDecorationRegistry;
import plugin.PluginPanelRegistry;
import plugin.PluginStatusRegistry;
import search.SearchMatch;
import style.Theme;
import view.View;
import view.LayoutKind;

/** UI-independent application surface, implemented by the hosted UI and model test host. */
interface WorkbenchHost {
	// -- Shared, UI-independent state the controllers read or mutate directly --
	function getTheme():Theme;
	function getProblems():ProblemRegistry;
	function getPluginDecorations():PluginDecorationRegistry;
	function getPluginStatusItems():PluginStatusRegistry;
	function getPluginPanels():PluginPanelRegistry;
	function getNotifications():NotificationCenter;

	// -- Text prompts / command-view input (also backs confirmations) --
	function openCommandView(provider:CommandViewProvider):Void;
	function closeCommandView():Void;
	function isCommandViewActive():Bool;
	function commandViewKeyPressed(key:Int, modifiers:Int):Bool;
	function commandViewTextInput(text:String):Void;

	// -- Focus & navigation requests --
	function splitActive(kind:LayoutKind, ?newFirst:Bool):Bool;
	function focusPane(horizontal:Int, vertical:Int):Bool;
	function moveActiveTab(horizontal:Int, vertical:Int):Bool;
	function reorderActiveTab(delta:Int):Bool;
	function switchActiveTab(delta:Int):Bool;
	function canCloseActiveTab():Bool;
	function toggleSidebar():Bool;
	function showProjectSidebar():Void;
	function searchMove(delta:Int):Bool;
	function searchActivate():Bool;
	/** The path selected in whatever file tree the host shows, or null (no tree, or nothing selected/showing). */
	function focusedFilePath():Null<String>;
	/** False when there is only a single pane, so "close pane" would have nothing to collapse into. */
	function canCloseActivePane():Bool;

	// -- Open/activate document & active-editor input dispatch --
	function openDocument(document:Document):View;
	function documentRenamed(document:Document):Void;
	function cursorChanged():Void;
	function textInput(text:String):Void;
	function setComposition(text:String, start:Int, length:Int):Void;
	function clearComposition():Void;
	function setDocumentSearchMatches(matches:Array<SearchMatch>):Void;
	function showSearchResults(query:String, results:Array<SearchMatch>):Void;
	function setWorkspaceSearchStatus(complete:Bool, capped:Bool, errorCount:Int):Void;
	function documentsLostByClosingActiveTab():Array<Document>;
	function closeActiveTab(force:Bool):Bool;
	function documentsLostByClosingActivePane():Array<Document>;
	function closeActivePane(force:Bool):Bool;
	/** Serializes/restores the open tabs and pane layout for `session.WorkspaceSession`/`recovery.RecoveryStore`. */
	function sessionLines():Array<String>;
	function restoreSessionLines(lines:Array<String>, ?resolver:(String, String)->Null<Document>):Void;

	// -- Problem / build-output publishing --
	function showProblems():Void;
	function setProblemActivationHandler(handler:Problem->Void):Void;
	function showBuildOutput(title:String, output:BuildOutput):Void;
	function setBuildDiagnosticHandler(handler:BuildDiagnostic->Void):Void;

	// -- Language popups (hover / completion / signature help) --
	function textInputArea():Null<TextInputArea>;
	function openLanguageInformation(area:TextInputArea, text:String):Void;
	function openLanguageCompletion(area:TextInputArea, items:Array<CompletionItem>, accept:CompletionItem->Void, ?input:String->Void, ?key:(Int, Int)->Bool):Void;
	function handleLanguagePopupText(text:String):Bool;
	function openLanguageSignature(area:TextInputArea, help:SignatureHelp):Void;
	function handleLanguagePopupKey(key:Int, modifiers:Int):Bool;
	function dismissLanguagePopup():Void;
	function isLanguagePopupVisible():Bool;

	// -- Visual settings application (theme colors already flow through getTheme()'s object) --
	function applySettings(settings:Settings):Bool;

	// -- One-time wiring core.Application performs after building its controllers --
	function configureFileActions(actions:FileActions):Void;
	function configureWelcomeActions(actions:WelcomeActions):Void;

	function sidebarMove(delta:Int):Bool;
	function sidebarActivate():Bool;
}
