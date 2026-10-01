package plugin;

/**
 * Source-editable, hot-reloadable plugins depended on `compiler.Compiler` and
 * `runtime.Runtime` - Haxeon's own compiler and patchable-runtime packages,
 * embedded as a library so a plugin's `.hx` sources could be recompiled and
 * hot-patched into the running process. Those packages are Haxeon's compiler
 * implementation, not something the `haxeon.json` package model exposes as an
 * installable dependency, so this class cannot be built against them yet.
 *
 * The original implementation is preserved in this file's git history for
 * when embedding Haxeon's compiler as a package becomes possible. Until then
 * this stub keeps `PluginController` and the rest of the plugin system
 * compiling; loading a manifest-based (source) plugin throws instead of
 * hot-compiling it.
 */
class DynamicPlugin implements Plugin {
	public final manifest:PluginManifest;
	public var lastError(default, null):Null<String>;
	public var revision(default, null):Int = 0;

	public function new(manifest:PluginManifest) {
		this.manifest = manifest;
		throw 'dynamic (source-compiled) plugins are not available in this build: '
			+ 'plugin "${manifest.id}" requires the embedded Haxeon compiler, which is not yet wired into the haxeon.json build';
	}

	public function id():String
		return manifest.id;

	public function activate(context:PluginContext):Void {}

	public function deactivate(context:PluginContext):Void {}

	public function update(now:Float):Bool
		return false;

	public function refresh():Bool
		return false;

	public function requestRefresh():Bool
		return false;

	public function diagnostic():Null<String>
		return lastError;

	public function busy():Bool
		return false;

	public function dispose():Void {}

	public function callInt(name:String):Int
		throw "dynamic plugins are not available in this build";

	public function callStringArg(name:String, value:String):Void
		throw "dynamic plugins are not available in this build";
}
