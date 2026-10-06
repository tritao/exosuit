package workspace.transport;

import haxeon.rpc.RpcConnectAttempt;

/** Cancels both the HTTPS ticket request and the subsequent WebSocket connect. */
class RelayMachineConnectAttempt {
	var ticketAttempt:Null<RelayTicketAttempt>;
	var socketAttempt:Null<RpcConnectAttempt>;
	var finished:Bool = false;
	var onTerminal:Null<RelayMachineConnectAttempt->Void>;

	public function new(?onTerminal:RelayMachineConnectAttempt->Void) {
		this.onTerminal = onTerminal;
	}

	public function isActive():Bool
		return !finished;

	public function cancel():Void {
		if (finished)
			return;
		finished = true;
		if (ticketAttempt != null) ticketAttempt.cancel();
		if (socketAttempt != null) socketAttempt.cancel();
		ticketAttempt = null;
		socketAttempt = null;
		finishOwner();
	}

	@:allow(workspace.transport.RelayMachineConnector)
	private function useTicket(attempt:RelayTicketAttempt):Void {
		if (finished)
			attempt.cancel();
		else
			ticketAttempt = attempt;
	}

	@:allow(workspace.transport.RelayMachineConnector)
	private function useSocket(attempt:RpcConnectAttempt):Void {
		if (finished)
			attempt.cancel();
		else
			socketAttempt = attempt;
	}

	@:allow(workspace.transport.RelayMachineConnector)
	private function finish():Bool {
		if (finished)
			return false;
		finished = true;
		ticketAttempt = null;
		socketAttempt = null;
		finishOwner();
		return true;
	}

	function finishOwner():Void {
		var callback = onTerminal;
		onTerminal = null;
		if (callback != null)
			callback(this);
	}
}
