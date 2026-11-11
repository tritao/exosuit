package app;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.Runtime;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcMethod;
import haxeon.rpc.RpcPeerOptions;
import nativekit.ffi.NativeKit;
import noisekit.NoiseSession;
import workspace.client.MachineClient;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.transport.MachineKeys;
import workspace.transport.DeviceRpcConnector;
import workspace.transport.StreamMultiplexer;
import workspace.transport.StreamMultiplexer.MuxStream;
import workspace.transport.NativeRpcHub;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.RelayDeviceTransport;
import workspace.transport.RelayMachineEndpoint;

/** One RPC connection a device opened (on stream 0 or on a workspace stream), polled by the test loop. */
private class Link {
	public var connection:Null<RpcConnection>;
	public var failure:Null<String>;
	public var changes:Int = 0;
	final shake:RpcHandshake;

	public function new(transport:MessageTransport, clock:Void->Float, application:String, capabilities:Array<String>) {
		var options = new RpcPeerOptions(application, capabilities, [], 20000, 65000, 16, 400000);
		shake = RpcHandshake.client(transport, clock, options, capabilities);
	}

	public function pump():Void {
		var current = connection;
		if (current != null) {
			current.poll(32, 400000);
			return;
		}
		shake.poll();
		if (shake.isFinished()) {
			connection = shake.connection;
			if (connection == null)
				failure = "handshake failed";
		}
	}
}

/**
	Headless integration test for machine-level remote access (M19 Phase 9). scripts/test-machine-remote.py starts a
	local relay Worker and an isolated suit, then runs this program. It is the owner's editor (suit control ops through
	MachineClient) and a fake phone (Noise over the relay):

	  two workspaces under one suit; the device pairs once, is granted workspace A only, sees A (not B) in the
	  directory, opens A and reads its catalog; granting B makes B appear and openable; dropping B closes its stream;
	  the device reconnects with its saved credentials; revoking it closes the channel and refuses a new one.
**/
class MachineRemoteTestMain {
	static var runtime:Runtime;
	static var hub:NativeRpcHub;
	static var machine:MachineClient;
	static var links:Array<Link> = [];
	static var streamsList:Array<StreamMultiplexer> = [];
	static var extra:Array<Void->Void> = [];
	static var checks = 0;

	static function clock():Float
		return NativeKit.nk_time_seconds() * 1000;

	static function pump():Void {
		runtime.events.wait(0.01);
		for (_ in 0...128)
			if (!runtime.events.poll())
				break;
		machine.poll();
		for (streams in streamsList)
			streams.poll();
		for (link in links)
			link.pump();
		for (work in extra)
			work();
	}

	static function await(what:String, seconds:Float, until:Void->Bool):Void {
		var deadline = clock() + seconds * 1000;
		while (!until()) {
			if (clock() >= deadline)
				throw "timed out waiting for: " + what;
			pump();
		}
	}

	static function check(condition:Bool, what:String):Void {
		if (!condition)
			throw "FAILED: " + what;
		checks++;
		Sys.println("ok: " + what);
	}

	/** Runs a control op against suit and waits for its reply: `{reply, error}`. */
	static function ctl(what:String, start:((Null<Dynamic>, Null<String>) -> Void) -> Void):Dynamic {
		var done = false, reply:Null<Dynamic> = null, error:Null<String> = null;
		start(function(value, problem) {
			reply = value;
			error = problem;
			done = true;
		});
		await(what, 40, function() return done);
		return {reply: reply, error: error};
	}

	static function ctlOk(what:String, start:((Null<Dynamic>, Null<String>) -> Void) -> Void):Dynamic {
		var result = ctl(what, start);
		if (result.error != null)
			throw what + " failed: " + result.error;
		return result.reply;
	}

	static function call<Q, R>(connection:RpcConnection, method:RpcMethod<Q, R>, request:Q, seconds:Int = 10):Dynamic {
		var done = false, value:Null<R> = null, code:Null<String> = null;
		connection.call(method, request, seconds * 1000, function(response) {
			value = response;
			done = true;
		}, function(error) {
			code = error.code;
			done = true;
		});
		await("an RPC answer", seconds + 5, function() return done);
		return {value: value, error: code};
	}

	static function link(transport:MessageTransport, application:String, capabilities:Array<String>):Link {
		var made = new Link(transport, clock, application, capabilities);
		links.push(made);
		await("a handshake on " + application, 20, function() return made.connection != null || made.failure != null);
		if (made.connection == null)
			throw "handshake failed on " + application;
		return made;
	}

	static function directory(device:Link):MachineDirectory {
		var answer = call(device.connection, MachineDirectoryProtocol.DIRECTORY, {machine: null});
		if (answer.error != null)
			throw "directory failed: " + answer.error;
		return answer.value;
	}

	static function listed(directory:MachineDirectory, workspace:String):Bool {
		for (entry in directory.workspaces)
			if (entry.workspace == workspace)
				return true;
		return false;
	}

	/** Opens `workspace` and reads its catalog on the new stream; the result has the stream and the page, or an error code. */
	static function openAndRead(streams:StreamMultiplexer, device:Link, machineId:String, workspace:String):Dynamic {
		var opened = call(device.connection, MachineDirectoryProtocol.OPEN, {ref: {machine: machineId, workspace: workspace}}, 40);
		if (opened.error != null)
			return {error: opened.error};
		var stream = streams.open(opened.value.stream);
		var service = link(stream, "exosuit-phone/1", [WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceCatalogProtocol.CAPABILITY]);
		var page = call(service.connection, WorkspaceCatalogProtocol.CATALOG,
			{ref: {machine: machineId, workspace: workspace}, resume: null, watch: false});
		return {error: page.error, stream: stream, page: page.value, grants: opened.value.grants};
	}

	static function hex(bytes:Bytes):String {
		var out = new StringBuf();
		for (index in 0...bytes.length)
			out.add(StringTools.hex(bytes.get(index), 2).toLowerCase());
		return out.toString();
	}

	static function main():Void {
		var args = Sys.args(), origin:Null<String> = null, folderA:Null<String> = null, folderB:Null<String> = null;
		var index = 0;
		while (index < args.length) {
			switch args[index++] {
				case "--origin": origin = args[index++];
				case "--folder-a": folderA = args[index++];
				case "--folder-b": folderB = args[index++];
				case other: throw "Unknown option: " + other;
			}
		}
		if (origin == null || folderA == null || folderB == null)
			throw "--origin, --folder-a and --folder-b are required";
		runtime = Runtime.start();
		hub = new NativeRpcHub(runtime.events);
		machine = new MachineClient(runtime.events, clock);
		var code = 0;
		try
			run(origin, folderA, folderB)
		catch (error:Dynamic) {
			Sys.stderr().writeString("machine remote test failed: " + Std.string(error) + "\n");
			code = 1;
		}
		hub.dispose();
		runtime.dispose();
		if (code == 0)
			Sys.println("PASS: machine remote access (" + checks + " checks)");
		Sys.exit(code);
	}

	static function run(origin:String, folderA:String, folderB:String):Void {
		// Two workspaces, then remote access on this machine's relay identity.
		var a = ctlOk("create A", function(done) machine.create("Alpha", [folderA], function(w, e) done(w, e)));
		var b = ctlOk("create B", function(done) machine.create("Beta", [folderB], function(w, e) done(w, e)));
		var idA:String = a.id, idB:String = b.id;
		ctlOk("enable remote access", function(done) machine.remoteEnable(origin, done));
		await("the machine socket to the relay", 40, function() {
			var current = ctl("status", function(done) machine.remoteStatus(done));
			return current.reply != null && current.reply.connected == true;
		});
		var status = ctlOk("status", function(done) machine.remoteStatus(done));
		var machineId:String = status.machineId;
		check(StringTools.startsWith(machineId, "machine-") && status.relayMachineId != null, "one machine identity: " + machineId);

		// The device pairs with the machine, not with a workspace.
		var invitation = ctlOk("invitation", function(done) machine.remoteInvite(300, done)).invitation;
		var privateKey:Bytes = NoiseSession.generateKeypair().privateKey;
		var deviceId:String = invitation.deviceId, relayMachine:String = invitation.machineId;
		var secure:Null<NoiseMessageTransport> = null, handshake:Null<NoiseClientHandshake> = null, socketFailure:Null<String> = null;
		hub.connectBytes(NativeRpcHub.websocketUrl(invitation.pairingSocketUrl), function(stream, error) {
			if (stream == null) {
				socketFailure = error == null ? "connect_failed" : error;
				return;
			}
			var channel = new RelayDeviceTransport(stream, deviceId);
			handshake = new NoiseClientHandshake(channel, privateKey, null, NoisePrologue.encode(relayMachine, deviceId), clock,
				function(transport) secure = transport);
		});
		var poller = function() {
			var current = handshake;
			if (current != null && !current.finished)
				current.poll();
		};
		extra.push(poller);
		await("the Noise handshake", 30, function() return secure != null || socketFailure != null || handshake != null && handshake.finished);
		extra.remove(poller);
		if (secure == null)
			throw "pairing handshake failed: " + socketFailure;
		var finishedShake = handshake;
		if (finishedShake == null || finishedShake.remoteStaticKey == null || finishedShake.transcriptHash == null)
			throw "the handshake gave no machine key";
		var machineKey:Bytes = finishedShake.remoteStaticKey;
		var shown = NoisePairingCode.fromHandshakeHash(finishedShake.transcriptHash);
		await("the pending device", 20, function() {
			var devices = ctl("devices", function(done) machine.remoteDevices(done)).reply;
			if (devices == null)
				return false;
			for (item in (devices.pending : Array<Dynamic>))
				if (item.deviceId == deviceId)
					return item.authenticationCode == shown;
			return false;
		});
		check(true, "the pairing code matches on both sides (" + shown + ")");
		var before = ctlOk("devices", function(done) machine.remoteDevices(done));
		var choices:Array<Dynamic> = before.workspaces;
		check(choices.length == 2, "suit lists both workspaces for the owner to pick from");

		// Approval grants only workspace A. The device reads the approval and confirms it.
		var approval:Null<Dynamic> = null;
		var read = function() {
			if (approval != null || secure == null)
				return;
			var message = secure.receive();
			if (message != null)
				approval = Json.parse(message.toString());
		};
		extra.push(read);
		var approved = false, approvalError:Null<String> = null, approvalDone = false;
		machine.remoteApprove(deviceId, [{workspace: idA, preset: "read"}], function(reply, error) {
			approved = reply != null;
			approvalError = error;
			approvalDone = true;
		});
		await("the approval message", 40, function() return approval != null || approvalDone);
		if (approval == null)
			throw "approval failed: " + approvalError;
		var message:Dynamic = approval;
		var offered:Array<String> = message.grants;
		check(message.type == "pairing-approved" && message.deviceId == deviceId && offered.length == 1
			&& offered[0] == MachineDirectoryProtocol.CAPABILITY, "pairing grants only the machine directory");
		var token:String = message.deviceToken;
		secure.send(Bytes.ofString(Json.stringify({version: 1, type: "pairing-confirmed", deviceId: deviceId, challenge: message.challenge})));
		await("approval to finish", 30, function() return approvalDone);
		extra.remove(read);
		check(approved, "the owner's approval completed");

		// The same channel now carries the machine stream.
		var streams = new StreamMultiplexer(secure);
		streamsList.push(streams);
		var device = link(streams.machineStream(), MachineDirectoryProtocol.APPLICATION, [MachineDirectoryProtocol.CAPABILITY]);
		device.connection.onNotification(MachineDirectoryProtocol.CHANGED, MachineDirectoryProtocol.decodeChange, function(_) device.changes++);
		var view = directory(device);
		check(view.machine == machineId, "the directory names this machine");
		check(view.relay == relayMachine, "the directory names the relay id the device paired under");
		check(relayMachine != machineId.substr("machine-".length) && MachineKeys.relayId(machineKey) == relayMachine,
			"a new relay gets its own relay id, derived from the machine key the device reached");
		check(listed(view, idA) && !listed(view, idB) && view.workspaces.length == 1, "the directory shows A and not B");
		check(view.workspaces[0].name == "Alpha", "the directory names the workspace");

		// B is refused as if it did not exist; A opens and serves its catalog.
		check(openAndRead(streams, device, machineId, idB).error == "unknown_workspace", "opening B is refused as unknown_workspace");
		var wrong = call(device.connection, MachineDirectoryProtocol.OPEN, {ref: {machine: "machine-" + hex(Bytes.alloc(16)), workspace: idA}});
		check(wrong.error == "machine_mismatch", "a ref to another machine is refused");
		var opened = openAndRead(streams, device, machineId, idA);
		check(opened.error == null, "opening A and reading its catalog works" + (opened.error == null ? "" : " (" + opened.error + ")"));
		check(opened.page.ref.workspace == idA && opened.page.ref.machine == machineId, "the catalog is A's");
		var streamA:MuxStream = opened.stream;
		var running = directory(device);
		check(running.workspaces[0].status == MachineDirectoryProtocol.RUNNING, "opening A started its service");

		// Granting B makes it appear and open.
		var changes = device.changes;
		ctlOk("grant B", function(done) machine.remoteGrant(deviceId, [{workspace: idA, preset: "read"}, {workspace: idB, preset: "read"}], done));
		await("a change notice", 20, function() return device.changes > changes);
		check(listed(directory(device), idB), "granting B shows it in the directory");
		var openedB = openAndRead(streams, device, machineId, idB);
		check(openedB.error == null && openedB.page.ref.workspace == idB && openedB.page.ref.machine == machineId, "B opens and serves its own catalog");
		var streamB:MuxStream = openedB.stream;

		// Taking B away closes its stream and leaves A alone.
		ctlOk("drop B", function(done) machine.remoteGrant(deviceId, [{workspace: idA, preset: "read"}], done));
		await("B's stream to close", 20, function() return !streamB.isOpen());
		check(streamA.isOpen() && !listed(directory(device), idB), "dropping B closes B's stream, leaves A open and hides B");
		check(openAndRead(streams, device, machineId, idB).error == "unknown_workspace", "B no longer opens");

		// The device reconnects with what it saved.
		streams.close();
		streamsList.remove(streams);
		var connector = new DeviceRpcConnector(runtime.events, hub, clock, new RelayMachineEndpoint(origin, relayMachine), relayMachine, deviceId, token,
			privateKey.sub(0, 32), machineKey);
		extra.push(function() connector.poll());
		var reopened:Null<MessageTransport> = null, reconnectFailure:Null<String> = null;
		connector.connect(function(result) {
			switch result {
				case Opened(transport): reopened = transport;
				case Failed(error, _): reconnectFailure = error.code;
			}
		});
		await("the device to reconnect", 40, function() return reopened != null || reconnectFailure != null);
		check(reopened != null, "the device reconnects with its saved credentials" + (reconnectFailure == null ? "" : " (" + reconnectFailure + ")"));
		var again = new StreamMultiplexer(reopened);
		streamsList.push(again);
		var second = link(again.machineStream(), MachineDirectoryProtocol.APPLICATION, [MachineDirectoryProtocol.CAPABILITY]);
		var view2 = directory(second);
		check(view2.workspaces.length == 1 && listed(view2, idA), "after reconnecting, the directory is still A only");
		check(openAndRead(again, second, machineId, idA).error == null, "A still opens after reconnecting");

		// Revoking the device ends its channel and refuses a new one.
		ctlOk("revoke the device", function(done) machine.remoteRevoke(deviceId, done));
		await("the channel to close", 30, function() return !again.isOpen());
		check(!again.isOpen(), "revoking the device closes its channel");
		var retry = new DeviceRpcConnector(runtime.events, hub, clock, new RelayMachineEndpoint(origin, relayMachine), relayMachine, deviceId, token,
			privateKey.sub(0, 32), machineKey);
		extra.push(function() retry.poll());
		var accepted = false, rejected = false;
		retry.connect(function(result) {
			switch result {
				case Opened(transport):
					accepted = true;
					transport.close();
				case Failed(_, _): rejected = true;
			}
		});
		await("the revoked device's connection attempt", 40, function() return accepted || rejected);
		check(rejected, "a revoked device cannot reconnect");

		// The relay can be given up and chosen again (a different one in real use); the config is deleted and enabling works again.
		var off = ctlOk("disable remote access", function(done) machine.remoteDisable(done));
		check(off.enabled == false && off.origin == null, "disabling forgets the relay");
		var reenabled = ctlOk("enable remote access again", function(done) machine.remoteEnable(origin, done));
		check(reenabled.enabled == true, "the relay can be enabled again after disabling");
		await("the machine socket to the relay after re-enabling", 40, function() {
			var current = ctl("status", function(done) machine.remoteStatus(done));
			return current.reply != null && current.reply.connected == true;
		});
	}
}
