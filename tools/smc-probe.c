#include "SMC.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    static const char *keys[] = {"TC0P", "TC0E", "TC0F", "Tp0P", "Tp0T", "F0Ac", "F0Mn", "F0Mx", "FNum"};
    if (zsmc_open() != 0) { fprintf(stderr, "AppleSMC unavailable\n"); return 2; }
    uint32_t count = 0;
    if (zsmc_key_count(&count) == 0) printf("key_count=%u\n", count);
    for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); ++i) {
        unsigned char data[32]; size_t len = 0; uint32_t type = 0;
        int rc = zsmc_read_key_name(keys[i], data, sizeof(data), &len, &type);
        if (rc != 0) { printf("%s error=%d\n", keys[i], rc); continue; }
        printf("%s type=%08x len=%zu bytes=", keys[i], type, len);
        for (size_t j = 0; j < len; ++j) printf("%02x", data[j]);
        puts("");
    }
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t key = 0; if (zsmc_key_at_index(i, &key) != 0) continue;
        char name[5] = {(char)(key >> 24), (char)(key >> 16), (char)(key >> 8), (char)key, 0};
        unsigned char data[32]; size_t len = 0; uint32_t type = 0;
        if (zsmc_read_key_name(name, data, sizeof(data), &len, &type) == 0 && (type == 0x73706c74 || type == 0x666c7420)) {
            printf("candidate %s type=%08x len=%zu bytes=", name, type, len);
            for (size_t j = 0; j < len; ++j) printf("%02x", data[j]); puts("");
        }
    }
    zsmc_close(); return 0;
}
