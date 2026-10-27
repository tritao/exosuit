package ui;

import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyDescriptorOptions;
import haxeon.ui.properties.PropertyOption;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.settings.SettingsStore;
import haxeon.ui.widgets.properties.PropertyInspector;
import haxeon.ui.widgets.settings.SettingsPanel;
import workspace.service.WorkspaceAgentProtocol.AgentModel;

/** Adds the live Codex model picker to the normal Workbench settings section. */
class ExosuitSettingsPanel extends SettingsPanel {
	final models:Void->Array<AgentModel>;
	var modelOptionsKey:String = "";

	public function new(store:SettingsStore, models:Void->Array<AgentModel>, onChanged:Void->Void) {
		super("exosuit-settings", store, onChanged);
		this.models = models;
	}

	override public function currentInspector():Null<PropertyInspector> {
		var store = catalog.store;
		var selected = store.getString("workbench/codex/default_model");
		var options = [new PropertyOption("model-default", "Codex default")];
		var known = selected == "";
		for (model in models()) {
			options.push(new PropertyOption("model:" + model.model, model.name));
			if (model.model == selected) known = true;
		}
		if (!known) options.push(new PropertyOption("model:" + selected, selected + " (saved)"));
		var nextKey = haxe.Json.stringify([for (option in options) [option.key, option.label]]);
		if (nextKey == modelOptionsKey) return super.currentInspector();
		modelOptionsKey = nextKey;
		var config = new PropertyDescriptorOptions();
		config.category = "workbench/codex";
		config.recordHistory = false;
		config.description = "Model for new Workbench Codex sessions. Existing sessions keep their selected model.";
		config.modified = function() return !store.isDefault("workbench/codex/default_model");
		config.reset = function() store.reset("workbench/codex/default_model");
		config.defaultValue = PropertyValue.Enum("model-default");
		config.options = options;
		var modelSetting = new PropertyDescriptor("workbench/codex/default_model", "Default Model", PropertyType.Enum,
			function(_) {
				var id = store.getString("workbench/codex/default_model");
				return PropertyValue.Enum(id == "" ? "model-default" : "model:" + id);
			},
			function(_, value) switch (value) {
				case Enum(choice):
					var id = choice == "model-default" ? "" : choice.substr("model:".length);
					var error = store.set("workbench/codex/default_model", PropertyValue.Text(id));
					if (error != null) throw error;
				default:
				}, config);
		catalog.setDescriptor("workbench/codex/default_model", modelSetting);
		invalidateInspector();
		return super.currentInspector();
	}
}
