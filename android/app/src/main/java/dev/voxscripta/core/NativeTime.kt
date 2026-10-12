package dev.voxscripta.core

/**
 * The Kotlin side of libvoxscripta's time types.
 *
 * Method names and the package path are load-bearing: JNI binds by symbol name,
 * so `dev.voxscripta.core.NativeTime.samplesAt` must match
 * `Java_dev_voxscripta_core_NativeTime_samplesAt` in voxscripta_jni.cpp exactly.
 * Renaming either side without the other produces an UnsatisfiedLinkError at
 * the first call rather than a compile error, so they are checked together by
 * the symbol dump in Tools/verify-android-core.sh.
 *
 * Not yet compiled. This machine has no JDK, so the declarations here are
 * matched against the exported symbols rather than against a real Gradle build.
 * That check happens when the Android app project exists.
 */
object NativeTime {

    init {
        System.loadLibrary("voxscripta_jni")
    }

    /** Nanoseconds to floating-point seconds, for display only. */
    external fun secondsFromNanoseconds(nanoseconds: Long): Double

    /**
     * Seconds to exact nanoseconds.
     *
     * @throws IllegalArgumentException if the value is not finite.
     */
    external fun nanosecondsFromSeconds(seconds: Double): Long

    /**
     * The sample index at [sampleRate], truncated toward zero.
     *
     * @throws IllegalArgumentException if the rate is not positive.
     * @throws ArithmeticException past the representable duration — roughly 53
     *   hours at 48 kHz. The core detects this rather than wrapping, because
     *   signed overflow is undefined behaviour in C++.
     */
    external fun samplesAt(nanoseconds: Long, sampleRate: Int): Long

    /** Formats as `h:mm:ss.mmm`, or `m:ss.mmm` under an hour. */
    external fun format(nanoseconds: Long): String

    /**
     * The asymmetric speech padding from the silence detector, returned as
     * `[startNanoseconds, endNanoseconds]`.
     *
     * Packed into a LongArray rather than a Kotlin data class on purpose: this
     * is the spike proving a compound value survives the boundary. The real
     * bridge will hand back a typed object once the core's value types are
     * ported and a serialisation shape is settled.
     */
    external fun paddedRange(
        startNanoseconds: Long,
        endNanoseconds: Long,
        leadNanoseconds: Long,
        trailNanoseconds: Long,
        limitEndNanoseconds: Long,
    ): LongArray
}
