package feedback;

import commandview.CommandViewProvider;
import core.WorkbenchHost;

class ConfirmationService {
	final host:WorkbenchHost;
	/** Installed by graphical hosts; core-only hosts retain their command input. */
	public var saveChangesPrompt:Null<(String, String->Void)->Void>;

	public function new(host:WorkbenchHost) {
		this.host = host;
	}

	public function saveChanges(filename:String, onChoose:String->Void, onCancel:Void->Void):Void {
		if (saveChangesPrompt != null) {
			saveChangesPrompt(filename, function(answer) {
				if (answer == "save" || answer == "discard") onChoose(answer); else onCancel();
			});
		} else choose('Save changes to "' + filename + '"? Type save, discard, or cancel: ',
			["save", "discard", "cancel"], onChoose, onCancel);
	}

	public function choose(prompt:String, choices:Array<String>, onChoose:String->Void, ?onCancel:Void->Void):Void {
		host.openCommandView(new CommandViewProvider(prompt, [], function(query) {}, function(entry, answer, backwards) {
			for (choice in choices)
				if (answer == choice) {
					onChoose(choice);
					return;
				}
		}, onCancel));
	}
}
