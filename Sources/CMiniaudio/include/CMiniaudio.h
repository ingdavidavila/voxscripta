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
