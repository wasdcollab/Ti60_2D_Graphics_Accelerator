#include <assert.h>
#include <string.h>
#define AUDIO_STREAM_HOST_TEST
#include "../sw/driver/audio_stream.c"

uint8_t mock_store[MM_BGM_CAPACITY];
static uint8_t rx[128], tx[256], samples[8192];
static uint32_t rx_count, rx_pos, tx_count, sample_count, level, clocks, clears;
static uint32_t tx_room = 128;
uint32_t cycle_now(void) { return clocks; }
uint32_t mock_read(uint32_t address)
{
    if (address == UART_BASE + 4u) return ((rx_count - rx_pos) << 24) | (tx_room << 16);
    if (address == UART_BASE) { assert(rx_pos < rx_count); return rx[rx_pos++]; }
    if (address == PCM_STATUS) return level;
    return 0;
}
void mock_write(uint32_t address, uint32_t value)
{
    if (address == UART_BASE) { assert(tx_count < sizeof(tx)); tx[tx_count++] = (uint8_t)value; }
    if (address == PCM_CTRL && (value & 2)) { level = 0; ++clears; }
    if (address == PCM_DATA) {
        assert(level < 2048 && sample_count < sizeof(samples));
        ++level; samples[sample_count++] = (uint8_t)value;
    }
}
void test_reset(void)
{
    bgm_size = bgm_ready = loaded = cursor = track_crc = expected_crc = 0;
    received = last_rx = reply_key = error = reply_pending = 0;
    rx_count = rx_pos = tx_count = sample_count = level = clocks = clears = 0;
    tx_room = 128;
    memset(mock_store, 0x55, sizeof(mock_store));
}
void test_receive(const uint8_t *data, uint32_t count)
{
    assert(count <= sizeof(rx)); memcpy(rx, data, count); rx_count = count; rx_pos = 0;
}
uint32_t test_reply(uint8_t *data)
{
    uint32_t count = tx_count; memcpy(data, tx, count); tx_count = 0; return count;
}
uint32_t test_samples(uint8_t *data)
{
    memcpy(data, samples, sample_count); return sample_count;
}
void test_time(uint32_t value) { clocks = value; }
void test_room(uint32_t value) { tx_room = value; }
void test_drain(void) { level = 0; }
uint32_t test_clears(void) { return clears; }
uint32_t test_byte(uint32_t address) { assert(address < sizeof(mock_store)); return mock_store[address]; }
