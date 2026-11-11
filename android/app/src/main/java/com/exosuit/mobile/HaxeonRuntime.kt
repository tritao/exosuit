package com.exosuit.mobile

import android.content.res.AssetManager

/** JNI to native/exosuit_jni.c. The Haxe module (ui.hl) owns application behavior and rendering. */
object HaxeonRuntime {
    init {
        System.loadLibrary("nativekit")
        System.loadLibrary("nativekit_gpu")
        System.loadLibrary("nativekit_ui")
        System.loadLibrary("haxeon")
    }

    /**
     * Loads ui.hl, ui.hli and ui.entries into the HashLink runtime; 0 on success. A file in [overrideDirectory]
     * (debug builds only, null otherwise) replaces the APK asset of the same name. Once a module is loaded, later calls in
     * the same process return 0 without loading or initialising it again.
     */
    external fun load(assets: AssetManager, overrideDirectory: String?): Int

    /** Sends one JSON command to UiBridge.commandJSON; 1 when it was accepted. */
    external fun command(json: ByteArray): Int
    /**
     * The next request the Haxe module has for the host (one frame: kind, 4-byte id, payload), or null. The caller wipes it.
     * Call it on the UI thread after each frame command.
     */
    external fun takeRequest(): ByteArray?

    /** Debug builds: applies a live patch (HLP bytes) to the running module; 0 when applied. See exosuit_jni.c. */
    external fun patch(hlp: ByteArray): Int

    external fun dispose(): Int

    /** Creates a GLES 3 NativeKit surface on NativeKitHost.handle(); 0 on failure. */
    external fun createSurface(host: Long, width: Int, height: Int): Long
    external fun resizeSurface(surface: Long, width: Int, height: Int): Int
}
