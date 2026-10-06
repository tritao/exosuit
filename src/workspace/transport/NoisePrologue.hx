package workspace.transport;

import haxe.io.Bytes;

/** Canonical Noise context: protocol version, machine route and device route. */
class NoisePrologue {
    static inline final PREFIX:String = "exosuit-workspace-noise-v1";
    public static function encode(machineId:String, deviceId:String):Bytes {
        var machine = RelayFrameCodec.decodeChannelId(machineId);
        var device = RelayFrameCodec.decodeChannelId(deviceId);
        var prefix = Bytes.ofString(PREFIX);
        var result = Bytes.alloc(prefix.length + machine.length + device.length + 2);
        result.blit(0, prefix, 0, prefix.length);
        var offset = prefix.length;
        result.blit(offset, machine, 0, machine.length);
        result.blit(offset + machine.length, device, 0, device.length);
        // The local agent is always the Noise responder in protocol version 1.
        result.set(result.length - 2, 0x01);
        result.set(result.length - 1, 0x02);
        return result;
    }
}
