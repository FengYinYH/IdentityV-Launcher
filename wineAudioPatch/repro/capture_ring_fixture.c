/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Exact source functions are supplied by testCaptureRingOffsets.py. No audio
 * device is opened: conversion timing/output and Windows calls are fixtures.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t BYTE;
typedef uint32_t UINT32, UINT;
typedef int BOOL, NTSTATUS;
typedef size_t SIZE_T;
typedef int64_t INT64;
typedef struct { int64_t QuadPart; } LARGE_INTEGER;
#define TRUE 1
#define FALSE 0
#define min(a,b) ((a)<(b)?(a):(b))
#define WARN(...) ((void)0)
#define STATUS_SUCCESS 0
#define S_OK 0
#define AUDCLNT_E_OUT_OF_ORDER -1
#define AUDCLNT_E_INVALID_SIZE -2
#define AUDCLNT_S_BUFFER_EMPTY 1
#define MEM_COMMIT 0
#define PAGE_READWRITE 0
static uintptr_t zero_bits;
struct format { UINT32 nSamplesPerSec, nChannels, nBlockAlign; };
struct coreaudio_stream {
    struct format *fmt;
    AudioStreamBasicDescription dev_desc;
    AudioConverterRef converter;
    BOOL audio_available, playing;
    AudioComponentInstance unit;
    int lock, getbuf_last;
    UINT32 period_frames, bufsize_frames, resamp_bufsize_frames;
    UINT32 cap_bufsize_frames, cap_offs_frames, cap_held_frames;
    UINT32 wrap_bufsize_frames, lcl_offs_frames, wri_offs_frames, held_frames;
    uint64_t written_frames;
    BYTE *cap_buffer, *wrap_buffer, *resamp_buffer, *local_buffer, *tmp_buffer;
};
struct get_capture_buffer_params {
    void *stream;
    BYTE **data;
    UINT32 *frames, *flags;
    uint64_t *devpos, *qpcpos;
    int result;
};
struct release_capture_buffer_params { void *stream; UINT32 done; int result; };
static struct coreaudio_stream *handle_get_stream(void *stream) { return stream; }
static void os_unfair_lock_lock(int *lock) { assert(*lock == 0); *lock = 1; }
static void os_unfair_lock_unlock(int *lock) { assert(*lock == 1); *lock = 0; }
static void *GetCurrentProcess(void) { return NULL; }
static int NtAllocateVirtualMemory(void *p, void **out, uintptr_t bits, SIZE_T *size, int type, int mode)
{ (void)p; (void)bits; (void)type; (void)mode; *out = calloc(1, *size); return !*out; }
static void NtQueryPerformanceCounter(LARGE_INTEGER *stamp, LARGE_INTEGER *freq)
{ stamp->QuadPart = 1234; if(freq) freq->QuadPart = 10000000; }
static UINT32 muldiv(UINT32 a, double b, UINT32 c) { return (uint64_t)(a * b) / c; }

static unsigned int converter_output;
static OSStatus mock_converter(AudioConverterRef c, AudioConverterComplexInputDataProc feed,
                                void *user, UInt32 *packets, AudioBufferList *output,
                                AudioStreamPacketDescription *desc)
{
    struct coreaudio_stream *s = user;
    (void)c; (void)feed; (void)desc;
    assert(s->lock == 1);
    *packets = converter_output;
    output->mBuffers[0].mDataByteSize = *packets * s->fmt->nBlockAlign;
    for(unsigned i = 0; i < *packets; ++i) ((int16_t *)output->mBuffers[0].mData)[i] = 5000 + i;
    /* One conversion only; the fixture starts just above the two-period gate. */
    s->cap_held_frames = 0;
    return noErr;
}
static OSStatus mock_render(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                            const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                            AudioBufferList *data)
{
    (void)unit; (void)flags; (void)time; (void)bus; (void)frames;
    memset(data->mBuffers[0].mData, 0x41, data->mBuffers[0].mDataByteSize);
    return noErr;
}
#define AudioConverterFillComplexBuffer mock_converter
#define AudioUnitRender mock_render
#include "capture_functions.inc"

int main(int argc, char **argv)
{
    assert(argc == 2);
    if(!strcmp(argv[1], "large-callback")) {
        struct format fmt = {8000, 1, 2};
        struct coreaudio_stream s = {0};
        s.fmt=&fmt; s.audio_available=TRUE; s.playing=TRUE;
        s.cap_bufsize_frames=1440; s.cap_buffer=calloc(1440, 2);
        /* 30 ms at 48 kHz is a valid default shared-mode ring duration.
         * The 4096-frame callback is synthetic, not a measured device slice.
         * There is no MaximumFramesPerSlice/ring relation enforced by this
         * source. Keep this separate ASan failure explicit; not fixed here. */
        ca_capture_cb(&s, NULL, NULL, 1, 4096, NULL);
        /* Make every byte written by the exact callback observable. Otherwise
         * LLVM may delete the whole malloc/write/free path before ASan runs. */
        __asm__ __volatile__("" : : "r"(s.cap_buffer) : "memory");
        free(s.cap_buffer); free(s.wrap_buffer);
        return 0;
    }
    int expect_broken = strcmp(argv[1], "candidate") != 0;
    unsigned cases = 0, violations = 0, wrapped_reads = 0;
    const unsigned rates[] = {8000, 48000};
    for(unsigned rate_idx = 0; rate_idx < 2; ++rate_idx) {
        unsigned rate = rates[rate_idx], period = rate / 200;
        const unsigned capacities[] = {period*2, period*4, period*20, period*20+1};
        for(unsigned n = 0; n < 4; ++n) {
            unsigned capacity = capacities[n];
            for(unsigned pos = 0; pos <= 100; ++pos) {
                unsigned read = pos == 100 ? capacity-1 : pos*capacity/100;
                const unsigned occupancies[] = {capacity-period-1, capacity-period, capacity-period+1, capacity};
                for(unsigned h = 0; h < 4; ++h) {
                    unsigned held = occupancies[h];
                    struct format fmt = {rate, 1, 2};
                    struct coreaudio_stream s = {0};
                    s.fmt = &fmt;
                    s.dev_desc.mSampleRate = 48000;
                    s.converter = (AudioConverterRef)(uintptr_t)1;
                    s.audio_available = TRUE;
                    s.period_frames = period;
                    s.bufsize_frames = capacity;
                    s.local_buffer = calloc(capacity, fmt.nBlockAlign);
                    s.lcl_offs_frames = read;
                    s.held_frames = held;
                    s.wri_offs_frames = (read + held) % capacity;
                    s.cap_held_frames = muldiv(period, 48000, rate)*2+1;
                    converter_output = period;
                    for(unsigned i = 0; i < held; ++i)
                        ((int16_t *)s.local_buffer)[(read + i) % capacity] = 1000+i;
                    os_unfair_lock_lock(&s.lock);
                    capture_resample(&s);
                    os_unfair_lock_unlock(&s.lock);
                    ++cases;
                    unsigned total = held + period;
                    assert(s.held_frames == min(total, capacity));
                    BYTE *data = NULL;
                    UINT32 frames = 0, flags = 0;
                    struct get_capture_buffer_params get = { .stream=&s, .data=&data, .frames=&frames, .flags=&flags };
                    unix_get_capture_buffer(&get);
                    assert(get.result == S_OK && frames == period && s.lock == 0);
                    if(s.lcl_offs_frames > capacity) {
                        ++violations;
                        assert((uintptr_t)data >= (uintptr_t)s.local_buffer + capacity*2);
                        if(!strcmp(argv[1], "unsafe-read")) {
                            volatile int16_t value = ((int16_t *)data)[0];
                            (void)value; /* ASan evidence of the real returned pointer. */
                        }
                    } else {
                        if(total > capacity) assert(s.lcl_offs_frames % capacity == s.wri_offs_frames);
                        /* Exactly N is noncanonical but GetBuffer's zero-length
                         * first chunk wraps safely; >N underflows chunk_frames. */
                        if(data == s.tmp_buffer) ++wrapped_reads;
                        unsigned dropped = total > capacity ? total-capacity : 0;
                        for(unsigned i = 0; i < period; ++i) {
                            unsigned index = dropped+i;
                            int16_t expected = index < held ? 1000+index : 5000+index-held;
                            assert(((int16_t *)data)[i] == expected);
                        }
                        struct release_capture_buffer_params release = {.stream=&s, .done=frames};
                        unix_release_capture_buffer(&release);
                        assert(release.result == S_OK && s.lcl_offs_frames < capacity && s.lock == 0);
                    }
                    free(s.local_buffer); free(s.resamp_buffer); free(s.tmp_buffer);
                    free(s.wrap_buffer); free(s.cap_buffer);
                }
            }
        }
    }
    /* A callback fills only the hardware ring while a client owns a packet.
     * GetBuffer must reject a second lease; bad/zero Release cannot consume it. */
    {
        struct format fmt={8000,1,2}; struct coreaudio_stream s={0};
        s.fmt=&fmt;s.dev_desc.mSampleRate=48000;s.converter=(AudioConverterRef)(uintptr_t)1;
        s.audio_available=s.playing=TRUE;s.period_frames=40;s.bufsize_frames=800;
        s.cap_bufsize_frames=960;s.cap_buffer=calloc(960,2);s.local_buffer=calloc(800,2);
        s.lcl_offs_frames=40;s.held_frames=80;s.wri_offs_frames=120;
        for(unsigned i=0;i<800;i++)((int16_t*)s.local_buffer)[i]=i;
        BYTE*data=NULL;UINT32 frames=0,flags=0;
        struct get_capture_buffer_params get={.stream=&s,.data=&data,.frames=&frames,.flags=&flags};
        unix_get_capture_buffer(&get);assert(get.result==S_OK&&frames==40);
        int16_t snapshot[40];memcpy(snapshot,data,sizeof(snapshot));
        ca_capture_cb(&s,NULL,NULL,1,240,NULL);
        assert(!memcmp(snapshot,data,sizeof(snapshot))&&s.cap_held_frames==240&&s.lock==0);
        unix_get_capture_buffer(&get);assert(get.result==AUDCLNT_E_OUT_OF_ORDER&&s.lock==0);
        struct release_capture_buffer_params release={.stream=&s,.done=39};
        unix_release_capture_buffer(&release);assert(release.result==AUDCLNT_E_INVALID_SIZE&&s.held_frames==80&&s.lcl_offs_frames==40);
        release.done=0;unix_release_capture_buffer(&release);assert(release.result==S_OK&&s.held_frames==80&&s.lcl_offs_frames==40);
        unix_get_capture_buffer(&get);assert(get.result==S_OK&&!memcmp(snapshot,data,sizeof(snapshot)));
        release.done=40;unix_release_capture_buffer(&release);assert(release.result==S_OK&&s.held_frames==40&&s.lcl_offs_frames==80&&s.written_frames==40);
        unix_get_capture_buffer(&get);assert(get.result==S_OK);unix_release_capture_buffer(&release);
        unix_get_capture_buffer(&get);assert(get.result==AUDCLNT_S_BUFFER_EMPTY&&frames==0&&s.lock==0);
        free(s.cap_buffer);free(s.local_buffer);free(s.tmp_buffer);free(s.wrap_buffer);free(s.resamp_buffer);
    }
    assert(expect_broken ? violations > 0 : violations == 0);
    assert(wrapped_reads > 0);
    printf("%s: cases=%u invalid_GetBuffer_pointers=%u wrapped_packet_reads=%u; sample order/lock/Get/Release verified (8k/48k mono)\n",
           argv[1], cases, violations, wrapped_reads);
    return 0;
}
