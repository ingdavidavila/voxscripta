// Swift's view of miniaudio, decoding only.
//
// One public-domain header that brings wav, flac and mp3 decoding together
// with a resampler and a channel mixer — which is the whole job, since the
// canonical format is 16 kHz mono float and sources are not.
//
// Device IO is switched off here. Recording is a separate backend and turning
// it on would link an audio device layer into a build that only decodes.
#ifndef VOXSCRIPTA_CMINIAUDIO_H
#define VOXSCRIPTA_CMINIAUDIO_H
#define MA_NO_DEVICE_IO
#define MA_NO_ENGINE
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#include "miniaudio.h"
#endif
