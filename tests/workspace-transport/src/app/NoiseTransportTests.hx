package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import noisekit.NoiseSession;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoisePrologue;
import workspace.transport.NoiseServerHandshake;
import workspace.transport.WorkspaceRpcServer;

private typedef HandshakePair = {
    var server:Null<NoiseMessageTransport>;
    var client:Null<NoiseMessageTransport>;
    var machine:MemoryTransport;
    var device:MemoryTransport;
    var serverHandshake:NoiseServerHandshake;
    var clientHandshake:NoiseClientHandshake;
}

class NoiseTransportTests {
    static function require(value:Bool, message:String):Void {
        if (!value)
            throw 'Noise transport test failed: ${message}';
    }

    static function handshake(machinePrivate:Bytes, machinePublic:Bytes, expectedDevicePublic:Bytes, devicePrivate:Bytes,
        serverPrologue:Bytes, clientPrologue:Bytes, maxMessages:Int = 4):HandshakePair {
        var pair = MemoryTransport.pair(1024 * 1024, maxMessages);
        var now = 0.0, authenticated:Null<NoiseMessageTransport> = null, clientAuthenticated:Null<NoiseMessageTransport> = null;
        var serverHandshake = new NoiseServerHandshake(pair.server, machinePrivate,
            expectedDevicePublic, serverPrologue, function() return now,
            function(transport) authenticated = transport);
        var clientHandshake = new NoiseClientHandshake(pair.client, devicePrivate, machinePublic,
            clientPrologue, function() return now, function(transport) clientAuthenticated = transport);
        for (_ in 0...12) {
            serverHandshake.poll();
            clientHandshake.poll();
            if (serverHandshake.finished && clientHandshake.finished)
                break;
        }
        return {server: authenticated, client: clientAuthenticated, machine: pair.server, device: pair.client,
            serverHandshake: serverHandshake, clientHandshake: clientHandshake};
    }

    public static function run():Void {
        var machineId = "0123456789abcdef0123456789abcdef";
        var deviceId = "fedcba9876543210fedcba9876543210";
        var prologue = NoisePrologue.encode(machineId, deviceId);
        var machineKeys = NoiseSession.generateKeypair();
        var deviceKeys = NoiseSession.generateKeypair();

        // A pinned key completes Noise XX before the caller receives any RPC transport.
        var approved = handshake(machineKeys.privateKey, machineKeys.publicKey, deviceKeys.publicKey, deviceKeys.privateKey,
            prologue, prologue, 1);
        require(approved.serverHandshake.finished && approved.serverHandshake.failure == null && approved.server != null,
            "registered device completes Noise XX before admission");
        require(approved.clientHandshake.finished && approved.clientHandshake.failure == null && approved.client != null,
            "client pins machine identity before opening RPC");
        var securedClient = approved.client;
        var first = Bytes.ofString("rpc request one"), second = Bytes.ofString("rpc request two");
        require(approved.server.send(first), "first ciphertext accepted");
        require(!approved.server.send(second), "backpressured ciphertext is retained");
        require(equal(securedClient.receive(), first), "first RPC payload decrypts");
        require(approved.server.send(second), "same ciphertext retries without advancing the nonce");
        require(equal(securedClient.receive(), second), "second RPC payload decrypts after retry");
        securedClient.close();

        // The real RPC handshake and service binding inherit the device grant subset.
        var rpcMachine = NoiseSession.generateKeypair(), rpcDevice = NoiseSession.generateKeypair();
        var rpcPair = handshake(rpcMachine.privateKey, rpcMachine.publicKey, rpcDevice.publicKey, rpcDevice.privateKey,
            prologue, prologue, 64);
        require(rpcPair.server != null && rpcPair.client != null, "RPC test channels authenticated");
        var rpcClock = function() return 0.0;
        var rpcClientTransport:NoiseMessageTransport = cast rpcPair.client;
        var service = new WorkspaceService("workspace", "epoch", [
            {id: "work", name: "Work", cwd: "/workspace", revision: 1}
        ]);
        var rpcServer = new WorkspaceRpcServer(service, rpcClock);
        rpcServer.acceptRemote(cast rpcPair.server, [WorkspaceProtocol.READ]);
        var clientOptions = new RpcPeerOptions("exosuit-agent/1",
            [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE], [], 1000, 262144, 32, 1048576);
        var rpcHandshake = RpcHandshake.client(rpcClientTransport, rpcClock, clientOptions, clientOptions.offered());
        for (_ in 0...8) {
            rpcHandshake.poll();
            rpcServer.poll();
        }
        require(rpcHandshake.connection != null && rpcServer.clientCount() == 1,
            "RPC starts over the established authenticated channel");
        require(rpcHandshake.capabilities().indexOf(WorkspaceProtocol.WRITE) < 0,
            "RPC capability negotiation cannot widen device grants");
        var rpcConnection = rpcHandshake.connection;
        var denied = "";
        rpcConnection.call(WorkspaceProtocol.RENAME, {
            workspace: "workspace", epoch: "epoch", operation: "remote-write",
            group: "work", expectedRevision: 1, name: "Denied"
        }, 1000, function(_) throw "Remote write exceeded the device grant",
            function(error) denied = error.code);
        for (_ in 0...8) {
            rpcServer.poll();
            rpcConnection.poll();
        }
        require(denied == "unauthorized" && service.snapshot().groups[0].name == "Work",
            "service methods enforce the narrowed grant list");
        rpcServer.dispose();
        rpcClientTransport.close();
        wipe(rpcMachine.privateKey);
        wipe(rpcDevice.privateKey);
        wipe(machineKeys.privateKey);
        wipe(deviceKeys.privateKey);

        // A different device static key is refused after XX and never reaches RPC.
        var machineForMismatch = NoiseSession.generateKeypair();
        var expectedDevice = NoiseSession.generateKeypair();
        var unknownDevice = NoiseSession.generateKeypair();
        var mismatch = handshake(machineForMismatch.privateKey, machineForMismatch.publicKey,
            expectedDevice.publicKey, unknownDevice.privateKey, prologue, prologue);
        require(mismatch.serverHandshake.finished && mismatch.serverHandshake.failure == "noise_identity_mismatch"
            && mismatch.server == null, "unknown static identity is refused before RPC");
        if (mismatch.client != null) mismatch.client.close();
        mismatch.serverHandshake.close();
        wipe(machineForMismatch.privateKey);
        wipe(expectedDevice.privateKey);
        wipe(unknownDevice.privateKey);

        // The browser side also refuses an unrecognized machine static key.
        var machineForPin = NoiseSession.generateKeypair();
        var deviceForPin = NoiseSession.generateKeypair();
        var pinnedWrongMachine = NoiseSession.generateKeypair();
        var clientPinMismatch = handshake(machineForPin.privateKey, pinnedWrongMachine.publicKey,
            deviceForPin.publicKey, deviceForPin.privateKey, prologue, prologue);
        require(clientPinMismatch.clientHandshake.failure == "noise_identity_mismatch"
            && clientPinMismatch.client == null, "client refuses a machine key outside its pin");
        clientPinMismatch.serverHandshake.close();
        wipe(machineForPin.privateKey);
        wipe(deviceForPin.privateKey);
        wipe(pinnedWrongMachine.privateKey);

        // Altering the machine/device route context fails the Noise transcript check.
        var machineForRoute = NoiseSession.generateKeypair();
        var deviceForRoute = NoiseSession.generateKeypair();
        var wrongRoute = NoisePrologue.encode(machineId, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        var routeMismatch = handshake(machineForRoute.privateKey, machineForRoute.publicKey, deviceForRoute.publicKey,
            deviceForRoute.privateKey, prologue, wrongRoute);
        require(routeMismatch.clientHandshake.failure != null && routeMismatch.client == null
            && routeMismatch.server == null,
            "route mismatch never creates an RPC channel");
        routeMismatch.serverHandshake.close();
        wipe(machineForRoute.privateKey);
        wipe(deviceForRoute.privateKey);

        Sys.println("PASS: Noise admission, pinned identity, encrypted messages and nonce-safe backpressure");
    }

    static function equal(left:Null<Bytes>, right:Bytes):Bool {
        if (left == null || left.length != right.length)
            return false;
        var difference = 0;
        for (index in 0...left.length)
            difference |= left.get(index) ^ right.get(index);
        return difference == 0;
    }

    static function wipe(bytes:Bytes):Void {
        for (index in 0...bytes.length)
            bytes.set(index, 0);
    }
}
