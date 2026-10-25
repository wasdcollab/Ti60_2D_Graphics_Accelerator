#include "audio_stream.h"
#include "gpu2d.h"

#ifndef AUDIO_STREAM_HOST_TEST
#define READ(addr) (*(volatile uint32_t *)(addr))
#define WRITE(addr, value) (*(volatile uint32_t *)(addr) = (value))
#else
#include "audio_flash_host.h"
#endif

#define PCM_CTRL (GPU2D_BASE_ADDR + 0x100u)
#define PCM_DATA (GPU2D_BASE_ADDR + 0x104u)
#define PCM_STATUS (GPU2D_BASE_ADDR + 0x108u)
#define FLASH_DATA (GPU2D_BASE_ADDR + 0x13Cu)
#define FLASH_CS (GPU2D_BASE_ADDR + 0x140u)
#define BGM_BASE 0x00200000u
#define BGM_LIMIT (0x00800000u - BGM_BASE - 8u)

uint32_t bgm_size, bgm_ready;
static uint32_t cursor;

static int transfer(unsigned byte)
{
    WRITE(FLASH_DATA, byte);
    for (unsigned budget = 0; budget < 4096u; ++budget) {
        unsigned status = READ(FLASH_DATA);
        if (!(status & 256u)) return status & 255u;
    }
    return -1;
}

static int read_begin(uint32_t addr)
{
    WRITE(FLASH_CS, 0u);
    return transfer(3u) >= 0 && transfer(addr >> 16) >= 0 &&
           transfer(addr >> 8) >= 0 && transfer(addr) >= 0;
}

void audio_stream_init(void)
{
    uint32_t header[2] = {0, 0};
    bgm_ready = bgm_size = cursor = 0;
    WRITE(PCM_CTRL, 2u);
    WRITE(FLASH_CS, 1u);
    WRITE(FLASH_CS, 0u);
    int awake = transfer(0xABu);
    WRITE(FLASH_CS, 1u);
    for (unsigned delay = 0; delay < 10000u; ++delay) (void)READ(FLASH_CS);
    if (awake >= 0 && read_begin(BGM_BASE)) {
        for (unsigned i = 0; i < 8u; ++i) {
            int byte = transfer(0u);
            if (byte < 0) break;
            header[i >> 2] |= (uint32_t)byte << ((i & 3u) * 8u);
            if (i == 7u && header[0] == 0x314D4742u && header[1] && header[1] <= BGM_LIMIT) {
                bgm_size = header[1]; bgm_ready = 1;
            }
        }
    }
    WRITE(FLASH_CS, 1u);
    if (bgm_ready) WRITE(PCM_CTRL, 3u);
}

__attribute__((noinline)) void audio_stream_service(void)
{
    if (!bgm_ready) return;
    unsigned level = READ(PCM_STATUS) & 0xFFFu;
    if (level >= 2048u) return;
    unsigned count = 2048u - level;
    if (count > 1024u) count = 1024u;
    while (count) {
        unsigned chunk = bgm_size - cursor;
        if (chunk > count) chunk = count;
        if (!read_begin(BGM_BASE + 8u + cursor)) goto fail;
        for (unsigned i = 0; i < chunk; ++i) {
            int byte = transfer(0u);
            if (byte < 0) goto fail;
            WRITE(PCM_DATA, (unsigned)byte);
        }
        WRITE(FLASH_CS, 1u);
        cursor += chunk;
        if (cursor == bgm_size) cursor = 0;
        count -= chunk;
    }
    return;
fail:
    WRITE(FLASH_CS, 1u);
    WRITE(PCM_CTRL, 2u);
    bgm_ready = 0;
}
