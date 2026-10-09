package scm;

class ScmGroup {
	public final id:ScmGroupId;
	public final resources:Array<ScmResource>;

	public function new(id:ScmGroupId, resources:Array<ScmResource>) {
		this.id = id;
		this.resources = resources.copy();
	}
}
