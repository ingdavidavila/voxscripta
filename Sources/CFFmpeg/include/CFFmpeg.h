// Swift's view of FFmpeg: demuxing, decoding and resampling, nothing else.
//
// Only the four libraries this project configured in. The build deliberately
// leaves out avdevice, avfilter and postproc, so they are not reachable from
// here either.
#ifndef VOXSCRIPTA_CFFMPEG_H
#define VOXSCRIPTA_CFFMPEG_H

// The four header directories are staged here by Tools/build-ffmpeg.sh and are
// gitignored, because they are build output: they used to be committed
// symlinks, which a Windows checkout cannot create without elevated
// privileges. Say so here rather than letting the compiler report a missing
// avformat.h, which does not tell anyone what to run.
#if !__has_include(<libavformat/avformat.h>)
#error "FFmpeg headers are not staged. Run: Tools/build-ffmpeg.sh host"
#endif

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#endif
