// Swift's view of miniaudio: the microphone, and nothing else.
//
// Decoding moved to FFmpeg, which reads the containers AVFoundation reads and
// which miniaudio could not. What miniaudio is here for now is the one job
// FFmpeg does not do at all: opening a capture device on Windows, Linux,
// Android and macOS behind one API.
//
// So the decoders are off and device IO is on — the opposite of how this
// started, and worth saying out loud because the defines look like
// boilerplate until you know which half is wanted.
//
// The vendor headers beside this one are one-line forwarding headers that
// #include the real file under vendor/. They were symlinks until a Windows
// checkout proved the cost: git writes a mode-120000 entry as a text file
// holding the path unless the clone has permission to create links, so the
// compiler saw a 51-byte text file where a header should be. A forwarding
// header is the same indirection in a form every platform can check out.
#ifndef VOXSCRIPTA_CMINIAUDIO_H
#define VOXSCRIPTA_CMINIAUDIO_H
#define MA_NO_ENGINE
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_DECODING
#define MA_NO_ENCODING

// Offered to C and Objective-C, withheld from C++.
//
// `VoxScriptaCoreParityTests` compiles with `.interoperabilityMode(.Cxx)` and
// depends on VoxScriptaDSP, so Swift builds this module in C++ mode for that
// target. On Xcode 26.6's SDK that fails: miniaudio.h imports pthread inside an
// `extern "C"` block, which is illegal in a C++ module —
//
//   miniaudio.h:3907: import of C++ module '_DarwinFoundation3.pthread'
//   appears within extern "C" language linkage specification
//
// It does not fail on 27.2, which is why CI caught it and no developer machine
// did. Nothing in C++ uses miniaudio — the recorder is Swift and keeps every
// `ma_` type private — so the honest fix is to not offer the vendor header to a
// C++ parse at all, rather than to patch a vendored file or to drop the
// parity tests' interop, which is the whole point of them.
#ifndef __cplusplus
#include "miniaudio.h"
#endif

#endif
