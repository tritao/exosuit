package ui.shell;

/** Which shell draws the application: the dock (desktop, tablet, unfolded phone) or the navigation stack (phone). */
enum ShellKind {
	Desktop;
	Phone;
}

/** A view the core asks a shell to show. `id` is stable (a session id, "files", "search", "machines", ...). */
typedef ShellView = {
	id:String,
	title:String,
	build:Void->haxeon.ui.core.View,
}

/** One choice in a sheet or menu. */
typedef ShellChoice = {
	id:String,
	label:String,
	?detail:String,
	?depth:Int,
}

/**
	What the application core needs from whatever draws it (ADR 0007). DesktopShell keeps today's dock; PhoneShell is
	a navigation stack with a bottom bar. The core never touches docks, rails or tab strips directly.
**/
interface Shell {
	function kind():ShellKind;
	/** Shows the view (focusing it when already open). */
	function open(view:ShellView):Void;
	function focus(id:String):Void;
	function close(id:String):Void;
	/** The view the user is on, re-opened in the other shell when the shell is swapped. */
	function focusedView():Null<String>;
	/** A short notice (a snackbar on the phone, the status bar on the desktop), with an optional action. */
	function notice(text:String, ?actionLabel:String, ?action:Void->Void):Void;
	/** A choice (a bottom sheet on the phone, a menu on the desktop). */
	function choose(title:String, choices:Array<ShellChoice>, selected:Array<String>, multi:Bool,
		done:Array<String>->Void):Void;
	/** The root of the window's content. */
	function build():haxeon.ui.core.View;
	function dispose():Void;
}
