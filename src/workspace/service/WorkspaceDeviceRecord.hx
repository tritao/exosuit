package workspace.service;

import haxe.io.Bytes;

/** Pinned device identity and explicit capabilities for one workspace. */
typedef WorkspaceDeviceRecord = {
    var deviceId:String;
    var staticPublicKey:Bytes;
    var grants:Array<String>;
    var revoked:Bool;
}
