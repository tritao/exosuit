package com.exosuit.mobile

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Runs in its own process (`:restart`, see AndroidManifest.xml). It ends the app's main process, whose runtime belongs to an
 * Activity instance that Android already destroyed, and starts ExosuitActivity in a fresh task, so the runtime loads anew.
 * Not exported: only ExosuitActivity.restartProcess starts it.
 */
class RestartActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val pid = intent.getIntExtra(EXTRA_PID, -1)
        if (pid > 0 && pid != android.os.Process.myPid()) android.os.Process.killProcess(pid)
        startActivity(Intent(this, ExosuitActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        finish()
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    companion object {
        const val EXTRA_PID = "pid"
    }
}
