#include <assert.h>
#include <stdio.h>
#include <string.h>
#define AUDIO_STREAM_HOST_TEST
#include "../sw/driver/audio_stream.c"

static unsigned cs, pos, address, result, delay, transfers, fail_at, polls;
static unsigned level, enabled, total;
static unsigned awake;
static unsigned char bank[731], samples[16384];
uint32_t host_read(uint32_t addr)
{
    if (addr == PCM_STATUS) return level;
    if (addr == FLASH_CS) return cs;
    assert(addr == FLASH_DATA);
    ++polls;
    if (transfers == fail_at) return 256;
    if (delay) { --delay; return 256; }
    return result;
}
void host_write(uint32_t addr, uint32_t val)
{
    if (addr == FLASH_CS) { cs = val; pos = address = 0; return; }
    if (addr == PCM_CTRL) {
        enabled = val & 1;
        if (val & 2) level = 0;
        return;
    }
    if (addr == PCM_DATA) {
        assert(enabled && level < 2048 && total < sizeof(samples));
        ++level; samples[total++] = val; return;
    }
    assert(addr == FLASH_DATA && cs == 0 && delay == 0);
    val &= 255; result = 255; delay = 2; ++transfers;
    if (pos == 0) {
        if (val == 0xAB) awake = 1;
        else assert(val == 3 && awake);
    }
    else if (pos < 4) address = (address << 8) | val;
    else {
        assert(address >= BGM_BASE && address < BGM_BASE + sizeof(bank));
        result = bank[address++ - BGM_BASE];
    }
    ++pos;
}
static void reset(void)
{
    cs = 1; pos = address = result = delay = transfers = polls = 0;
    level = enabled = total = 0; fail_at = ~0u;
    awake = 0;
    memcpy(bank, "BGM1", 4);
    unsigned len = sizeof(bank) - 8;
    for (unsigned i = 0; i < 4; ++i) bank[4+i] = len >> (8*i);
    for (unsigned i = 8; i < sizeof(bank); ++i) bank[i] = i * 37u;
}
int main(void)
{
    reset(); audio_stream_init();
    assert(bgm_ready && bgm_size == 723 && cs == 1 && enabled);
    for (unsigned pass = 0; pass < 8; ++pass) {
        unsigned before = total;
        audio_stream_service();
        assert(total - before <= 1024 && cs == 1);
        for (unsigned i = before; i < total; ++i) assert(samples[i] == bank[8 + i % 723]);
        if (pass > 1) level -= 777;
    }
    level = 2048; unsigned before = transfers;
    audio_stream_service(); assert(transfers == before);
    for (unsigned fault = 1; fault <= 13; ++fault) {
        reset(); fail_at = fault; audio_stream_init();
        assert(!bgm_ready && cs == 1 && !enabled && polls < 4200);
    }
    for (unsigned fault = 14; fault <= 51; ++fault) {
        reset(); audio_stream_init(); fail_at = fault; audio_stream_service();
        assert(!bgm_ready && cs == 1 && !enabled && polls < 4300);
    }
    reset(); bank[0] = 0; audio_stream_init(); assert(!bgm_ready);
    reset(); memset(bank+4, 0, 4); audio_stream_init(); assert(!bgm_ready);
    reset(); memset(bank+4, 255, 4); audio_stream_init(); assert(!bgm_ready);
    reset(); audio_stream_init(); assert(bgm_ready);
    puts("PASS: actual C flash driver, wake-up, exact PCM/loop, FIFO bounds, bad headers, 51 timeout positions, restart");
    return 0;
}
