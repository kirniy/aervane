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
    if (result != KERN_SUCCESS || p.result != 0) return result ? result : kIOReturnError;
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

static int read_named_float(const char *name, float *value) {
    unsigned char bytes[32]; size_t length = 0; uint32_t type = 0;
    int result = zsmc_read_key_name(name, bytes, sizeof(bytes), &length, &type);
    if (result != KERN_SUCCESS) return result;
    if (type == 0x666c7420 && length == sizeof(float)) memcpy(value, bytes, sizeof(float));
    else if (type == 0x66706532 && length == 2) *value = (float)((bytes[0] << 8) | bytes[1]) / 4.0f;
    else return kIOReturnBadArgument;
    return KERN_SUCCESS;
}

int zsmc_target_rpm(double minimum, double maximum, double percent, double *target) {
    if (!target || !isfinite(percent) || percent < 0 || percent > 100 ||
        !isfinite(minimum) || !isfinite(maximum) || minimum < 0 || maximum <= 0 || minimum > maximum)
        return kIOReturnBadArgument;
    *target = fmax(minimum, fmin(maximum, maximum * percent / 100.0));
    return KERN_SUCCESS;
}

int zsmc_set_fan_percent(uint32_t fan_index, double percent) {
    if (!isfinite(percent) || percent < 0.0 || percent > 100.0 || fan_index > 9) return kIOReturnBadArgument;
    char min_key[5], max_key[5], target_key[5], mode_key[5];
    snprintf(min_key, sizeof(min_key), "F%uMn", fan_index); snprintf(max_key, sizeof(max_key), "F%uMx", fan_index);
    snprintf(target_key, sizeof(target_key), "F%uTg", fan_index); snprintf(mode_key, sizeof(mode_key), "F%uMd", fan_index);
    // Never assume a mode key exists: Apple models differ and a missing mode
    // key means we cannot safely claim manual control.
    uint8_t current_mode = 0; size_t mode_length = 0; uint32_t mode_type = 0;
    int mode_result = zsmc_read_key_name(mode_key, &current_mode, sizeof(current_mode), &mode_length, &mode_type);
    if (mode_result != KERN_SUCCESS || mode_length != 1 || mode_type != 0x75693820 || (current_mode != 0 && current_mode != 1 && current_mode != 3)) return mode_result ? mode_result : kIOReturnUnsupported;
    float min_value = 0, max_value = 0;
    int result = read_named_float(min_key, &min_value); if (result) return result;
    result = read_named_float(max_key, &max_value); if (result) return result;
    if (!isfinite(min_value) || !isfinite(max_value) || min_value < 0.0f ||
        max_value <= 0.0f || min_value > max_value)
        return kIOReturnBadArgument;
    double mapped_target = 0;
    result = zsmc_target_rpm(min_value, max_value, percent, &mapped_target); if (result) return result;
    float target = (float)mapped_target;
    // Stage the target while automatic control remains active, then switch to
    // manual mode so a failed target write cannot leave an old manual target.
    ZSMCKeyInfo target_info; result = zsmc_key_info(key_code(target_key), &target_info); if (result) return result;
    if (target_info.dataType == 0x666c7420 && target_info.dataSize == 4)
        result = zsmc_write_key_name(target_key, &target, sizeof(target), 0x666c7420);
    else if (target_info.dataType == 0x66706532 && target_info.dataSize == 2 && target <= 16383.75f) {
        uint16_t raw = (uint16_t)lroundf(target * 4.0f);
        uint8_t encoded[2] = { raw >> 8, raw & 0xff };
        result = zsmc_write_key_name(target_key, encoded, 2, 0x66706532);
    } else return kIOReturnUnsupported;
    if (result) return result;
    uint8_t mode = 1;
    return zsmc_write_key_name(mode_key, &mode, sizeof(mode), 0x75693820);
}

int zsmc_set_fan_automatic(uint32_t fan_index) {
    if (fan_index > 9) return kIOReturnBadArgument;
    char mode_key[5]; snprintf(mode_key, sizeof(mode_key), "F%uMd", fan_index);
    uint8_t current_mode = 0; size_t mode_length = 0; uint32_t mode_type = 0;
    int mode_result = zsmc_read_key_name(mode_key, &current_mode, sizeof(current_mode), &mode_length, &mode_type);
    if (mode_result != KERN_SUCCESS || mode_length != 1 || mode_type != 0x75693820 || (current_mode != 0 && current_mode != 1 && current_mode != 3)) return mode_result ? mode_result : kIOReturnUnsupported;
    uint8_t mode = 0;
    return zsmc_write_key_name(mode_key, &mode, sizeof(mode), 0x75693820);
}
