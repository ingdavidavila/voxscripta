package dev.voxscripta.voxscripta

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * What the Dart side cannot learn for itself, one small channel per concern.
 *
 * Android gives an app no home directory, and the engine refuses to guess one, so
 * the app's own private directories are reported on the paths channel and handed
 * to the engine as its data directory (see lib/src/app_directories.dart). The
 * microphone permission has its own channel (lib/src/microphone_permission.dart).
 *
 * Channels stay separate so each is small enough to read in one sitting. No
 * third-party plugin is involved: what this app does with the network, the
 * microphone and the user's files has to be provable from our own code, and a
 * plugin is code we would have to re-audit on every version bump.
 */
class MainActivity : FlutterActivity() {
    /** The reply owed to a permission prompt that is on screen, if any. */
    private var pendingMicrophone: MethodChannel.Result? = null

    private val models by lazy { ModelStore(applicationContext) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        models.begin()
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, PATHS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPaths" -> result.success(
                    mapOf(
                        "files" to filesDir.absolutePath,
                        "cache" to cacheDir.absolutePath,
                    )
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, MODEL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> models.whenFinished { runOnUiThread { result.success(modelStatus()) } }
                "status" -> result.success(modelStatus())
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, MICROPHONE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensure" -> ensureMicrophone(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * What the Dart side shows while the speech model is made ready: `state` is
     * idle, copying, ready, absent or failed (see [ModelStore]); `total` is -1
     * when the size is unknown.
     */
    private fun modelStatus(): Map<String, Any?> = mapOf(
        "state" to models.state.name.lowercase(),
        "copied" to models.copiedBytes,
        "total" to models.totalBytes,
        "error" to models.error,
    )

    /**
     * Replies "granted", "denied" (the prompt can be shown again) or "blocked"
     * (Android will no longer show it, so only Settings can change the answer).
     */
    private fun ensureMicrophone(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        if (pendingMicrophone != null) {
            // One prompt at a time. A second caller would otherwise strand the
            // first, whose screen would wait for ever.
            result.error("busy", "the microphone prompt is already showing", null)
            return
        }
        pendingMicrophone = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MICROPHONE_REQUEST) return
        val reply = pendingMicrophone ?: return
        pendingMicrophone = null

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        reply.success(
            when {
                granted -> "granted"
                // After a refusal the system only says "do not show the
                // rationale" once the person has chosen not to be asked again.
                !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) ->
                    "blocked"
                else -> "denied"
            }
        )
    }

    private companion object {
        // Match the Dart side, and the application id, so they cannot collide
        // with a plugin's channel.
        const val PATHS_CHANNEL = "dev.voxscripta.voxscripta/paths"
        const val MICROPHONE_CHANNEL = "dev.voxscripta.voxscripta/microphone"
        const val MODEL_CHANNEL = "dev.voxscripta.voxscripta/model"
        const val MICROPHONE_REQUEST = 7001
    }
}
