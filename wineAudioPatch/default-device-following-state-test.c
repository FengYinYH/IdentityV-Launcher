/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Kept aligned with the Wine CoreAudio policy helper tested here.
 */
#include "default-device-following-state.h"

#include <assert.h>

struct mock_stream
{
    uint32_t device;
    uint32_t format;
    uint64_t written_frames;
    uint64_t queued_frames;
    int playing;
    int available;
};

struct mock_resources
{
    int unit;
    int converter;
    int local_buffer;
    int cap_buffer;
    int volume_arrays;
    int initialized;
    int started;
    int stops;
    int disposals;
};

static void route_failed(struct mock_stream *stream)
{
    stream->available = 0;
    stream->queued_frames = 0;
}

static int route_recovered(struct mock_stream *stream, uint32_t requested,
                           uint32_t actual, int initialize_ok, int cap_buffer_ok,
                           int stopping)
{
    if(!idv_audio_route_candidate_matches(requested, actual, 1, initialize_ok,
                                          cap_buffer_ok, stopping))
        return 0;
    stream->device = requested;
    stream->available = 1;
    stream->queued_frames = 0;
    return 1;
}

static void mock_create_capture(struct mock_resources *resources,
                                int cap_allocation_ok, int initialize_ok)
{
    resources->unit = 1;
    resources->converter = 1;
    resources->local_buffer = 1;
    resources->volume_arrays = 1;
    if(!cap_allocation_ok) goto failed;
    resources->cap_buffer = 1;
    if(!initialize_ok) goto failed;
    resources->initialized = 1;
    resources->started = 1; /* Callback cannot run before every buffer exists. */
    return;

failed:
    if(resources->unit){
        if(resources->initialized) ++resources->stops;
        ++resources->disposals;
    }
    resources->unit = resources->converter = resources->local_buffer = 0;
    resources->cap_buffer = resources->volume_arrays = 0;
    resources->initialized = resources->started = 0;
}

int main(void)
{
    struct mock_stream stream = { 1, 48000, 12000, 384, 1, 1 };
    unsigned int retry_polls = 0;

    assert(!idv_audio_route_needs_rebuild(1, 1, 1, 0));
    assert(idv_audio_route_needs_rebuild(1, 2, 1, 0));
    assert(idv_audio_route_needs_rebuild(2, 2, 0, 0));
    assert(!idv_audio_route_needs_rebuild(1, 2, 1, 1));

    /* An initialization or capture-buffer allocation failure never publishes. */
    assert(!idv_audio_route_candidate_matches(2, 2, 1, 0, 1, 0));
    assert(!idv_audio_route_candidate_matches(2, 2, 1, 1, 0, 0));
    assert(!idv_audio_capture_buffer_size_valid(0, 4, UINT64_MAX));
    assert(!idv_audio_capture_buffer_size_valid(UINT64_MAX, 4, UINT64_MAX));
    assert(idv_audio_capture_buffer_size_valid(48000, 4, UINT64_MAX));

    /* A route that changes while the replacement unit starts must be retried
     * for the actual latest device; release prevents publishing any candidate. */
    assert(!route_recovered(&stream, 2, 3, 1, 1, 0));
    assert(!route_recovered(&stream, 3, 3, 1, 1, 1));

    route_failed(&stream);
    stream.written_frames += 256; /* Transition-time render data is discarded. */
    assert(stream.playing && stream.format == 48000 && !stream.available);
    assert(stream.queued_frames == 0 && stream.written_frames == 12256);
    assert(route_recovered(&stream, 3, 3, 1, 1, 0));
    assert(stream.device == 3 && stream.available && stream.playing);
    assert(stream.format == 48000 && stream.written_frames == 12256);
    assert(stream.queued_frames == 0); /* No old audio backlog after recovery. */

    assert(idv_audio_route_retry_due(&retry_polls));
    idv_audio_route_schedule_retry(&retry_polls);
    assert(!idv_audio_route_retry_due(&retry_polls));
    assert(!idv_audio_route_retry_due(&retry_polls));
    assert(!idv_audio_route_retry_due(&retry_polls));
    assert(!idv_audio_route_retry_due(&retry_polls));
    assert(idv_audio_route_retry_due(&retry_polls));

    /* First-install failures release every partially allocated resource;
     * capture buffers are ready before Initialize/Start can invoke callbacks. */
    {
        struct mock_resources resources = { 0 };
        mock_create_capture(&resources, 0, 1); /* cap buffer allocation fails */
        assert(!resources.unit && !resources.converter && !resources.local_buffer);
        assert(!resources.cap_buffer && !resources.volume_arrays && !resources.started);
        assert(resources.disposals == 1 && resources.stops == 0);
    }
    {
        struct mock_resources resources = { 0 };
        mock_create_capture(&resources, 1, 0); /* AudioUnitInitialize fails */
        assert(!resources.unit && !resources.converter && !resources.local_buffer);
        assert(!resources.cap_buffer && !resources.volume_arrays && !resources.started);
        assert(resources.disposals == 1 && resources.stops == 0);
    }
    {
        struct mock_resources resources = { 0 };
        mock_create_capture(&resources, 1, 1);
        assert(resources.unit && resources.converter && resources.local_buffer);
        assert(resources.cap_buffer && resources.volume_arrays && resources.started);
    }
    return 0;
}
