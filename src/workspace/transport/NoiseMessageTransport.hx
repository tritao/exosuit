package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import noisekit.NoiseSession;

/** Encrypts each RPC message into one bounded relay-channel message. */
class NoiseMessageTransport implements MessageTransport {
    public static inline final FRAME_BYTES:Int = 1;
    public static inline final MAX_PLAINTEXT_BYTES:Int = RelaySocketLink.MAX_MESSAGE_BYTES - FRAME_BYTES - 16;
    static inline final ENCRYPTED_FRAME:Int = 2;

    public var failure(default, null):Null<String>;
    final inner:MessageTransport;
    final session:NoiseSession;
    var pendingCiphertext:Null<Bytes>;
    var pendingPlaintext:Null<Bytes>;
    var terminal:Bool = false;

    public function new(inner:MessageTransport, session:NoiseSession) {
        if (inner == null || !inner.isOpen() || session == null)
            throw "Noise transport requires an open channel and established session";
        this.inner = inner;
        this.session = session;
    }

    public function isOpen():Bool
        return !terminal && inner.isOpen();

    public function send(message:Bytes):Bool {
        if (!isOpen())
            return false;
        if (message == null || message.length > MAX_PLAINTEXT_BYTES) {
            fail("noise_message_too_large");
            return false;
        }
        if (pendingCiphertext != null) {
            if (!sameBytes(message, pendingPlaintext))
                return false;
            if (!inner.send(pendingCiphertext)) {
                if (!inner.isOpen()) fail("noise_send_failed");
                return false;
            }
            pendingCiphertext = null;
            pendingPlaintext = null;
            return true;
        }
        try {
            var ciphertext = session.encrypt(message);
            var frame = Bytes.alloc(FRAME_BYTES + ciphertext.length);
            frame.set(0, ENCRYPTED_FRAME);
            frame.blit(FRAME_BYTES, ciphertext, 0, ciphertext.length);
            if (frame.length > RelaySocketLink.MAX_MESSAGE_BYTES) {
                fail("noise_message_too_large");
                return false;
            }
            if (inner.send(frame))
                return true;
            if (!inner.isOpen()) {
                fail("noise_send_failed");
                return false;
            }
            // Encryption advances the send nonce, so preserve this exact frame
            // until the underlying transport accepts it.
            pendingCiphertext = frame;
            pendingPlaintext = message;
            return false;
        } catch (_:Dynamic) {
            fail("noise_encrypt_failed");
            return false;
        }
    }

    public function receive():Null<Bytes> {
        if (!isOpen())
            return null;
        var frame = inner.receive();
        if (frame == null)
            return null;
        if (frame.length < FRAME_BYTES + 16 || frame.length > RelaySocketLink.MAX_MESSAGE_BYTES
            || frame.get(0) != ENCRYPTED_FRAME) {
            fail("invalid_noise_frame");
            return null;
        }
        try
            return session.decrypt(frame.sub(FRAME_BYTES, frame.length - FRAME_BYTES))
        catch (_:Dynamic) {
            fail("noise_decrypt_failed");
            return null;
        }
    }

    public function close():Void
        fail("closed");

    static function sameBytes(left:Bytes, right:Null<Bytes>):Bool {
        if (left == null || right == null || left.length != right.length)
            return false;
        var difference = 0;
        for (index in 0...left.length)
            difference |= left.get(index) ^ right.get(index);
        return difference == 0;
    }

    function fail(reason:String):Void {
        if (terminal)
            return;
        terminal = true;
        failure = reason;
        pendingCiphertext = null;
        pendingPlaintext = null;
        try session.close() catch (_:Dynamic) {}
        try inner.close() catch (_:Dynamic) {}
    }
}
