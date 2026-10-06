package app;

import haxe.io.Bytes;
import noisekit.NoiseSession;

class Main {
    static function main():Void {
        var initiatorKeys = NoiseSession.generateKeypair();
        var responderKeys = NoiseSession.generateKeypair();
        var prologue = Bytes.ofString("exosuit-noise-binding-contract-v1");
        var initiator = NoiseSession.create(NoiseSession.INITIATOR, initiatorKeys.privateKey, prologue);
        var responder = NoiseSession.create(NoiseSession.RESPONDER, responderKeys.privateKey, prologue);
        try {
            require(initiator.action() == NoiseSession.WRITE_MESSAGE, "initiator starts with write");
            var first = initiator.write();
            responder.read(first);
            var second = responder.write();
            initiator.read(second);
            var third = initiator.write();
            responder.read(third);
            require(initiator.action() == NoiseSession.COMPLETE, "initiator handshake complete");
            require(responder.action() == NoiseSession.COMPLETE, "responder handshake complete");
            require(equal(initiator.remoteStatic(), responderKeys.publicKey), "initiator verifies responder key");
            require(equal(responder.remoteStatic(), initiatorKeys.publicKey), "responder verifies initiator key");
            require(equal(initiator.handshakeHash(), responder.handshakeHash()), "matching transcript hash");
            var payload = Bytes.ofString("MessagePack-shaped test payload");
            require(equal(responder.decrypt(initiator.encrypt(payload)), payload), "initiator encrypts to responder");
            require(equal(initiator.decrypt(responder.encrypt(payload)), payload), "responder encrypts to initiator");
            Sys.println("PASS: managed Haxe NoiseKit FFI round trip");
        } catch (error:Dynamic) {
            initiator.close();
            responder.close();
            wipe(initiatorKeys.privateKey);
            wipe(responderKeys.privateKey);
            throw error;
        }
        initiator.close();
        responder.close();
        wipe(initiatorKeys.privateKey);
        wipe(responderKeys.privateKey);
    }

    static function equal(left:Bytes, right:Bytes):Bool {
        if (left == null || right == null || left.length != right.length)
            return false;
        var difference = 0;
        for (index in 0...left.length)
            difference |= left.get(index) ^ right.get(index);
        return difference == 0;
    }

    static function require(condition:Bool, message:String):Void {
        if (!condition)
            throw 'NoiseKit Haxe contract failed: ${message}';
    }

    static function wipe(value:Bytes):Void {
        for (index in 0...value.length)
            value.set(index, 0);
    }
}
