package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import suit.remote.MachineDeviceSession;
import suit.remote.MachineDeviceStore;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineGrants;
import workspace.service.WorkspaceProtocol;
import workspace.transport.ForwardedStream;
import workspace.transport.ForwardedStream.PushbackTransport;
import workspace.transport.StreamMultiplexer;
import workspace.transport.StreamMultiplexer.MuxStream;

/**
	The machine's remote access in suit (ADR 0005 section 4): what an owner can grant, the device store, the intro
	of a forwarded stream, and a device session served over in-memory transports (directory, open, forwarding, revoking).
	No relay, Noise or service runs here; scripts/test-machine-remote.py runs the real thing.
**/
class MachineRemoteUnitTests {
	static var failures:Int = 0;
	static var granted:Map<String, Array<String>> = [];
	static var revision:Int = 1;
	static var servicePipes:Array<MemoryTransport> = [];

	public static function run():Int {
		failures = 0;
		machineGrants();
		machineDeviceStore();
		forwardedIntro();
		machineDeviceSession();
		return failures;
	}

	static function check(condition:Bool, message:String):Void {
		if (condition)
			return;
		failures++;
		Sys.println("FAIL: " + message);
	}

	/** What an owner can grant: presets name known capabilities and round-trip, anything else is refused. */
	static function machineGrants():Void {
		for (name in [MachineGrants.PRESET_READ, MachineGrants.PRESET_EDIT, MachineGrants.PRESET_ALL]) {
			var grants = MachineGrants.preset(name);
			check(grants != null && MachineGrants.valid(grants) && MachineGrants.presetOf(grants) == name, "preset " + name + " is valid and names itself");
		}
		check(MachineGrants.preset("nonsense") == null, "an unknown preset has no grants");
		var read = MachineGrants.preset("read");
		check(read.indexOf(WorkspaceProtocol.WRITE) < 0 && MachineGrants.preset("edit").indexOf(WorkspaceProtocol.WRITE) >= 0,
			"read does not edit; edit does");
		check(!MachineGrants.valid(["workspace.read", "workspace.read"]) && !MachineGrants.valid(["made.up"]) && !MachineGrants.valid(null)
			&& MachineGrants.valid([]), "grants are known, unique and may be none");
		check(MachineGrants.presetOf(["workspace.read"]) == "custom", "a partial list is custom");
	}

	/** Paired devices and their workspaces survive a restart; a revoked device reaches nothing; a deleted workspace is forgotten. */
	static function machineDeviceStore():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		var base = haxe.io.Path.join([temp, "suit-devices-" + Sys.getPid() + "-" + Std.int(Sys.time())]);
		sys.FileSystem.createDirectory(base);
		var file = haxe.io.Path.join([base, "machine-devices.json"]);
		try {
			var store = new MachineDeviceStore(file);
			var key = Bytes.alloc(32);
			key.set(0, 7);
			store.saveDevice({deviceId: "d1", staticPublicKey: key, grants: [MachineDirectoryProtocol.CAPABILITY], revoked: false});
			store.saveDevice({deviceId: "d2", staticPublicKey: key, grants: [MachineDirectoryProtocol.CAPABILITY], revoked: false});
			check(store.grantsFor("d1", "w1") == null, "pairing grants no workspace");
			var wanted = new Map<String, Array<String>>();
			wanted.set("w1", MachineGrants.preset("read"));
			wanted.set("w2", ["workspace.read"]);
			store.setGrants("d1", wanted);
			store.setGrants("d2", wanted);
			var again = new MachineDeviceStore(file);
			check(again.loadDevices().length == 2 && again.loadDevices()[0].staticPublicKey.get(0) == 7, "devices and their pins persist");
			var first = again.grantsFor("d1", "w1"), second = again.grantsFor("d1", "w2");
			check(first != null && second != null && MachineGrants.presetOf(first) == "read" && second.length == 1, "workspace grants persist");
			again.revokeDevice("d1");
			check(again.grantsFor("d1", "w1") == null && again.loadDevices()[0].revoked, "a revoked device keeps its pin and reaches nothing");
			check(again.forgetWorkspace("w1") && again.grantsFor("d2", "w1") == null && again.grantsFor("d2", "w2") != null,
				"a deleted workspace is forgotten for every device");
			check(!again.forgetWorkspace("w1"), "forgetting a workspace nobody holds changes nothing");
			var third = new MachineDeviceStore(file);
			check(third.grantsFor("d2", "w1") == null && third.loadDevices()[0].revoked, "a forgotten grant and a revocation persist");
		} catch (error:Dynamic)
			{ check(false, "device store: " + Std.string(error)); Sys.println(haxe.CallStack.toString(haxe.CallStack.exceptionStack())); }
		try sys.FileSystem.deleteFile(file) catch (_:Dynamic) {}
		try sys.FileSystem.deleteDirectory(base) catch (_:Dynamic) {}
	}

	static function hexBytes(hex:String):Bytes {
		var result = Bytes.alloc(Std.int(hex.length / 2));
		for (index in 0...result.length)
			result.set(index, Std.parseInt("0x" + hex.substr(index * 2, 2)));
		return result;
	}

	/** The intro a forwarded stream starts with is recognised and checked; a normal client's hello is not one. */
	static function forwardedIntro():Void {
		var intro = ForwardedStream.parse(ForwardedStream.intro("dev", ["workspace.read", "workspace.catalog"]));
		check(intro != null && intro.device == "dev" && intro.grants.length == 2 && intro.grants[1] == "workspace.catalog", "an intro round-trips");
		var hello = hexBytes("8101940101a6746573742f3191ae776f726b73706163652e72656164");
		check(!ForwardedStream.isIntro(hello) && ForwardedStream.parse(hello) == null, "a normal hello is not an intro");
		check(ForwardedStream.isIntro(Bytes.ofString("EXFWnot json")) && ForwardedStream.parse(Bytes.ofString("EXFWnot json")) == null,
			"a malformed intro is an intro that does not parse");
		check(ForwardedStream.parse(Bytes.ofString('EXFW{"version":2,"device":"d","grants":[]}')) == null, "an unknown intro version is refused");
		var pair = MemoryTransport.pair();
		pair.client.send(Bytes.ofString("second"));
		var pushed = new PushbackTransport(Bytes.ofString("first"), pair.server);
		check(pushed.receive().toString() == "first" && pushed.receive().toString() == "second", "a pushed-back message is read before the rest");
	}

	static function machineDeviceSession():Void {
		granted = ["w1" => MachineGrants.preset("read")];
		revision = 1;
		servicePipes = [];
		var host = new FakeMachine();
		var channel = MemoryTransport.pair();
		var clock = function() return Sys.time() * 1000;
		var session = new MachineDeviceSession("dev", channel.server, host, clock);
		var streams = new StreamMultiplexer(channel.client);
		var options = new RpcPeerOptions("test/1", [MachineDirectoryProtocol.CAPABILITY], [], 5000, 65000, 16, 400000);
		var shake = RpcHandshake.client(streams.machineStream(), clock, options, [MachineDirectoryProtocol.CAPABILITY]);
		var device:Null<RpcConnection> = null;
		function pump(until:Void->Bool):Bool {
			var deadline = Sys.time() + 3;
			while (!until() && Sys.time() < deadline) {
				streams.poll();
				session.poll();
				if (device == null) {
					shake.poll();
					if (shake.isFinished())
						device = shake.connection;
				} else
					device.poll(32, 400000);
			}
			return until();
		}
		check(pump(function() return device != null), "a device completes the machine handshake");
		if (device == null)
			return;
		var directory:Null<MachineDirectory> = null;
		var failure:Null<String> = null;
		device.call(MachineDirectoryProtocol.DIRECTORY, {machine: null}, 2000, function(value) directory = value, function(error) failure = error.code);
		pump(function() return directory != null || failure != null);
		check(directory != null && directory.machine == "machine-1" && directory.workspaces.length == 1 && directory.workspaces[0].workspace == "w1"
			&& directory.workspaces[0].status == "idle", "the directory lists only the granted workspace");
		directory = null;
		device.call(MachineDirectoryProtocol.DIRECTORY, {machine: "machine-other"}, 2000, function(value) directory = value, function(error) failure = error.code);
		pump(function() return failure != null);
		check(failure == "machine_mismatch", "a directory for another machine is refused");
		failure = null;
		device.call(MachineDirectoryProtocol.OPEN, {ref: {machine: "machine-1", workspace: "w2"}}, 2000, function(_) {}, function(error) failure = error.code);
		pump(function() return failure != null);
		check(failure == "unknown_workspace", "opening a workspace that is not granted is refused as if it did not exist");
		failure = null;
		device.call(MachineDirectoryProtocol.OPEN, {ref: {machine: "machine-1", workspace: "nope"}}, 2000, function(_) {}, function(error) failure = error.code);
		pump(function() return failure != null);
		check(failure == "unknown_workspace", "opening a workspace that does not exist gives the same answer");
		failure = null;
		device.call(MachineDirectoryProtocol.OPEN, {ref: {machine: "machine-x", workspace: "w1"}}, 2000, function(_) {}, function(error) failure = error.code);
		pump(function() return failure != null);
		check(failure == "machine_mismatch", "a ref to another machine is refused");
		var opened:Null<Int> = null;
		failure = null;
		device.call(MachineDirectoryProtocol.OPEN, {ref: {machine: "machine-1", workspace: "w1"}}, 2000, function(value) opened = value.stream,
			function(error) failure = error.code);
		pump(function() return opened != null || failure != null);
		check(opened != null && opened > 0 && servicePipes.length == 1, "a granted workspace opens a stream to its service");
		if (opened == null)
			return;
		// Frames pass both ways, unread.
		var stream = streams.open(opened);
		var service = servicePipes[0];
		stream.send(Bytes.ofString("to-service"));
		var arrived:Null<String> = null;
		pump(function() {
			var message = service.receive();
			if (message != null)
				arrived = message.toString();
			return arrived != null;
		});
		check(arrived == "to-service", "device frames reach the service unread");
		service.send(Bytes.ofString("from-service"));
		var got:Null<String> = null;
		pump(function() {
			var message = stream.receive();
			if (message != null)
				got = message.toString();
			return got != null;
		});
		check(got == "from-service", "service frames reach the device on the stream");
		// Removing the grant closes the stream on both ends.
		granted = new Map<String, Array<String>>();
		revision++;
		pump(function() return !stream.isOpen());
		check(!stream.isOpen() && !service.isOpen(), "removing a grant closes the device's stream and the service's");
		directory = null;
		device.call(MachineDirectoryProtocol.DIRECTORY, {machine: null}, 2000, function(value) directory = value, function(error) failure = error.code);
		pump(function() return directory != null);
		check(directory != null && directory.workspaces.length == 0, "the directory shrinks with the grants");
		session.close();
		check(!session.isOpen(), "closing the session closes the channel");
	}

	public static function currentRevision():Int
		return revision;

	public static function currentGrants():Map<String, Array<String>>
		return granted;

	public static function addPipe(pipe:MemoryTransport):Void
		servicePipes.push(pipe);
}

/** The machine a device session serves in the unit test: grants come from the test, services are in-memory pipes. */
private class FakeMachine implements MachineSessionHost {
	public function new() {}

	public function machineId():String
		return "machine-1";

	public function revision():Int
		return MachineRemoteUnitTests.currentRevision();

	public function grantsFor(deviceId:String, workspace:String):Null<Array<String>>
		return deviceId == "dev" ? MachineRemoteUnitTests.currentGrants().get(workspace) : null;

	public function directory(deviceId:String):MachineDirectory {
		var listed = [for (workspace => grants in MachineRemoteUnitTests.currentGrants()) {workspace: workspace, name: "Workspace " + workspace, status: "idle", grants: grants}];
		return {machine: "machine-1", name: "test", revision: revision(), workspaces: listed};
	}

	public function openService(deviceId:String, workspace:String, grants:Array<String>, done:Null<MessageTransport>->Null<String>->Void):Void {
		var pipe = MemoryTransport.pair();
		MachineRemoteUnitTests.addPipe(pipe.client);
		done(pipe.server, null);
	}
}
