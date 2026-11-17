package plugin;

import compiler.Compiler.CompileResult;

class DynamicCompileCompletion {
	public final generation:Int;
	public final build:Null<CompileResult>;
	public final error:Null<String>;

	public function new(generation:Int, build:Null<CompileResult>, error:Null<String>) {
		this.generation = generation;
		this.build = build;
		this.error = error;
	}
}
