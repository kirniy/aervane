#include "SMC.h"

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <pthread.h>

// AppleSMC user-client command values. These are the stable public user-client
// interface used by the open-source smcFanControl family; no vendor binary is
// linked into Zephyr.
enum { ZSMC_USER_CLIENT_EVENT = 2, ZSMC_GET_KEY_COUNT = 4, ZSMC_READ_KEY = 5, ZSMC_WRITE_KEY = 6, ZSMC_GET_KEY_FROM_INDEX = 8, ZSMC_GET_KEY_INFO = 9 };
// SMC-level result byte for an absent key (kSMCKeyNotFound).
enum { ZSMC_RESULT_KEY_NOT_FOUND = 0x84 };
static io_connect_t g_connection = IO_OBJECT_NULL;
static pthread_mutex_t g_connection_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t key_code(const char *name) {
    return ((uint32_t)(uint8_t)name[0] << 24) |
           ((uint32_t)(uint8_t)name[1] << 16) |
           ((uint32_t)(uint8_t)name[2] << 8) |
           (uint32_t)(uint8_t)name[3];
}

static int call(uint32_t index, ZSMCParam *p) {
    if (!p) return kIOReturnBadArgument;
    size_t in_size = sizeof(*p), out_size = sizeof(*p);
    pthread_mutex_lock(&g_connection_lock);
    if (g_connection == IO_OBJECT_NULL) { pthread_mutex_unlock(&g_connection_lock); return kIOReturnNotOpen; }
    int result = IOConnectCallStructMethod(g_connection, index, p, in_size, p, &out_size);
    pthread_mutex_unlock(&g_connection_lock);
    if (result == KERN_SUCCESS && out_size != sizeof(*p)) return kIOReturnUnderrun;
    return result;
}

int zsmc_open(void) {
    pthread_mutex_lock(&g_connection_lock);
    if (g_connection != IO_OBJECT_NULL) { pthread_mutex_unlock(&g_connection_lock); return 0; }
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (!matching) { pthread_mutex_unlock(&g_connection_lock); return kIOReturnError; }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) { pthread_mutex_unlock(&g_connection_lock); return kIOReturnNoDevice; }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &g_connection);
    IOObjectRelease(service);
    pthread_mutex_unlock(&g_connection_lock); return result;
}

void zsmc_close(void) {
    pthread_mutex_lock(&g_connection_lock);
    if (g_connection != IO_OBJECT_NULL) {
        IOServiceClose(g_connection);
        g_connection = IO_OBJECT_NULL;
    }
    pthread_mutex_unlock(&g_connection_lock);
}

int zsmc_key_info(uint32_t key, ZSMCKeyInfo *info) {
    if (!info) return kIOReturnBadArgument;
    if (zsmc_open() != KERN_SUCCESS) return kIOReturnNotOpen;
    ZSMCParam p; memset(&p, 0, sizeof(p)); p.key = key; p.data8 = ZSMC_GET_KEY_INFO;
    int result = call(ZSMC_USER_CLIENT_EVENT, &p);
    if (result != KERN_SUCCESS) return result;
    // Only this SMC result says the key does not exist; callers treat every
    // other failure as possibly transient.
    if (p.result == ZSMC_RESULT_KEY_NOT_FOUND) return kIOReturnNotFound;
    if (p.result != 0) return kIOReturnError;
    memcpy(info, &p.keyInfoData, sizeof(ZSMCKeyInfo));
    return KERN_SUCCESS;
}

int zsmc_read_key(uint32_t key, void *out, size_t capacity, size_t *length, uint32_t *data_type) {
    if (!out || !length) return kIOReturnBadArgument;
    if (zsmc_open() != KERN_SUCCESS) return kIOReturnNotOpen;
    ZSMCKeyInfo info; int result = zsmc_key_info(key, &info);
    if (result != KERN_SUCCESS) return result;
    if (info.dataSize > sizeof(((ZSMCParam *)0)->bytes) || info.dataSize > capacity) return kIOReturnNoSpace;
    ZSMCParam p; memset(&p, 0, sizeof(p)); p.key = key; p.keyInfoData.dataSize = info.dataSize; p.data8 = ZSMC_READ_KEY; p.bytes[0] = 0;
    result = call(ZSMC_USER_CLIENT_EVENT, &p);
    if (result != KERN_SUCCESS || p.result != 0) return result ? result : kIOReturnError;
    memcpy(out, p.bytes, info.dataSize); *length = info.dataSize;
    if (data_type) *data_type = info.dataType;
    return KERN_SUCCESS;
}

int zsmc_read_key_name(const char *name, void *out, size_t capacity, size_t *length, uint32_t *data_type) {
    if (!name || strlen(name) != 4) return kIOReturnBadArgument;
    return zsmc_read_key(key_code(name), out, capacity, length, data_type);
}

int zsmc_write_key(uint32_t key, const void *data, size_t length, uint32_t data_type) {
    if (!data || length > sizeof(((ZSMCParam *)0)->bytes)) return kIOReturnBadArgument;
    if (zsmc_open() != KERN_SUCCESS) return kIOReturnNotOpen;
    ZSMCKeyInfo info;
    int info_result = zsmc_key_info(key, &info);
    if (info_result != KERN_SUCCESS) return info_result;
    if (info.dataSize != length || info.dataType != data_type) return kIOReturnBadArgument;
    ZSMCParam p; memset(&p, 0, sizeof(p)); p.key = key; p.keyInfoData.dataSize = (uint32_t)length; p.keyInfoData.dataType = data_type; p.data8 = ZSMC_WRITE_KEY;
    memcpy(p.bytes, data, length);
    int result = call(ZSMC_USER_CLIENT_EVENT, &p);
    if (result != KERN_SUCCESS || p.result != 0) return result ? result : kIOReturnError;
    return KERN_SUCCESS;
}

int zsmc_write_key_name(const char *name, const void *data, size_t length, uint32_t data_type) {
    if (!name || strlen(name) != 4) return kIOReturnBadArgument;
    return zsmc_write_key(key_code(name), data, length, data_type);
}

int zsmc_key_count(uint32_t *count) {
    if (!count) return kIOReturnBadArgument;
    if (zsmc_open() != KERN_SUCCESS) return kIOReturnNotOpen;
    ZSMCParam p; memset(&p, 0, sizeof(p)); p.data8 = ZSMC_GET_KEY_COUNT;
    int result = call(ZSMC_USER_CLIENT_EVENT, &p);
    if (result != KERN_SUCCESS || p.result != 0) return result ? result : kIOReturnError;
    *count = p.data32; return KERN_SUCCESS;
}

int zsmc_key_at_index(uint32_t index, uint32_t *key) {
    if (!key) return kIOReturnBadArgument;
    if (zsmc_open() != KERN_SUCCESS) return kIOReturnNotOpen;
    ZSMCParam p; memset(&p, 0, sizeof(p)); p.data8 = ZSMC_GET_KEY_FROM_INDEX; p.data32 = index;
    int result = call(ZSMC_USER_CLIENT_EVENT, &p);
    if (result != KERN_SUCCESS || p.result != 0) return result ? result : kIOReturnError;
    *key = p.key; return KERN_SUCCESS;
}

int zsmc_target_rpm(double minimum, double maximum, double percent, double *target) {
    if (!target || !isfinite(percent) || percent < 0 || percent > 100 ||
        !isfinite(minimum) || !isfinite(maximum) || minimum < 0 || maximum <= 0 || minimum > maximum)
        return kIOReturnBadArgument;
    *target = fmax(minimum, fmin(maximum, maximum * percent / 100.0));
    return KERN_SUCCESS;
}
