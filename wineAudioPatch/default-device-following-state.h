/* SPDX-License-Identifier: LGPL-2.1-or-later
 * This small policy helper is compiled into Wine's LGPL-licensed CoreAudio driver.
 */
#ifndef IDV_DEFAULT_DEVICE_FOLLOWING_STATE_H
#define IDV_DEFAULT_DEVICE_FOLLOWING_STATE_H

#include <stdint.h>

/* Pure policy helpers shared by the Wine path and the no-device test. */
static inline int idv_audio_route_needs_rebuild(uint32_t current_device,
                                                uint32_t target_device,
                                                int audio_available,
                                                int reconfiguring)
{
    return !reconfiguring && (!audio_available || current_device != target_device);
}

static inline int idv_audio_route_candidate_matches(uint32_t requested_device,
                                                     uint32_t current_default,
                                                     int default_read_succeeded,
                                                     int candidate_ready,
                                                     int capture_buffer_ready,
                                                     int stopping)
{
    return !stopping && default_read_succeeded && candidate_ready &&
           capture_buffer_ready && requested_device == current_default;
}

static inline int idv_audio_capture_buffer_size_valid(uint64_t frames,
                                                       uint64_t bytes_per_frame,
                                                       uint64_t size_max)
{
    return frames && bytes_per_frame && frames <= size_max / bytes_per_frame;
}

static inline int idv_audio_route_retry_due(unsigned int *polls_remaining)
{
    if(*polls_remaining){
        --*polls_remaining;
        return 0;
    }
    return 1;
}

static inline void idv_audio_route_schedule_retry(unsigned int *polls_remaining)
{
    *polls_remaining = 4; /* Four 100 ms polls between failed rebuild attempts. */
}

#endif
