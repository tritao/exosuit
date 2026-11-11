package workspace.transport;

import haxe.io.Bytes;
import noisekit.NoiseSession;

/**
	Proves to a relay that the machine registering a relay id holds the Noise key the id is derived from
	(`MachineKeys.relayId`), so a relay id someone else registered first can be taken back (docs/mobile/relay-identity.md).
	Only a relay id derived from the key can be proven; `forKey` gives null for any other (a relay set up before ids were
	derived keeps the catalog id and first-come registration).
**/
class RelayRegistrationProver {
	public final relayId:String;
	final privateKey:Bytes;
	final publicKey:Bytes;

	function new(relayId:String, privateKey:Bytes, publicKey:Bytes) {
		this.relayId = relayId;
		this.privateKey = privateKey;
		this.publicKey = publicKey;
	}

	/** `privateKey` is the machine's Noise static key, borrowed: it stays owned (and wiped) by the identity holding it. */
	public static function forKey(relayId:String, privateKey:Bytes, publicKey:Bytes):Null<RelayRegistrationProver>
		return privateKey != null && privateKey.length == 32 && MachineKeys.derived(relayId, publicKey) ? new RelayRegistrationProver(relayId, privateKey,
			publicKey) : null;

	/** The JSON body of a proven registration for this challenge (the relay's one-use X25519 key, 64 hex digits) and bearer. */
	public function body(challengeHex:String, machineToken:String):String {
		var challenge = MachineKeys.fromHex(challengeHex);
		if (challenge.length != 32)
			throw "invalid_relay_challenge";
		var shared = NoiseSession.sharedSecret(privateKey, challenge);
		var proof:Null<String> = null;
		var failure:Null<Dynamic> = null;
		try proof = MachineKeys.registrationProof(shared, relayId, challenge, machineToken) catch (error:Dynamic) failure = error;
		wipe(shared);
		if (proof == null)
			throw failure == null ? "invalid_relay_proof" : failure;
		return haxe.Json.stringify({publicKey: MachineKeys.hex(publicKey, 32), challenge: challengeHex, proof: proof});
	}

	static function wipe(bytes:Bytes):Void
		for (index in 0...bytes.length)
			bytes.set(index, 0);
}
