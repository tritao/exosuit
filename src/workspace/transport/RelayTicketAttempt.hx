package workspace.transport;

/** Cancellable in-flight request for a one-use relay socket ticket. */
class RelayTicketAttempt {
	var cancelAction:Null<Void->Void>;

	@:allow(workspace.transport.RelayTicketClient)
	private function new(cancelAction:Void->Void) {
		this.cancelAction = cancelAction;
	}

	public function cancel():Void {
		var action = cancelAction;
		cancelAction = null;
		if (action != null)
			action();
	}

	@:allow(workspace.transport.RelayTicketClient)
	private function finish():Void
		cancelAction = null;
}
