package noisekit;

import haxe.io.Bytes;
import noisekit.ffi.NoiseKit;
import noisekit.ffi.NoiseKitTypes.Handshake;

/** Managed owner for one Noise XX handshake and its split cipher states. */
class NoiseSession {
    public static inline final INITIATOR = 0;
    public static inline final RESPONDER = 1;
    public static inline final WRITE_MESSAGE = 0x4101;
    public static inline final READ_MESSAGE = 0x4102;
    public static inline final SPLIT = 0x4103;
    public static inline final COMPLETE = 0x4105;
    public static inline final MAX_MESSAGE_BYTES = 65519;

    var state:Null<Handshake>;

    private function new(state:Handshake) {
        this.state = state;
    }

    public static function generateKeypair():NoiseKeypair {
        var result = NoiseKit.noisekit_keypair_generate();
        check(result.status, "keypair.generate");
        if (result.private_key.length != 32 || result.public_key.length != 32)
            throw "NoiseKit returned an invalid keypair size";
        return {privateKey: result.private_key, publicKey: result.public_key};
    }

    public static function publicKey(privateKey:Bytes):Bytes {
        if (privateKey == null || privateKey.length != 32)
            throw "Invalid Noise static private key";
        var result = NoiseKit.noisekit_public_key(privateKey);
        check(result.status, "keypair.publicKey");
        if (result.public_key.length != 32)
            throw "NoiseKit returned an invalid public key size";
        return result.public_key;
    }

    public static function create(role:Int, staticPrivateKey:Bytes, prologue:Bytes):NoiseSession {
        if (staticPrivateKey == null || staticPrivateKey.length != 32 || prologue == null || prologue.length > 1024)
            throw "Invalid Noise handshake input";
        var result = NoiseKit.noisekit_handshake_create(role, staticPrivateKey, prologue);
        check(result.status, "handshake.create");
        if (result.out_state == null)
            throw "NoiseKit did not return a handshake state";
        return new NoiseSession(result.out_state);
    }

    public function action():Int
        return NoiseKit.noisekit_handshake_action(live());

    public function write():Bytes {
        var result = NoiseKit.noisekit_handshake_write(live());
        check(result.status, "handshake.write");
        return result.message;
    }

    public function read(message:Bytes):Void {
        if (message == null || message.length == 0 || message.length > MAX_MESSAGE_BYTES)
            throw "Invalid Noise handshake message size";
        check(NoiseKit.noisekit_handshake_read(live(), message), "handshake.read");
    }

    public function remoteStatic():Bytes {
        var result = NoiseKit.noisekit_handshake_remote_static(live());
        check(result.status, "handshake.remoteStatic");
        return result.public_key;
    }

    public function handshakeHash():Bytes {
        var result = NoiseKit.noisekit_handshake_hash(live());
        check(result.status, "handshake.hash");
        return result.hash;
    }

    public function encrypt(plaintext:Bytes):Bytes {
        if (plaintext == null || plaintext.length > MAX_MESSAGE_BYTES)
            throw "Invalid Noise plaintext size";
        var result = NoiseKit.noisekit_encrypt(live(), plaintext);
        check(result.status, "transport.encrypt");
        return result.ciphertext;
    }

    public function decrypt(ciphertext:Bytes):Bytes {
        if (ciphertext == null || ciphertext.length < 16 || ciphertext.length > MAX_MESSAGE_BYTES + 16)
            throw "Invalid Noise ciphertext size";
        var result = NoiseKit.noisekit_decrypt(live(), ciphertext);
        check(result.status, "transport.decrypt");
        return result.plaintext;
    }

    public function close():Void {
        if (state == null)
            return;
        var closing = state;
        state = null;
        check(NoiseKit.noisekit_handshake_free(closing), "handshake.free");
    }

    function live():Handshake {
        if (state == null)
            throw "Noise session is closed";
        return state;
    }

    static function check(status:Int, operation:String):Void {
        if (status != 0)
            throw 'NoiseKit ${operation} failed (${status})';
    }
}

typedef NoiseKeypair = {
    var privateKey:Bytes;
    var publicKey:Bytes;
}
