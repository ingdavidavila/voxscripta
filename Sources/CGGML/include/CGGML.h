// ggml, which both engines share.
//
// whisper.cpp and llama.cpp each vendor their own copy of ggml, and linking
// both would mean two definitions of the same symbols. Tools/build-engines.sh
// therefore installs llama.cpp's ggml first and builds whisper.cpp against it
// with WHISPER_USE_SYSTEM_GGML — one ggml in the binary, one set of backends.
//
// This target is that arrangement expressed to the compiler. The declarations
// have to live in exactly one module: when CLlama and CWhisper each carried
// their own copy of the ggml headers, Clang attributed the declarations to
// whichever module it parsed first and the other one could not see them, which
// is a compile error in llama.h on the field that uses ggml_opt_* types.
#ifndef VOXSCRIPTA_CGGML_H
#define VOXSCRIPTA_CGGML_H
#include "ggml.h"
#include "ggml-cpu.h"
#include "ggml-backend.h"
#include "ggml-opt.h"
#include "gguf.h"
#endif
