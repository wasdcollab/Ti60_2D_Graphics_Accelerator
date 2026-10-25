#ifndef AUDIO_STREAM_H
#define AUDIO_STREAM_H
#include <stdint.h>

extern uint32_t bgm_size, bgm_ready;
void audio_stream_service(void);
void audio_stream_init(void);

#endif
