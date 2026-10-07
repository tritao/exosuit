package workspace.transport;

import haxe.io.Bytes;

/** One opaque relay-channel message after its routing envelope is removed. */
class RelayFrame {
	public final channelId:String;
	public final payload:Bytes;
	public final reset:Bool;

	public function new(channelId:String, payload:Bytes, reset:Bool = false) {
		this.channelId = channelId;
		this.payload = payload;
		this.reset = reset;
	}
}
