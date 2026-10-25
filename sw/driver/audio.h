#ifndef GAME_AUDIO_H
#define GAME_AUDIO_H

#include <stdint.h>
#include "gpu2d.h"

/* APB 0x4C: [3:0] is sampled as a one-shot event.  Keeping enable/BGM in the
 * same write makes each event self-contained and does not require a read-modify-
 * write against a live peripheral register. */
#define AUDIO_REG_CONTROL (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x4Cu))
#define AUDIO_ENABLE       (1u << 8)
#define AUDIO_BGM_ENABLE   (1u << 9)
#define AUDIO_VOLUME_SHIFT 12u
#define AUDIO_VOLUME_MASK  (7u << AUDIO_VOLUME_SHIFT)

enum {
    AUDIO_EVENT_NONE  = 0u,
    AUDIO_EVENT_SHOT  = 1u,
    AUDIO_EVENT_LASER = 2u,
    AUDIO_EVENT_KILL  = 3u,
    AUDIO_EVENT_BOSS  = 4u,
    AUDIO_EVENT_HIT   = 5u
};

/* 0 = mute; 1..4 are 12.5%, 25%, 50%, and 100%. */
extern uint8_t game_audio_volume;

static inline void audio_write(uint32_t event)
{
    AUDIO_REG_CONTROL = AUDIO_ENABLE | AUDIO_BGM_ENABLE |
        (((uint32_t)game_audio_volume & 7u) << AUDIO_VOLUME_SHIFT) |
        (event & 0x0Fu);
}

static inline void audio_event(uint32_t event)
{
    audio_write(event);
}

#endif
