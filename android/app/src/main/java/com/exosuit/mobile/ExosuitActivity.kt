package com.exosuit.mobile

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.util.Log
import android.view.Choreographer
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import android.widget.FrameLayout
import android.widget.TextView
import io.nativekit.NativeKitHost
import org.json.JSONObject
import java.io.File

/**
 * The whole Android host: a full-screen view that NativeKit draws into, a Choreographer frame loop, and lifecycle.
 * Everything else, including the UI, is Haxe (ExosuitApp) running in the HashLink runtime.
 */
class ExosuitActivity : Activity(), Choreographer.FrameCallback {
    private var host: NativeKitHost? = null
    private var surface = 0L
    private var loaded = false
    private var started = false
    private var active = false
    // NativeKit observes insets on `content`; the Activity observes them on `root`, so neither replaces the other.
    private lateinit var root: FrameLayout
    private lateinit var content: FrameLayout
    private lateinit var vault: CredentialVault
    private val debuggable by lazy { applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 }
    /** Debug-only commands from the launching intent (pairing_url, pairing_confirm, open_workspace), held until the module has started. */
    private val pendingCommands = ArrayDeque<JSONObject>()

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if (runtimeBound) {
            // An earlier instance of this Activity in this process already bound the runtime to its own views and surface
            // (Android recreated the Activity without ending the process). That binding cannot move, so start a fresh process.
            restartProcess()
            return
        }
        root = FrameLayout(this)
        content = FrameLayout(this)
        root.addView(content, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        try {
            vault = CredentialVault(this)
            // Secure WebSockets need the system CA roots; NativeKit reads this before its first connection.
            TlsTrust.install(this)
            // Debug builds: a test run that put `files/automation.on` there gets the app's labelled elements and state in
            // `files/automation/snapshot.json` (AutomationProbe), so it taps what the UI shows instead of fixed pixels.
            if (debuggable && File(filesDir, "automation.on").exists())
                android.system.Os.setenv("EXOSUIT_AUTOMATION_DIR", File(filesDir, "automation").path, true)
            check(HaxeonRuntime.load(assets, if (debuggable) File(filesDir, "dev").path else null) == 0) { "Haxeon module load failed" }
            loaded = true
            queueIntentCommands(intent)
            runtimeBound = true
            host = NativeKitHost(content)
            observeInsets()
            // Back (gesture, button or key) goes to ExosuitApp first; the Activity finishes only at the top level.
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, backCallback)
            content.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
                if (right > left && bottom > top) onLayout(right - left, bottom - top)
            }
        } catch (error: Throwable) {
            fail(error)
        }
    }

    private val backCallback = OnBackInvokedCallback {
        val consumed = try {
            started && HaxeonRuntime.command(JSONObject().put("type", "back").toString().toByteArray(Charsets.UTF_8)) == 1
        } catch (error: Throwable) { false }
        // Back at the root sends the app to the background like Home: the connections stay up, and the process (with its
        // GPU context) is never torn down and started again in place, which wedged NativeKit (see onDestroy).
        if (!consumed) moveTaskToBack(true)
    }

    /** System bars, display cutout and keyboard in dp; the UI keeps its content inside them. */
    private fun observeInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val density = resources.displayMetrics.density
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val bottom = maxOf(bars.bottom, ime)
            pendingInsets = JSONObject().put("type", "insets")
                .put("left", bars.left / density.toDouble()).put("top", bars.top / density.toDouble())
                .put("right", bars.right / density.toDouble()).put("bottom", bottom / density.toDouble())
                .put("keyboard", ime / density.toDouble())
            sendInsets()
            insets
        }
        ViewCompat.requestApplyInsets(root)
    }

    private var pendingInsets: JSONObject? = null

    private fun sendInsets() {
        val value = pendingInsets ?: return
        if (!started) return
        try { command(value) } catch (error: Throwable) { fail(error) }
    }

    private var laidOutWidth = 0
    private var laidOutHeight = 0

    private fun onLayout(pixelWidth: Int, pixelHeight: Int) {
        // Resizing the surface lays the view out again; act only on a real change.
        if (pixelWidth == laidOutWidth && pixelHeight == laidOutHeight) return
        laidOutWidth = pixelWidth; laidOutHeight = pixelHeight
        try {
            val scale = resources.displayMetrics.density
            val width = (pixelWidth / scale).toInt().coerceAtLeast(1)
            val height = (pixelHeight / scale).toInt().coerceAtLeast(1)
            val geometry = JSONObject().put("width", width).put("height", height)
                .put("fbWidth", pixelWidth).put("fbHeight", pixelHeight).put("scale", scale.toDouble())
            if (surface == 0L) {
                surface = HaxeonRuntime.createSurface(requireNotNull(host).handle(), width, height)
                check(surface != 0L) { "NativeKit GLES3 surface creation failed" }
                startModule(
                    geometry.put("type", "start").put("surface", surface.toInt())
                        .put("appFilesRoot", filesDir.absolutePath)
                        .put("regular", unpackFont("IBMPlexSans-Regular.ttf"))
                        .put("mono", unpackFont("IBMPlexMono-Regular.ttf"))
                )
                started = true
                sendInsets()
                while (pendingCommands.isNotEmpty()) command(pendingCommands.removeFirst())
            } else {
                check(HaxeonRuntime.resizeSurface(surface, width, height) == 0) { "Surface resize failed" }
                command(geometry.put("type", "resize"))
            }
        } catch (error: Throwable) {
            fail(error)
        }
    }

    /** UIKit loads fonts from files, so the APK's font assets are copied to the app's private directory. */
    private fun unpackFont(name: String): String {
        val target = File(filesDir, name)
        assets.open("fonts/$name").use { input -> target.outputStream().use { input.copyTo(it) } }
        return target.absolutePath
    }

    /**
     * The start command carries the stored credentials as base64 text spliced in as bytes, so the secrets are never a
     * String; the arrays are wiped as soon as the call returns.
     */
    private fun startModule(value: JSONObject) {
        val document = vault.read()
        var encoded: ByteArray? = null
        var message: ByteArray? = null
        try {
            val head = value.toString().toByteArray(Charsets.UTF_8)
            if (document == null) {
                message = head
            } else {
                encoded = android.util.Base64.encode(document, android.util.Base64.NO_WRAP)
                val prefix = ",\"credentials\":\"".toByteArray(Charsets.US_ASCII)
                // head ends with '}': keep everything before it, then add the field and close the object.
                val out = ByteArray(head.size - 1 + prefix.size + encoded.size + 2)
                System.arraycopy(head, 0, out, 0, head.size - 1)
                System.arraycopy(prefix, 0, out, head.size - 1, prefix.size)
                System.arraycopy(encoded, 0, out, head.size - 1 + prefix.size, encoded.size)
                out[out.size - 2] = '"'.code.toByte()
                out[out.size - 1] = '}'.code.toByte()
                message = out
            }
            val result = HaxeonRuntime.command(message)
            check(result == 1) { "Haxeon rejected the start command (code $result)" }
        } finally {
            CredentialVault.wipe(document)
            CredentialVault.wipe(encoded)
            CredentialVault.wipe(message)
        }
    }

    /** Answers what the Haxe module asked of the host since the last frame (today only: store the credentials). */
    private fun serveRequests() {
        while (true) {
            val frame = HaxeonRuntime.takeRequest() ?: return
            try {
                check(frame.size >= 5) { "Short host request" }
                val kind = frame[0].toInt()
                val id = ((frame[1].toInt() and 0xff) shl 24) or ((frame[2].toInt() and 0xff) shl 16) or
                    ((frame[3].toInt() and 0xff) shl 8) or (frame[4].toInt() and 0xff)
                val payload = frame.copyOfRange(5, frame.size)
                val stored = try {
                    kind == REQUEST_SAVE_CREDENTIALS && vault.write(payload)
                } finally {
                    CredentialVault.wipe(payload)
                }
                command(JSONObject().put("type", "hostResult").put("id", id).put("ok", if (stored) 1 else 0))
            } finally {
                CredentialVault.wipe(frame)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyLivePatch(intent)
        queueIntentCommands(intent)
        if (started) while (pendingCommands.isNotEmpty()) runCatching { command(pendingCommands.removeFirst()) }.onFailure { fail(it) }
    }

    /**
     * Debug builds only: `--ez live_patch true` applies files/dev/patch.hlp (pushed by android/scripts/dev.ps1 -Live) to the
     * running module without restarting. The outcome is logged as `exosuit-live: patched ...` or `exosuit-live: refused ...`;
     * a refusal leaves the app running its old code and the script falls back to a reload.
     */
    private fun applyLivePatch(source: Intent?) {
        if (!debuggable || source == null || !source.getBooleanExtra("live_patch", false) || !started) return
        val file = File(File(filesDir, "dev"), "patch.hlp")
        val began = System.nanoTime()
        val status = runCatching { HaxeonRuntime.patch(file.readBytes()) }.getOrDefault(-2)
        val millis = (System.nanoTime() - began) / 1_000_000
        android.util.Log.i("ExosuitLive", if (status == 0) "exosuit-live: patched in $millis ms" else "exosuit-live: refused (status $status)")
    }

    /** Debug builds only: `--es pairing_url <url>` starts pairing, `--ez pairing_confirm true` confirms the shown code,
     * `--es open_workspace <name>` opens the granted workspace with that name once the machine lists it,
     * `--es clipboard_text <text>` sets the clipboard. */
    private fun queueIntentCommands(source: Intent?) {
        if (!debuggable || source == null) return
        source.getStringExtra("pairing_url")?.let { pendingCommands.addLast(JSONObject().put("type", "pair").put("url", it)) }
        if (source.getBooleanExtra("pairing_confirm", false)) pendingCommands.addLast(JSONObject().put("type", "confirm"))
        // `--es clipboard_text <text>` puts text on the Android clipboard (there is no adb shell command for it), for paste checks.
        source.getStringExtra("clipboard_text")?.let {
            (getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(android.content.ClipData.newPlainText("test", it))
        }
        source.getStringExtra("open_workspace")?.let { pendingCommands.addLast(JSONObject().put("type", "open").put("name", it)) }
    }

    private fun command(value: JSONObject) {
        val result = HaxeonRuntime.command(value.toString().toByteArray(Charsets.UTF_8))
        check(result == 1) { "Haxeon rejected the ${value.optString("type")} command (code $result)" }
    }

    override fun onResume() {
        super.onResume()
        host?.active()
        active = loaded
        if (active) Choreographer.getInstance().postFrameCallback(this)
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!active) return
        try {
            if (started) {
                command(JSONObject().put("type", "frame").put("timeMs", frameTimeNanos / 1_000_000.0))
                serveRequests()
            }
        } catch (error: Throwable) {
            fail(error)
            return
        }
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onPause() {
        active = false
        Choreographer.getInstance().removeFrameCallback(this)
        host?.inactive()
        super.onPause()
    }

    override fun onStop() {
        host?.background()
        super.onStop()
    }

    override fun onDestroy() {
        active = false
        Choreographer.getInstance().removeFrameCallback(this)
        if (!isChangingConfigurations) {
            // Tearing the runtime down in a process that lives on does not work: NativeKit's host close spins when a
            // surface still has a frame in flight or sampled images (found with Back at the root, before moveTaskToBack), and
            // the next launch then sat on the splash icon for ever. Everything durable is already on disk or in the
            // Keystore, so the process ends and the next start is a clean one. This covers a destroy without finishing too
            // ("Don't keep activities"); a recreation for a configuration change restarts the process in the next onCreate.
            android.os.Process.killProcess(android.os.Process.myPid())
        }
        super.onDestroy()
    }

    /**
     * Starts this Activity again in a new process: RestartActivity, in its own process, waits for this one to be gone and
     * then launches a fresh task. This process ends now, so nothing of the old runtime is reused.
     */
    private fun restartProcess() {
        Log.i(TAG, "Activity recreated in a process whose runtime belongs to an earlier instance; restarting the process")
        startActivity(Intent(this, RestartActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(RestartActivity.EXTRA_PID, android.os.Process.myPid()))
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    private fun fail(error: Throwable) {
        active = false
        Choreographer.getInstance().removeFrameCallback(this)
        Log.e(TAG, "Exosuit host failed", error)
        setContentView(TextView(this).apply {
            text = "Exosuit could not start: ${error.message}"
            setPadding(24, 48, 24, 24)
        })
    }

    private companion object {
        const val TAG = "Exosuit"
        const val REQUEST_SAVE_CREDENTIALS = 1
        /** The process's runtime is bound to an Activity instance's views (one per process; see restartProcess). */
        @Volatile var runtimeBound = false
    }
}
