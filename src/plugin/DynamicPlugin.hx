package plugin;

import command.CommandContext;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import runtime.LoadedModule;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeError;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Mutex;
import sys.thread.Thread;

class DynamicPlugin implements Plugin {
	public final manifest:PluginManifest;
	public var lastError(default, null):Null<String>;
	public var revision(default, null):Int = 0;

	final compiler:Compiler;
	final contents:Array<String> = [];
	final sourceStamps:Array<String> = [];
	var module:Null<LoadedModule>;
	var functionIds:Map<String, Int> = [];
	var context:Null<PluginContext>;
	var nextPollAt:Float = 0.0;
	var changedAt:Float = -1.0;
	var nextContentAuditAt:Float = 0.0;
	var observationGeneration:Int = 0;
	var compiling:Bool = false;
	var disposed:Bool = false;
	var completion:Null<DynamicCompileCompletion>;
	final completionMutex = new Mutex();
	static final compilerMutex = new Mutex();
	static inline final POLL_SECONDS = 0.25;
	static inline final DEBOUNCE_SECONDS = 0.3;
	static inline final CONTENT_AUDIT_SECONDS = 2.0;

	public function new(manifest:PluginManifest) {
		this.manifest = manifest;
		compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addFfiInterface("PluginHost.hxi", DynamicEditorApiSource.NATIVE_INTERFACE);
		compiler.enablePublicationTracking();
		compiler.update("pragtical/Editor.hx", DynamicEditorApiSource.CONTENT);
		for (source in manifest.sources) {
			var content = File.getContent(source);
			contents.push(content);
			sourceStamps.push(sourceStamp(source));
			compiler.update(modulePath(source), content);
		}
		var build = compilePlugin();
		module = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
		functionIds = build.functionIds;
		revision = build.revision;
		compiler.acknowledgePublication(build.revision);
	}

	public function id():String
		return manifest.id;

	public function activate(context:PluginContext):Void {
		this.context = context;
		DynamicHostRouter.begin(context, this);
		try {
			Runtime.callVoid(requireModule(), functionId("activate"));
		} catch (error:Dynamic) {
			DynamicHostRouter.end();
			throw error;
		}
		DynamicHostRouter.end();
		for (syntax in manifest.syntaxes)
			context.addSyntax(syntax.definition());
		for (command in manifest.commands) {
			var stableId = functionId(command.functionName);
			context.addCommand(command.name, function(editor:CommandContext) {
				Runtime.callVoid(requireModule(), stableId);
			});
			if (command.key > 0)
				context.bind(command.key, command.modifiers, [command.name]);
		}
	}

	public function deactivate(context:PluginContext):Void {
		Runtime.callVoid(requireModule(), functionId("deactivate"));
		this.context = null;
	}

	public function update(now:Float):Bool {
		var published = publishCompletion();
		if (now < nextPollAt) return published;
		nextPollAt = now + POLL_SECONDS;
		var observedChange = false;
		for (index in 0...manifest.sources.length) {
			var stamp = sourceStamp(manifest.sources[index]);
			if (stamp != sourceStamps[index]) {
				sourceStamps[index] = stamp;
				observedChange = true;
			}
		}
		var audit = false;
		if (now >= nextContentAuditAt) {
			nextContentAuditAt = now + CONTENT_AUDIT_SECONDS;
			audit = true;
		}
		if (observedChange) {
			changedAt = now;
			observationGeneration++;
		} else if (audit) changedAt = now;
		if (changedAt < 0.0 || now - changedAt < DEBOUNCE_SECONDS) return published;
		changedAt = -1.0;
		requestRefresh();
		return published;
	}

	public function requestRefresh():Bool {
		if (compiling || disposed) return false;
		var generation = observationGeneration;
		compiling = true;
		Thread.create(function() {
			var build:Null<compiler.CompileResult> = null, error:Null<String> = null;
			compilerMutex.acquire();
			try {
				if (updateCompilerSources()) build = compilePlugin();
			} catch (failure:Dynamic) {
				error = Std.string(failure) + haxe.CallStack.toString(haxe.CallStack.exceptionStack());
			}
			compilerMutex.release();
			completionMutex.acquire();
			if (disposed) {
				if (build != null) compiler.rejectPublication(build.revision);
				compiling = false;
			} else {
				completion = new DynamicCompileCompletion(generation, build, error);
			}
			completionMutex.release();
		});
		return true;
	}

	public function refresh():Bool {
		try {
			if (compiling) return false;
			var changed = updateCompilerSources();
			if (!changed) {
				lastError = null;
				return false;
			}
			return publish(compilePlugin());
		} catch (error:RuntimeError) {
			lastError = error.message;
			return false;
		} catch (error:Dynamic) {
			lastError = Std.string(error) + haxe.CallStack.toString(haxe.CallStack.exceptionStack());
			return false;
		}
	}

	function updateCompilerSources():Bool {
		var changed = false;
		for (index in 0...manifest.sources.length) {
			var content = File.getContent(manifest.sources[index]);
			if (content != contents[index]) {
				contents[index] = content;
				compiler.update(modulePath(manifest.sources[index]), content);
				changed = true;
			}
		}
		return changed;
	}

	function publishCompletion():Bool {
		completionMutex.acquire();
		var finished = completion;
		completion = null;
		completionMutex.release();
		if (finished == null) return false;
		compiling = false;
		if (finished.generation != observationGeneration) {
			if (finished.build != null) compiler.rejectPublication(finished.build.revision);
			return false;
		}
		if (finished.error != null) {
			lastError = finished.error;
			return false;
		}
		if (finished.build == null) {
			lastError = null;
			return false;
		}
		return publish(finished.build);
	}

	function publish(build:compiler.CompileResult):Bool {
		try {
			if (build.patchBytes != null && !build.requiresReload) {
				try {
					Runtime.patchSet(requireModule(), new PatchSet(revision, build.revision, build.patchBytes, build.changedFunctions));
					functionIds = build.functionIds;
					revision = build.revision;
					compiler.acknowledgePublication(build.revision);
				} catch (error:RuntimeError) {
					reload(build);
				}
			} else if (build.requiresReload) {
				reload(build);
			}
			lastError = null;
			return true;
		} catch (error:RuntimeError) {
			lastError = error.message;
			return false;
		} catch (error:Dynamic) {
			lastError = Std.string(error) + haxe.CallStack.toString(haxe.CallStack.exceptionStack());
			return false;
		}
	}

	static function sourceStamp(path:String):String {
		var metadata = FileSystem.metadata(path);
		return metadata == null ? "missing" : Std.string(metadata.size) + ":" + Std.string(metadata.modified);
	}

	public function dispose():Void {
		completionMutex.acquire();
		disposed = true;
		var finished = completion;
		completion = null;
		if (finished != null && finished.build != null) compiler.rejectPublication(finished.build.revision);
		completionMutex.release();
		var loaded = module;
		if (loaded != null)
			Runtime.dispose(loaded);
		module = null;
	}

	public function callInt(name:String):Int
		return Runtime.callInt(requireModule(), functionId(name));

	public function callStringArg(name:String, value:String):Void
		Runtime.callStringArg(requireModule(), functionId(name), value);

	public function diagnostic():Null<String>
		return lastError;

	public function busy():Bool
		return compiling;

	function compilePlugin():compiler.CompileResult {
		try {
			return compiler.compile(manifest.entry);
		} catch (error:CompileError) {
			var diagnostic = error.diagnostic;
			throw '${diagnostic.span.file.path}:${diagnostic.span.start}: ${diagnostic.code}: ${diagnostic.message}';
		}
	}

	function reload(build:compiler.CompileResult):Void {
		var previous = requireModule(),
			previousIds = functionIds,
			previousRevision = revision,
			previousStateVersion = Runtime.callInt(previous, functionId("stateVersion")),
			state = Runtime.callString(previous, functionId("saveState")),
			replacement = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			nextIds = build.functionIds,
			nextStateVersion = Runtime.callInt(replacement, requiredId(nextIds, "stateVersion"));
		if (context == null) {
			Runtime.dispose(replacement);
			compiler.rejectPublication(build.revision);
			throw 'plugin "${manifest.id}" has no active host context';
		}
		var activeContext:PluginContext = context;
		try {
			deactivate(activeContext);
			activeContext.dispose();
			activeContext.reset();
			module = replacement;
			functionIds = nextIds;
			revision = build.revision;
			if (previousStateVersion == nextStateVersion)
				Runtime.callStringArg(replacement, requiredId(nextIds, "restoreState"), state);
			activate(activeContext);
		} catch (error:Dynamic) {
			activeContext.dispose();
			activeContext.reset();
			module = previous;
			functionIds = previousIds;
			revision = previousRevision;
			Runtime.dispose(replacement);
			compiler.rejectPublication(build.revision);
			try {
				activate(activeContext);
			} catch (rollbackError:Dynamic) {
				activeContext.dispose();
				throw 'plugin reload failed (${Std.string(error)}) and rollback activation failed (${Std.string(rollbackError)})';
			}
			throw error;
		}
		compiler.acknowledgePublication(build.revision);
		Runtime.dispose(previous);
	}

	function functionId(name:String):Int
		return requiredId(functionIds, name);

	function requiredId(ids:Map<String, Int>, name:String):Int {
		var direct = ids.get(name);
		if (direct != null)
			return direct;
		var qualified = manifest.entry + "." + name;
		var resolved = ids.get(qualified);
		if (resolved != null)
			return resolved;
		throw 'plugin is missing exported function "$qualified"';
	}

	function requireModule():LoadedModule {
		if (module == null)
			throw 'plugin "${manifest.id}" has no loaded module';
		return module;
	}

	static function modulePath(path:String):String {
		var slash = path.lastIndexOf("/"),
			name = slash < 0 ? path : path.substring(slash + 1);
		return name;
	}
}
