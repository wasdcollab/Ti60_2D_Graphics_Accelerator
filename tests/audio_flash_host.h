#include <stdint.h>
uint32_t host_read(uint32_t addr);
void host_write(uint32_t addr, uint32_t value);
#define READ(addr) host_read(addr)
#define WRITE(addr, value) host_write(addr, value)
