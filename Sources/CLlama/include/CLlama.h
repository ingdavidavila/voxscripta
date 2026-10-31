// Swift's view of llama.cpp.
//
// A shim for the same reason CWhisper has one: the search paths and the C++
// headers behind it stay the build system's problem rather than leaking into
// every Swift file that wants the model.
#ifndef VOXSCRIPTA_CLLAMA_H
#define VOXSCRIPTA_CLLAMA_H
#include "llama.h"
#endif
