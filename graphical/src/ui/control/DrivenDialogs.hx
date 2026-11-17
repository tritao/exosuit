package ui.control;

import platform.HostFileDialogs;
import suit.control.ControlError;

private typedef Pending = {
	var id:String;
	var kind:String;
	var title:Null<String>;
	var detail:Null<String>;
	var choices:Array<String>;
	/** Takes the answer: `paths` for a file or folder dialog, `choice` for a question. */
	var answer:(Array<String>, Null<String>) -> Void;
	/** Shows it as the native dialog instead, which then takes the answer. */
	var showNative:Void->Void;
}

/**
	The window's dialogs while it is driven (docs/design/suitctl/TDD-exosuit-ctl.md §8.4 T5): every file and folder
	dialog and every question the window asks goes through this one seam. While a program drives the window
	(SyntheticInput.driven) a dialog does not show; it waits in `pending` until the program answers it with
	`exosuit.dialog.answer`, as a user would in the native dialog. Otherwise the native dialog shows as usual, and a
	waiting dialog shows natively once the window stops being driven (the user's own input, or a driver gone quiet), so
	a dialog never waits unseen for a program that died.
**/
class DrivenDialogs implements HostFileDialogs {
	final native:HostFileDialogs;
	final driven:Void->Bool;
	final pending:Array<Pending> = [];
	var nextId = 1;
	/** Called when a dialog starts to wait, so the window can say so to whoever drives it. */
	public var onPending:String->Void = function(_) {};

	public function new(native:HostFileDialogs, driven:Void->Bool) {
		this.native = native;
		this.driven = driven;
	}

	/** The dialogs waiting for an answer, oldest first. */
	public function list():Array<Dynamic>
		return [for (item in pending) {id: item.id, kind: item.kind, title: item.title, detail: item.detail, choices: item.choices}];

	/**
		Answers a waiting dialog: `paths` for `open-file`, `save-file` and `folder` (none cancels), `choice` for a question
		(one of its `choices`). Null on success, else why not.
	**/
	public function answer(id:String, paths:Null<Array<String>>, choice:Null<String>):Null<ControlError> {
		for (index in 0...pending.length) {
			var item = pending[index];
			if (item.id != id)
				continue;
			if (item.choices.length > 0 && (choice == null || item.choices.indexOf(choice) < 0))
				return new ControlError("invalid_argument", "dialog " + id + " takes a choice: " + item.choices.join(", "));
			pending.splice(index, 1);
			item.answer(paths == null ? [] : paths, choice);
			return null;
		}
		return new ControlError("not_found", "no dialog " + id + " is waiting");
	}

	/** Shows the waiting dialogs natively once the window is no longer driven. Call every loop pass. */
	public function poll():Void {
		if (pending.length == 0 || driven())
			return;
		var shown = pending.copy();
		pending.resize(0);
		for (item in shown)
			item.showNative();
	}

	/** Shows `showNative` now when the window is not driven, else waits for `exosuit.dialog.answer`. */
	function ask(kind:String, title:Null<String>, detail:Null<String>, choices:Array<String>, answer:(Array<String>, Null<String>) -> Void,
			showNative:Void->Void):Void {
		if (!driven()) {
			showNative();
			return;
		}
		var id = "dialog-" + nextId++;
		pending.push({id: id, kind: kind, title: title, detail: detail, choices: choices, answer: answer, showNative: showNative});
		onPending(id);
	}

	public function openFile(handler:Bool->Array<String>->Void, ?title:String, ?initialPath:String, ?allowMultiple:Bool):haxe.Int64 {
		ask("open-file", title, initialPath, [], function(paths, _) handler(paths.length > 0, paths),
			function() native.openFile(handler, title, initialPath, allowMultiple));
		return 0;
	}

	public function saveFile(handler:Bool->Array<String>->Void, ?title:String, ?initialPath:String, ?suggestedName:String):haxe.Int64 {
		ask("save-file", title, suggestedName == null ? initialPath : suggestedName, [], function(paths, _) handler(paths.length > 0, paths),
			function() native.saveFile(handler, title, initialPath, suggestedName));
		return 0;
	}

	public function selectDirectory(handler:Bool->Array<String>->Void, ?title:String, ?initialPath:String):haxe.Int64 {
		ask("folder", title, initialPath, [], function(paths, _) handler(paths.length > 0, paths),
			function() native.selectDirectory(handler, title, initialPath));
		return 0;
	}

	public function confirmSaveChanges(filename:String, handler:String->Void):Void
		ask("save-changes", "Save changes?", filename, ["save", "discard", "cancel"], function(_, choice) handler(choice),
			function() native.confirmSaveChanges(filename, handler));

	public function confirmMoveToTrash(path:String, handler:(Bool, Bool)->Void):Void
		ask("move-to-trash", "Move to Trash?", path, ["move", "cancel"], function(_, choice) handler(choice == "move", false),
			function() native.confirmMoveToTrash(path, handler));

	public function shutdown():Void {
		for (item in pending)
			item.answer([], item.choices.length > 0 ? "cancel" : null);
		pending.resize(0);
		native.shutdown();
	}
}
