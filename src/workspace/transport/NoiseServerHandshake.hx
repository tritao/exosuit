package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import noisekit.NoiseSession;

/** Nonblocking responder handshake; no RPC transport exists before key pinning. */
class NoiseServerHandshake {
    static inline final HANDSHAKE_FRAME:Int = 1;
    static inline final MAX_HANDSHAKE_BYTES:Int = 1024;
    static inline final TIMEOUT_MILLISECONDS:Float = 5000;

    public var finished(default, null):Bool = false;
    public var failure(default, null):Null<String>;
    public var remoteStaticKey(default, null):Null<Bytes>;
    public var transcriptHash(default, null):Null<Bytes>;

    final channel:MessageTransport;
    final expectedRemoteKey:Null<Bytes>;
    final clock:Void->Float;
    final deadline:Float;
    final authenticated:NoiseMessageTransport->Void;
    var session:Null<NoiseSession>;
    var outgoing:Null<Bytes>;

    public function new(channel:MessageTransport, localPrivateKey:Bytes, expectedRemoteKey:Null<Bytes>,
        prologue:Bytes, clock:Void->Float, authenticated:NoiseMessageTransport->Void) {
        if (channel == null || !channel.isOpen() || localPrivateKey == null || localPrivateKey.length != 32
            || expectedRemoteKey != null && expectedRemoteKey.length != 32 || prologue == null
            || clock == null || authenticated == null)
            throw "Invalid Noise server handshake configuration";
        this.channel = channel;
        this.expectedRemoteKey = expectedRemoteKey;
        this.clock = clock;
        this.authenticated = authenticated;
        deadline = clock() + TIMEOUT_MILLISECONDS;
        session = NoiseSession.create(NoiseSession.RESPONDER, localPrivateKey, prologue);
    }

    public function poll():Void {
        try
            pollHandshake()
        catch (_:Dynamic)
            fail("noise_handshake_failed");
    }

    function pollHandshake():Void {
        if (finished)
            return;
        if (!channel.isOpen()) {
            fail("noise_disconnected");
            return;
        }
        if (clock() >= deadline) {
            fail("noise_timeout");
            return;
        }
        var current = session;
        if (current == null) {
            fail("noise_state_missing");
            return;
        }
        for (_ in 0...4) {
            if (outgoing != null) {
                if (!channel.send(outgoing)) {
                    if (!channel.isOpen()) fail("noise_send_failed");
                    return;
                }
                outgoing = null;
            }
            var action = current.action();
            if (action == NoiseSession.WRITE_MESSAGE) {
                var message = current.write();
                if (message.length == 0 || message.length > MAX_HANDSHAKE_BYTES) {
                    fail("noise_handshake_too_large");
                    return;
                }
                outgoing = Bytes.alloc(1 + message.length);
                outgoing.set(0, HANDSHAKE_FRAME);
                outgoing.blit(1, message, 0, message.length);
                continue;
            }
            if (action == NoiseSession.COMPLETE) {
                var remoteKey = current.remoteStatic();
                if (expectedRemoteKey != null && !sameKey(remoteKey, expectedRemoteKey)) {
                    fail("noise_identity_mismatch");
                    return;
                }
                remoteStaticKey = remoteKey;
                transcriptHash = current.handshakeHash();
                finished = true;
                session = null;
                var transport = new NoiseMessageTransport(channel, current);
                try
                    authenticated(transport)
                catch (_:Dynamic) {
                    transport.close();
                    failure = "noise_admission_failed";
                }
                return;
            }
            if (action != NoiseSession.READ_MESSAGE) {
                fail("noise_invalid_state");
                return;
            }
            var frame = channel.receive();
            if (frame == null)
                return;
            if (frame.length < 2 || frame.length > MAX_HANDSHAKE_BYTES + 1 || frame.get(0) != HANDSHAKE_FRAME) {
                fail("invalid_noise_handshake_frame");
                return;
            }
            current.read(frame.sub(1, frame.length - 1));
        }
    }

    function sameKey(left:Bytes, right:Bytes):Bool {
        if (left == null || right == null || left.length != 32 || right.length != 32)
            return false;
        var difference = 0;
        for (index in 0...32)
            difference |= left.get(index) ^ right.get(index);
        return difference == 0;
    }

    function fail(reason:String):Void {
        if (finished)
            return;
        finished = true;
        failure = reason;
        outgoing = null;
        if (session != null) {
            try session.close() catch (_:Dynamic) {}
            session = null;
        }
        try channel.close() catch (_:Dynamic) {}
    }

    public function close():Void
        fail("closed");
}
