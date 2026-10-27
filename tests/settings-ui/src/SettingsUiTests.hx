import config.PreferencesRegistry;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.settings.SettingsStore;
import ui.ExosuitSettingsPanel;

class SettingsUiTests {
 static function check(value:Bool, message:String):Void { if (!value) throw message; }
 public static function main():Int {
  var store = new SettingsStore(PreferencesRegistry.create());
  var panel = new ExosuitSettingsPanel(store, function() return [], function() {});
  var definition:haxeon.ui.settings.SettingDefinition = cast store.registry.get("files/explorer/excluded_names");
  var list = panel.catalog.descriptor(definition);
  check(list.structure != null, "excluded names use a structured list");
  var data = PropertyValue.Custom("ui.list", ["build", "vendor"]);
  check(list.validateValue(null, data) == null, "string lists validate");
  list.write(null, data);
  check(store.getString(definition.path) == '["build","vendor"]', "list edits retain JSON storage compatibility");
  check(list.validateValue(null, PropertyValue.Custom("ui.list", [1])) != null, "non-string entries are rejected");
  var fonts = panel.catalog.descriptor(store.registry.get("editor/fonts/font_fallback_paths"));
  check(fonts.structure != null && fonts.restartRequired, "fallback font list keeps restart metadata");
  var font = panel.catalog.descriptor(store.registry.get("editor/fonts/font_path"));
  font.write(null, PropertyValue.Custom("exosuit.font-path", "/tmp/font.ttf"));
  check(store.getString("editor/fonts/font_path") == "/tmp/font.ttf", "chosen font saves as a normal path");
  panel.setFilter("default model");
  var inspector = panel.currentInspector();
  check(inspector != null && inspector.descriptors.length == 1, "model picker remains searchable");
  Sys.println("Settings UI adapter tests passed");
  return 0;
 }
}
