// Swift's view of FFmpeg: demuxing, decoding and resampling, nothing else.
//
// Only the four libraries this project configured in. The build deliberately
// leaves out avdevice, avfilter and postproc, so they are not reachable from
// here either.
#ifndef VOXSCRIPTA_CFFMPEG_H
#define VOXSCRIPTA_CFFMPEG_H
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#endif
