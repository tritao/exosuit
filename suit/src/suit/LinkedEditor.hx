package suit;

/**
	An editor window suit knows by its link: what the window last said about itself. `started` is when it linked, in
	seconds; `focusedAt` when it last had the OS focus (its link time until it has), in milliseconds: the most recently
	used window has the largest.
**/
typedef LinkedEditor = {
	var window:String;
	var pid:Int;
	var context:Null<String>;
	var workspaces:Array<String>;
	var roots:Array<String>;
	var started:Float;
	var focusedAt:Float;
}
