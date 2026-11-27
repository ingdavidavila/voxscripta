package dev.voxscripta.voxscripta

import android.content.Context
import android.system.Os
import android.util.Log
import java.io.File

/**
 * Gets the speech model somewhere the engine can read it, and says so.
 *
 * The engine reads the model as an ordinary file, but a model that ships with the
 * install (as a Play Asset Delivery install-time pack) is only reachable through
 * Android's asset reader. So on first launch it is copied once into the app's
 * private `models` directory and the engine is pointed there. A model already in
 * that directory is used as it is, which is also how one is put there by hand
 * during development.
 *
 * Nothing here touches the network and nothing downloads: if the install carries
 * no model and none is in the directory, the state is [State.ABSENT] and the
 * engine reports its own "model is missing" message naming the path.
 *
 * The copy is written to a `.part` file and renamed when complete, so an
 * interrupted copy is never mistaken for a model, and a half-written file never
 * reaches the engine.
 *
 * The polish model arrives the same way, from its own pack, and is copied after
 * the speech model. It is not allowed to stop transcription: if it cannot be
 * copied, the engine reports that polish did not run and why.
 */
class ModelStore(private val context: Context) {
    enum class State { IDLE, COPYING, READY, ABSENT, FAILED }

    @Volatile var state: State = State.IDLE
        private set
    @Volatile var copiedBytes: Long = 0
        private set
    @Volatile var totalBytes: Long = -1
        private set
    /**
     * Why it failed, as a code the interface words in its own language, never a
     * sentence: no_space, not_in_place or copy_failed. Null unless [state] is FAILED.
     */
    @Volatile var error: String? = null
        private set
    /** For no_space: how many megabytes the device would need free. */
    @Volatile var neededMb: Long = 0
        private set
    /** For copy_failed: what the system said, which is not ours to translate. */
    @Volatile var errorDetail: String? = null
        private set

    private val lock = Any()
    private val listeners = mutableListOf<() -> Unit>()

    private val directory get() = File(context.filesDir, "models")

    /** Starts preparing, once. Safe to call again. */
    fun begin() {
        synchronized(lock) {
            if (state != State.IDLE) return
            state = State.COPYING
        }
        Thread({ prepare() }, "model-store").start()
    }

    /** Calls [done] on the thread that finishes the work, or at once if it has. */
    fun whenFinished(done: () -> Unit) {
        synchronized(lock) {
            if (state != State.IDLE && state != State.COPYING) {
                done()
                return
            }
            listeners += done
        }
    }

    private fun prepare() {
        try {
            directory.mkdirs()
            // A leftover from an interrupted copy is never a model.
            directory.listFiles { f -> f.name.endsWith(".part") }?.forEach { it.delete() }

            val existing = NAMES.map { File(directory, it) }.firstOrNull { it.isFile }
            if (existing != null) {
                copyPolishModel()
                finish(State.READY, existing)
                return
            }

            val packaged = NAMES.firstOrNull { name ->
                context.assets.list("models")?.contains(name) == true
            }
            if (packaged == null) {
                finish(State.ABSENT, null)
                return
            }

            totalBytes = try {
                context.assets.openFd("models/$packaged").use { it.length }
            } catch (_: Exception) {
                // A compressed asset has no fixed length to report.
                -1
            }
            if (totalBytes > 0 && directory.usableSpace < totalBytes + SPACE_MARGIN) {
                val needMb = (totalBytes + SPACE_MARGIN) / MEGABYTE
                neededMb = needMb
                finish(State.FAILED, null, "no_space")
                return
            }

            val part = File(directory, "$packaged.part")
            context.assets.open("models/$packaged").use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(BUFFER)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        copiedBytes += read
                    }
                    output.fd.sync()
                }
            }
            val target = File(directory, packaged)
            if (!part.renameTo(target)) {
                part.delete()
                finish(State.FAILED, null, "not_in_place")
                return
            }
            copyPolishModel()
            finish(State.READY, target)
        } catch (e: Exception) {
            directory.listFiles { f -> f.name.endsWith(".part") }
                ?.forEach { it.delete() }
            errorDetail = e.message
            finish(State.FAILED, null, "copy_failed")
        }
    }

    /**
     * Copies the polish model out of its pack, once. Quietly does nothing when
     * the install carries none or there is no room: the speech model is what
     * the app cannot work without.
     */
    private fun copyPolishModel() {
        val target = File(directory, POLISH)
        if (target.isFile) return
        val part = File(directory, "$POLISH.part")
        try {
            if (context.assets.list("models")?.contains(POLISH) != true) return
            val length = try {
                context.assets.openFd("models/$POLISH").use { it.length }
            } catch (_: Exception) {
                -1
            }
            if (length > 0 && directory.usableSpace < length + SPACE_MARGIN) {
                Log.w(TAG, "no room for the polish model")
                return
            }
            // The progress bar starts again for this second file.
            copiedBytes = 0
            totalBytes = length
            context.assets.open("models/$POLISH").use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(BUFFER)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        copiedBytes += read
                    }
                    output.fd.sync()
                }
            }
            if (!part.renameTo(target)) part.delete()
        } catch (e: Exception) {
            part.delete()
            Log.w(TAG, "the polish model could not be copied: ${e.message}")
        }
    }

    private fun finish(result: State, model: File?, message: String? = null) {
        // In-process, before any job starts: the engine reads the environment
        // when it resolves a model, not when the library loads.
        if (model != null) Os.setenv("VOXSCRIPTA_WHISPER_MODEL", model.absolutePath, true)
        val toCall: List<() -> Unit>
        synchronized(lock) {
            error = message
            state = result
            toCall = listeners.toList()
            listeners.clear()
        }
        toCall.forEach { it() }
    }

    companion object {
        /** Small first, then base, matching the engine's own order. */
        val NAMES = listOf("ggml-small.bin", "ggml-base.bin")
        /** The only name the engine looks for. */
        const val POLISH = "polish.gguf"
        private const val TAG = "ModelStore"
        private const val BUFFER = 1 shl 20
        private const val MEGABYTE = 1L shl 20
        private const val SPACE_MARGIN = 64L shl 20
    }
}
