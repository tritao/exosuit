import workspace.client.PairingLink;

/** A one-time pairing link from the desktop's Remote Access panel, checked before the phone opens a connection (`PairingLink`). */
class PhoneInvitation {
	/** The pairing socket URL, without the fingerprint fragment: what the phone connects to. */
	public final url:String;
	public final origin:String;
	/** The relay id the phone pairs under. */
	public final machineId:String;
	public final deviceId:String;
	/** The link itself: the machine key fingerprint, if it carries one, and the check against the key the handshake reached. */
	public final link:PairingLink;

	function new(link:PairingLink) {
		this.link = link;
		url = link.socketUrl;
		origin = link.origin;
		machineId = link.relayId;
		deviceId = link.deviceId;
	}

	public static function parse(text:Null<String>):Null<PhoneInvitation> {
		var link = PairingLink.parse(text);
		return link == null ? null : new PhoneInvitation(link);
	}
}
