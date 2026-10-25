#include <stdint.h>
uint32_t mock_read(uint32_t address);
void mock_write(uint32_t address, uint32_t value);
uint32_t cycle_now(void);
extern uint8_t mock_store[];
#define READ(addr) mock_read(addr)
#define WRITE(addr, value) mock_write(addr, value)
#define PCM_STORE mock_store
