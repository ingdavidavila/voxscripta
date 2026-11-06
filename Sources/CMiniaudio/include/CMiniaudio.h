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
#include "miniaudio.h"
#endif
