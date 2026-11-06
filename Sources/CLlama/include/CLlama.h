// Swift's view of llama.cpp.
//
// A shim for the same reason CWhisper has one: the search paths and the C++
// headers behind it stay the build system's problem rather than leaking into
// every Swift file that wants the model.
//
// The vendor headers beside this one are one-line forwarding headers that
// #include the real file under vendor/. They were symlinks until a Windows
// checkout proved the cost: git writes a mode-120000 entry as a text file
// holding the path unless the clone has permission to create links, so the
// compiler saw a 51-byte text file where a header should be. A forwarding
// header is the same indirection in a form every platform can check out.
#ifndef VOXSCRIPTA_CLLAMA_H
#define VOXSCRIPTA_CLLAMA_H
#include "CGGML.h"
#include "llama.h"
#endif
