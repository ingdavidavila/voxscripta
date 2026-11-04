// Swift's view of whisper.cpp.
//
// A shim rather than importing whisper.h directly, so the search paths and the
// C++ headers behind it stay the build system's problem instead of leaking
// into every Swift file that wants the engine.
#ifndef VOXSCRIPTA_CWHISPER_H
#define VOXSCRIPTA_CWHISPER_H
#include "whisper.h"   // symlinked from vendor/whisper.cpp — see Sources/CWhisper/include
#endif
