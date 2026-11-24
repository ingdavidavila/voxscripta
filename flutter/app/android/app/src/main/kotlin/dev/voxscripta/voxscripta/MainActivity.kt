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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pointEngineAtModel()
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

        MethodChannel(messenger, MICROPHONE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensure" -> ensureMicrophone(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Tells the engine where the speech model is, when there is one.
     *
     * The engine looks beside its executable and under a development build
     * tree, and neither exists inside an Android app, so without help every
     * transcription fails with "a required model asset is missing". It also
     * honours `VOXSCRIPTA_WHISPER_MODEL`, which is the one place to say so
     * without changing the engine; this sets it from the app's private
     * `models` directory, preferring small over base in the engine's own order.
     *
     * Deliberately does nothing when no model has been put there. How a model
     * reaches the phone (bundled with the install, or fetched once) is a
     * distribution decision this does not make: whichever it is only has to
     * leave a file in that directory. An absent model then fails with the
     * engine's own message naming the path, which is the honest outcome.
     */
    private fun pointEngineAtModel() {
        val models = java.io.File(filesDir, "models")
        val model = listOf("ggml-small.bin", "ggml-base.bin")
            .map { java.io.File(models, it) }
            .firstOrNull { it.isFile } ?: return
        // In-process, before the engine is opened: the engine reads the
        // environment when it resolves a model, not when the library loads.
        android.system.Os.setenv("VOXSCRIPTA_WHISPER_MODEL", model.absolutePath, true)
    }

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
        const val MICROPHONE_REQUEST = 7001
    }
}
