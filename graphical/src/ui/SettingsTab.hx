package ui;






/**
	The Settings tab: opening and closing it, and the model list its model picker reads from the agent service.
	ExosuitApp owns one.
**/
@:allow(ui)
class SettingsTab {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	var settingsModels:Array<workspace.service.WorkspaceAgentProtocol.AgentModel> = [];
	var settingsModelsNext:Null<String>;
	var settingsModelsRetryCursor:Null<String>;
	var settingsModelsPending:Bool = false;
	var settingsModelsError:Null<String>;
	var settingsModelsToken:Int = 0;
	public function openSettings():Void {
		app.host.closeCommandView();
		for (pane in app.host.panes) for (item in pane.items) {
			var existing = UiEditorTabs.settings(item);
			if (existing != null) {
				app.settingsPanel = existing.panel;
				existing.panel.requestSearchFocus();
				app.host.activateEditorTab(UiSettingsTab.KEY, pane.id); app.requestFrame(); return;
			}
		}
		app.settingsPanel = new ExosuitSettingsPanel(app.application.settings.store, function() return settingsModels, app.requestFrame, app.desktop, settingsModelPickerState);
		var tab = new UiSettingsTab(app.settingsPanel);
		tab.content = function(paneId) {
			app.settingsPanel = tab.panel;
			return new SettingsTabView(tab, app.requestFrame, function(bounds, id) app.host.editorResolved(paneId, bounds, id));
		};
		tab.requestClose = function() {
			if (!tab.panel.hasUnsavedChanges()) return true;
			app.closingSettingsTab = tab; app.settingsClosePending = true; app.requestFrame(); return false;
		};
		tab.onClosed = function() {
			tab.panel.discardUnsavedChanges();
			if (app.settingsPanel == tab.panel) {
				app.settingsPanel = null; settingsModelsToken++; settingsModelsPending = false;
			}
			if (app.closingSettingsTab == tab) { app.closingSettingsTab = null; app.settingsClosePending = false; }
			app.requestFrame();
		};
		tab.panel.requestSearchFocus();
		app.host.attachSettings(tab);
		settingsModels = [];
		settingsModelsNext = null;
		settingsModelsPending = false;
		settingsModelsError = null;
		// Codex models are loaded by "Refresh models": opening Settings starts no agent program.
		app.requestFrame();
	}
	/**
		After a settings reload replaced the store, gives each open Settings tab a panel on the new store that shows what
		the old one showed. Runs before the build (ExosuitApp.submit): the new panel saves its Advanced switch and category
		into the store and calls requestFrame, and neither is allowed inside a build.
	**/
	public function syncStore():Void {
		var store = app.application.settings.store;
		for (pane in app.host.panes) for (item in pane.items) {
			var tab = UiEditorTabs.settings(item);
			if (tab == null || tab.panel.catalog.store == store) continue;
			var previous = tab.panel;
			tab.panel = new ExosuitSettingsPanel(store, function() return settingsModels, app.requestFrame, app.desktop, settingsModelPickerState);
			tab.panel.setShowAdvanced(previous.showAdvanced);
			tab.panel.setModifiedOnly(previous.modifiedOnly);
			if (previous.restartOnly) tab.panel.showRestartChanges();
			tab.panel.setFilter(previous.filter);
			if (previous.selectedCategory != null) tab.panel.select(previous.selectedCategory);
			if (app.settingsPanel == previous) app.settingsPanel = tab.panel;
		}
	}
	function settingsModelPickerState():SettingsModelPickerState {
		return new SettingsModelPickerState(settingsModelsPending, settingsModelsError, settingsModelsNext != null,
			function() loadSettingsModels(null), function() loadSettingsModels(settingsModelsNext),
			function() loadSettingsModels(settingsModelsRetryCursor));
	}
	function loadSettingsModels(cursor:Null<String>):Void {
		if (settingsModelsPending) return;
		settingsModelsRetryCursor = cursor;
		var client = app.workbenchClient == null ? null : app.workbenchClient.agentService();
		if (client == null) {
			settingsModelsError = "Connect a workspace to load Codex models";
			app.requestFrame();
			return;
		}
		settingsModelsPending = true;
		settingsModelsError = null;
		var token = ++settingsModelsToken;
		client.listModels(cursor, function(page, error) {
			if (token != settingsModelsToken || app.settingsPanel == null) return;
			settingsModelsPending = false;
			if (error != null || page == null) settingsModelsError = error == null ? "Could not load Codex models" : error;
			else {
				if (cursor == null) settingsModels = [];
				for (model in page.models) {
					var found = false;
					for (existing in settingsModels) if (existing.model == model.model) found = true;
					if (!found) settingsModels.push(model);
				}
				settingsModelsNext = page.next;
			}
			app.requestFrame();
		});
	}
}
