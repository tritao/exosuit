package plugin;

/** Owner-scoped badge and tint attached to a workspace resource path. */
class PluginResourceDecoration {
	public final owner:String;
	public final id:String;
	public final path:String;
	public final badge:String;
	public final color:PluginResourceDecorationColor;
	public final tooltip:String;
	public final propagateToParents:Bool;
	public final priority:Int;
	/** True when this result is inherited from a descendant directory entry. */
	public final inherited:Bool;
	/** Resource originally decorated when this result is inherited. */
	public final sourcePath:String;

	public function new(owner:String, id:String, path:String, badge:String,
			color:PluginResourceDecorationColor, tooltip:String, propagateToParents:Bool,
			priority:Int, ?inherited:Bool = false, ?sourcePath:String) {
		this.owner = owner;
		this.id = id;
		this.path = path;
		this.badge = badge;
		this.color = color;
		this.tooltip = tooltip;
		this.propagateToParents = propagateToParents;
		this.priority = priority;
		this.inherited = inherited;
		this.sourcePath = sourcePath == null ? path : sourcePath;
	}

	public function atParent(parent:String):PluginResourceDecoration
		return new PluginResourceDecoration(owner, id, parent, badge, color, tooltip,
			propagateToParents, priority, true, sourcePath);
}
