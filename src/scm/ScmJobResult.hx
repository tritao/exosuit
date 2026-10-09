package scm;

class ScmJobResult<T> {
	public final generation:Int;
	public final value:Null<T>;
	public final error:Null<ScmError>;

	public function new(generation:Int, value:Null<T>, ?error:ScmError) {
		this.generation = generation;
		this.value = value;
		this.error = error;
	}
}
