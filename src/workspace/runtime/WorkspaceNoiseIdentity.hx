package workspace.runtime;

import haxe.io.Bytes;
import noisekit.NoiseSession;
import workspace.transport.RelayFrameCodec;

/** Persistent machine identity whose private half stays in the OS credential store. */
class WorkspaceNoiseIdentity {
    public final publicKey:Bytes;
    final privateKey:Bytes;

    public function new(machineId:String, credentials:WorkspaceCredentialStore) {
        RelayFrameCodec.decodeChannelId(machineId);
        if (credentials == null)
            throw "Workspace credential store is required";
        var account = "noise-static:" + machineId;
        var loaded = credentials.read(account);
        if (loaded == null) {
            var generated = NoiseSession.generateKeypair();
            privateKey = generated.privateKey;
            publicKey = generated.publicKey;
            try
                credentials.write(account, privateKey)
            catch (error:Dynamic) {
                wipe(privateKey);
                throw error;
            }
        } else {
            if (loaded.length != 32) {
                wipe(loaded);
                throw "Invalid stored workspace Noise identity";
            }
            privateKey = loaded;
            try
                publicKey = NoiseSession.publicKey(privateKey)
            catch (error:Dynamic) {
                wipe(privateKey);
                throw error;
            }
        }
    }

    public function privateKeyForHandshake():Bytes
        return privateKey;

    public function dispose():Void
        wipe(privateKey);

    static function wipe(bytes:Bytes):Void {
        if (bytes == null)
            return;
        for (index in 0...bytes.length)
            bytes.set(index, 0);
    }
}
