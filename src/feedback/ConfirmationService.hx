package feedback;

import commandview.CommandViewProvider;
import core.WorkbenchHost;

class ConfirmationService {
	final host:WorkbenchHost;

	public function new(host:WorkbenchHost) {
		this.host = host;
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
