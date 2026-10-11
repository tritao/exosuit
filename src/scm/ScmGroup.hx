package scm;

class ScmGroup {
	public final id:ScmGroupId;
	public final resources:Array<ScmResource>;

	public function new(id:ScmGroupId, resources:Array<ScmResource>, copyResources:Bool = true) {
		this.id = id;
		this.resources = copyResources ? resources.copy() : resources;
	}
}
