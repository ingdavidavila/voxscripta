package dev.voxscripta.voxscripta

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The one thing the Dart side cannot learn for itself: where this app may write.
 *
 * Android gives an app no home directory, and the engine refuses to guess one, so
 * the app's own private directories are reported here and handed to the engine as
 * its data directory (see lib/src/app_directories.dart).
 *
 * Paths and nothing else, on purpose. Permissions, the document picker and the
 * foreground service belong in their own channels, so that this one stays small
 * enough to read in one sitting. No third-party plugin is involved: what this app
 * does with the network, the microphone and the user's files has to be provable
 * from our own code, and a plugin is code we would have to re-audit on every
 * version bump.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PATHS_CHANNEL)
            .setMethodCallHandler { call, result ->
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
    }

    private companion object {
        // Matches AppDirectories.channelName on the Dart side, and the
        // application id, so it cannot collide with a plugin's channel.
        const val PATHS_CHANNEL = "dev.voxscripta.voxscripta/paths"
    }
}
