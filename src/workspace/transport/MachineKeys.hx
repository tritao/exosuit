package workspace.transport;

import haxe.crypto.Sha256;
import haxe.io.Bytes;

/**
	Values derived from a machine's Noise static public key (32 bytes). exohost, the phone and the relay Worker
	(`relay/worker/src/index.ts`) compute the same ones; `docs/mobile/relay-identity.md` describes them.

	- `fingerprint`: what an invitation carries (`#mk=` in its URL) so the phone can check, after the handshake, that it
	  reached the machine that made the invitation. The first 16 bytes of SHA-256(key), as 32 hex digits.
	- `relayId`: the id a machine takes on a relay. The first 16 bytes of SHA-256("exosuit-relay-id/1" + key), as 32 hex
	  digits, so a relay can check that a registration comes from the key's holder (`registrationProof`).
	- `registrationProof`: HMAC-SHA256, keyed with the X25519 secret the machine's key shares with the relay's one-use
	  challenge key, over "exosuit-relay-register/1", the relay id, the challenge key and SHA-256 of the bearer being
	  registered. Only the holder of the machine's private key can make it, and it is bound to that bearer.
**/
class MachineKeys {
	public static inline final RELAY_ID_CONTEXT = "exosuit-relay-id/1";
	public static inline final PROOF_CONTEXT = "exosuit-relay-register/1";
	/** What an invitation URL puts before the fingerprint. */
	public static inline final URL_FRAGMENT = "#mk=";

	public static function fingerprint(publicKey:Bytes):String {
		requireKey(publicKey);
		return hex(Sha256.make(publicKey), 16);
	}

	public static function relayId(publicKey:Bytes):String {
		requireKey(publicKey);
		return hex(Sha256.make(concat([Bytes.ofString(RELAY_ID_CONTEXT), publicKey])), 16);
	}

	/** Whether `relayId` was derived from this key (relays set up before ids were derived keep the catalog id, which was not). */
	public static function derived(relayId:String, publicKey:Bytes):Bool
		return publicKey != null && publicKey.length == 32 && relayId == MachineKeys.relayId(publicKey);

	/** True for 32 lowercase hex digits, the shape of a fingerprint. */
	public static function isFingerprint(value:Null<String>):Bool
		return value != null && ~/^[0-9a-f]{32}$/.match(value);

	/** `shared` is the X25519 result of the machine's private key and the challenge key; `machineToken` the bearer (64 hex digits). */
	public static function registrationProof(shared:Bytes, relayId:String, challenge:Bytes, machineToken:String):String {
		if (shared == null || shared.length != 32 || challenge == null || challenge.length != 32 || !~/^[0-9a-f]{32}$/.match(relayId))
			throw "Invalid relay registration proof input";
		var message = concat([Bytes.ofString(PROOF_CONTEXT), fromHex(relayId), challenge, Sha256.make(Bytes.ofString(machineToken))]);
		return hex(hmacSha256(shared, message), 32);
	}

	/** HMAC-SHA256 (RFC 2104) for a key of at most one block. */
	public static function hmacSha256(key:Bytes, message:Bytes):Bytes {
		if (key == null || key.length > 64)
			throw "Invalid HMAC key";
		var inner = Bytes.alloc(64), outer = Bytes.alloc(64);
		for (index in 0...64) {
			var value = index < key.length ? key.get(index) : 0;
			inner.set(index, value ^ 0x36);
			outer.set(index, value ^ 0x5c);
		}
		return Sha256.make(concat([outer, Sha256.make(concat([inner, message]))]));
	}

	public static function hex(bytes:Bytes, length:Int):String {
		var output = new StringBuf();
		for (index in 0...length) {
			var value = bytes.get(index);
			output.addChar("0123456789abcdef".charCodeAt(value >>> 4));
			output.addChar("0123456789abcdef".charCodeAt(value & 0xf));
		}
		return output.toString();
	}

	public static function fromHex(value:String):Bytes {
		if (value == null || value.length % 2 != 0 || !~/^[0-9a-f]*$/.match(value))
			throw "invalid_hex_bytes";
		var result = Bytes.alloc(Std.int(value.length / 2));
		for (index in 0...result.length)
			result.set(index, ("0123456789abcdef".indexOf(value.charAt(index * 2)) << 4) | "0123456789abcdef".indexOf(value.charAt(index * 2 + 1)));
		return result;
	}

	static function requireKey(publicKey:Bytes):Void {
		if (publicKey == null || publicKey.length != 32)
			throw "A machine key is 32 bytes";
	}

	static function concat(parts:Array<Bytes>):Bytes {
		var total = 0;
		for (part in parts)
			total += part.length;
		var result = Bytes.alloc(total);
		var at = 0;
		for (part in parts) {
			result.blit(at, part, 0, part.length);
			at += part.length;
		}
		return result;
	}
}
