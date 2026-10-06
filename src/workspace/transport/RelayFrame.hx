package workspace.transport;

import haxe.io.Bytes;

/** One opaque relay-channel message after its routing envelope is removed. */
class RelayFrame {
	public final channelId:String;
	public final payload:Bytes;

	public function new(channelId:String, payload:Bytes) {
		this.channelId = channelId;
		this.payload = payload;
	}
}
