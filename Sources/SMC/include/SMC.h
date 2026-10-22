#ifndef ZEPHYR_SMC_H
#define ZEPHYR_SMC_H
#include <stdint.h>
#include <stddef.h>
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } ZSMCKeyInfo;
typedef struct { uint32_t key; uint8_t vers[6]; uint8_t pLimitData[16]; ZSMCKeyInfo keyInfoData; uint8_t result; uint8_t status; uint8_t data8; uint32_t data32; uint8_t bytes[32]; } ZSMCParam;
int zsmc_open(void);
void zsmc_close(void);
int zsmc_read_key(uint32_t key, void *out, size_t capacity, size_t *length, uint32_t *data_type);
int zsmc_key_info(uint32_t key, ZSMCKeyInfo *info);
int zsmc_read_key_name(const char *name, void *out, size_t capacity, size_t *length, uint32_t *data_type);
int zsmc_write_key(uint32_t key, const void *data, size_t length, uint32_t data_type);
int zsmc_write_key_name(const char *name, const void *data, size_t length, uint32_t data_type);
int zsmc_key_count(uint32_t *count);
int zsmc_key_at_index(uint32_t index, uint32_t *key);
// Pure mapping shared by writes and regression tests. Percent is physical
// target / maximum, clamped to the firmware floor (never range-normalized).
int zsmc_target_rpm(double minimum, double maximum, double percent, double *target);
int zsmc_set_fan_percent(uint32_t fan_index, double percent);
int zsmc_set_fan_automatic(uint32_t fan_index);
#endif
