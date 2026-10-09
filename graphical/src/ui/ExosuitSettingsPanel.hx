package ui;

import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyDescriptorOptions;
import haxeon.ui.properties.PropertyInspectorSection;
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

	public function new(store:SettingsStore, models:Void->Array<AgentModel>, onChanged:Void->Void) {
		super("exosuit-settings", store, onChanged);
		this.models = models;
	}

	override public function currentInspector():Null<PropertyInspector> {
		if (selectedCategory != "workbench/codex") return super.currentInspector();
		var sections = catalog.sections(selectedCategory, filter, showAdvanced);
		if (sections.length == 0) return null;
		var store = catalog.store;
		var selected = store.getString("workbench/codex/default_model");
		var options = [new PropertyOption("model-default", "Codex default")];
		var known = selected == "";
		for (model in models()) {
			options.push(new PropertyOption("model:" + model.model, model.name));
			if (model.model == selected) known = true;
		}
		if (!known) options.push(new PropertyOption("model:" + selected, selected + " (saved)"));
		var config = new PropertyDescriptorOptions();
		config.category = "workbench/codex";
		config.recordHistory = false;
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
		var first = sections[0];
		var withModel = [modelSetting];
		for (descriptor in first.descriptors) withModel.push(descriptor);
		sections[0] = new PropertyInspectorSection(first.id, first.label, withModel, first.expanded);
		return new PropertyInspector(key + ":inspector:" + selectedCategory, null, null, null,
			sections, null, "Codex settings");
	}
}
