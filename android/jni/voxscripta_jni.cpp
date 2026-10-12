// The JNI face of libvoxscripta.
//
// Deliberately small. This is the spike's whole point: prove that the core
// cross-compiles for Android, that the symbols bind, and above all that a C++
// exception crossing the boundary becomes a Java exception rather than killing
// the process.
//
// That last part is not incidental. The core throws for the cases the Swift
// code handles by trapping — a non-finite duration, a sample index too large to
// express — and an exception that escapes a JNI frame calls std::terminate.
// A transcription job dying with no stack and no message, hours in, is the worst
// failure mode this app has. So every entry point here is wrapped.

#include <jni.h>

#include <new>
#include <stdexcept>
#include <string>

#include "voxscripta/media_time.hpp"
#include "voxscripta/time_range.hpp"

namespace {

void throw_java(JNIEnv* env, const char* class_name, const std::string& message) {
    // Any pending exception has to be cleared first or ThrowNew is ignored.
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
    if (jclass cls = env->FindClass(class_name)) {
        env->ThrowNew(cls, message.c_str());
        env->DeleteLocalRef(cls);
    }
}

/// Runs `body`, translating every C++ exception into the closest Java one.
///
/// The mapping is chosen so Kotlin callers can catch what they actually expect:
/// a bad argument is IllegalArgumentException, an arithmetic limit is
/// ArithmeticException, and anything unforeseen still arrives as a throwable
/// with a message instead of a SIGABRT.
template <typename T, typename Body>
T guarded(JNIEnv* env, T fallback, Body body) {
    try {
        return body();
    } catch (const std::overflow_error& error) {
        throw_java(env, "java/lang/ArithmeticException", error.what());
    } catch (const std::invalid_argument& error) {
        throw_java(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::bad_alloc& error) {
        throw_java(env, "java/lang/OutOfMemoryError", error.what());
    } catch (const std::exception& error) {
        throw_java(env, "java/lang/RuntimeException", error.what());
    } catch (...) {
        throw_java(env, "java/lang/RuntimeException", "unknown error in libvoxscripta");
    }
    return fallback;
}

}  // namespace

extern "C" {

JNIEXPORT jdouble JNICALL Java_dev_voxscripta_core_NativeTime_secondsFromNanoseconds(
    JNIEnv* env, jclass, jlong nanoseconds) {
    return guarded(env, 0.0, [&] {
        return static_cast<jdouble>(voxscripta::MediaTime(nanoseconds).seconds());
    });
}

JNIEXPORT jlong JNICALL Java_dev_voxscripta_core_NativeTime_nanosecondsFromSeconds(
    JNIEnv* env, jclass, jdouble seconds) {
    return guarded(env, jlong{0}, [&] {
        return static_cast<jlong>(voxscripta::MediaTime::from_seconds(seconds).nanoseconds());
    });
}

/// Throws ArithmeticException past the representable duration, which is the
/// case the spike exists to exercise.
JNIEXPORT jlong JNICALL Java_dev_voxscripta_core_NativeTime_samplesAt(JNIEnv* env, jclass,
                                                                      jlong nanoseconds,
                                                                      jint sample_rate) {
    return guarded(env, jlong{0}, [&] {
        return static_cast<jlong>(
            voxscripta::MediaTime(nanoseconds).samples_at(static_cast<int>(sample_rate)));
    });
}

JNIEXPORT jstring JNICALL Java_dev_voxscripta_core_NativeTime_format(JNIEnv* env, jclass,
                                                                     jlong nanoseconds) {
    return guarded(env, static_cast<jstring>(nullptr), [&] {
        const std::string text = voxscripta::MediaTime(nanoseconds).to_string();
        return env->NewStringUTF(text.c_str());
    });
}

/// Exercises TimeRange across the boundary: returns the padded span packed into
/// a two-element array, so the spike proves a compound type round-trips.
JNIEXPORT jlongArray JNICALL Java_dev_voxscripta_core_NativeTime_paddedRange(
    JNIEnv* env, jclass, jlong start, jlong end, jlong lead, jlong trail, jlong limit_end) {
    return guarded(env, static_cast<jlongArray>(nullptr), [&] {
        // Braces, not parentheses: `TimeRange range(MediaTime(start), ...)`
        // is parsed as a function declaration, which is the most vexing parse.
        const voxscripta::TimeRange range{voxscripta::MediaTime(start),
                                          voxscripta::MediaTime(end)};
        const voxscripta::TimeRange limit{voxscripta::MediaTime(0),
                                          voxscripta::MediaTime(limit_end)};
        const auto padded = range.padded(voxscripta::MediaTime(lead), voxscripta::MediaTime(trail),
                                         limit);

        jlongArray result = env->NewLongArray(2);
        if (result == nullptr) {
            return static_cast<jlongArray>(nullptr);
        }
        const jlong values[2] = {padded.start_time().nanoseconds(),
                                 padded.end_time().nanoseconds()};
        env->SetLongArrayRegion(result, 0, 2, values);
        return result;
    });
}

}  // extern "C"
