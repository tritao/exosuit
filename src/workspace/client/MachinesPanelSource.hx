package workspace.client;

import workspace.service.MachineDirectoryProtocol.MachineWorkspaceEntry;

/** One paired machine as a machines list shows it, copied when asked (MachinesPanelSource.pairedMachines). */
class PairedMachineCard {
	public final machineId:String;
	public final deviceId:String;
	public final name:String;
	public final online:Bool;
	/** Why the pairing is dead for good, as a sentence; null while it works or is only offline. */
	public final refusal:Null<String>;
	/** The machine connection's last error, if any. */
	public final error:Null<String>;
	/** The workspaces the machine grants this device; null until its directory has been read. */
	public final workspaces:Null<Array<MachineWorkspaceEntry>>;

	public function new(machineId:String, deviceId:String, name:String, online:Bool, refusal:Null<String>, error:Null<String>,
			workspaces:Null<Array<MachineWorkspaceEntry>>) {
		this.machineId = machineId;
		this.deviceId = deviceId;
		this.name = name;
		this.online = online;
		this.refusal = refusal;
		this.error = error;
		this.workspaces = workspaces;
	}
}

/**
	What a machines screen reads and does with a device's paired machines (RemoteMachines implements it), as methods,
	so a shell that cannot depend on RemoteMachines (the desktop build has no Noise) holds this instead of a Dynamic.
**/
interface MachinesPanelSource {
	/** The paired machines, in the order they were paired. */
	function pairedMachines():Array<PairedMachineCard>;

	/** True while a pairing is in progress (connecting, comparing the code, waiting for approval). */
	function pairingActive():Bool;

	/** The code to compare with the machine, once the pairing has one. */
	function pairingCode():Null<String>;

	function pairingCodeConfirmed():Bool;

	/** The machine's key differs from the one already paired. */
	function pairingMachineKeyChanged():Bool;

	/** What the panel says: the pairing's progress while one runs, else the connection's. */
	function panelStatus():String;

	function panelError():Null<String>;

	/** Starts pairing with a one-time invitation URL; false when it could not start. */
	function beginPairing(url:String):Bool;

	/** The user compared the code with the machine's. */
	function confirmCode():Void;

	function cancelPairing():Void;

	/** Opens workspace `workspace` of the paired machine (machineId, deviceId). */
	function openMachineWorkspace(machineId:String, deviceId:String, workspace:String):Void;

	/** Forgets a paired machine on this device. */
	function forget(machineId:String, deviceId:String):Void;
}
