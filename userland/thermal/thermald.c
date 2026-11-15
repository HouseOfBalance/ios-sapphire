/*
 * thermald: Qualcomm Thermal Manager for iOS on Sapphire (SM6225/Snapdragon 685)
 *
 * Reads thermal zones from /sys/class/thermal/thermal_zone*/temp and PMIC PM6225 battery temp.
 * Implements 4-tier throttling policy:
 *   Normal (<40°C):    Full performance, A73 boost on touch
 *   Warm (40-45°C):    A73 max 2.4GHz, GPU max 900MHz
 *   Hot (45-50°C):     A73 max 1.9GHz, GPU max 610MHz, disable sustained boost
 *   Critical (>50°C):  Emergency throttle - all cores to min freq, GPU to 310MHz
 *
 * Deep Sleep / AMOLED Display Off:
 *   Listens for com.apple.springboard.hasBlankedScreen notification.
 *   On screen off:  Sends DSI DCS 0x28 (Display Off) + 0x10 (Sleep In), parks A73@min, GPU@310MHz
 *   On screen on:   Sends DSI DCS 0x11 (Sleep Out) + 0x29 (Display On), restores freqs
 *
 * Kernel sysctls exposed:
 *   kern.sweet_thermal_zone[N]      - per-zone temperature (millicelsius)
 *   kern.sweet_thermal_state        - 0=Normal, 1=Warm, 2=Hot, 3=Critical
 *   kern.sweet_thermal_policy       - bitmask of active mitigations
 *   kern.sweet_deep_sleep           - 1 if deep sleep active (screen off + panel asleep)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <pthread.h>
#include <dispatch/dispatch.h>

#define LOG_PATH "/var/tmp/thermald.log"
#define LOG_MAX (128 * 1024)

#define THERMAL_BASE "/sys/class/thermal"
#define PMIC_TEMP_PATH "/sys/class/power_supply/battery/temp"

#define ZONE_SOC      0   // SoC / CPU cluster
#define ZONE_GPU      1   // GPU (Adreno 610)
#define ZONE_BATTERY  2   // Battery PMIC (PM6225)
#define ZONE_SKIN     3   // Skin temperature (if available)
#define ZONE_COUNT    4

// Thermal trip points (millicelsius)
#define TRIP_NORMAL_MAX   40000
#define TRIP_WARM_MAX     45000
#define TRIP_HOT_MAX      50000

// Thermal states
enum {
    THERMAL_NORMAL = 0,
    THERMAL_WARM   = 1,
    THERMAL_HOT    = 2,
    THERMAL_CRITICAL = 3
};

// Policy bitmask
#define POLICY_A73_LIMIT_2400   (1u << 0)  // Limit A73 to 2.4GHz
#define POLICY_A73_LIMIT_1900   (1u << 1)  // Limit A73 to 1.9GHz
#define POLICY_A73_MIN_FREQ     (1u << 2)  // Force A73 to min freq
#define POLICY_GPU_LIMIT_900    (1u << 3)  // Limit GPU to 900MHz
#define POLICY_GPU_LIMIT_610    (1u << 4)  // Limit GPU to 610MHz
#define POLICY_GPU_MIN_FREQ     (1u << 5)  // Force GPU to 310MHz
#define POLICY_DISABLE_BOOST    (1u << 6)  // Disable touch/launch boost
#define POLICY_DEEP_SLEEP       (1u << 7)  // Deep sleep active

// Frequency paths (sysfs)
#define CPUFREQ_POLICY4 "/sys/devices/system/cpu/cpufreq/policy4"  // A73 cluster (cores 4-7)
#define CPUFREQ_POLICY0 "/sys/devices/system/cpu/cpufreq/policy0"  // A53 cluster (cores 0-3)
#define GPU_FREQ_PATH   "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq"
#define GPU_MIN_FREQ    "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq"
#define GPU_MAX_FREQ    "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"

// DSI panel control (via sysctl or direct write if available)
#define SYSCTL_DSI_CMD  "kern.sweet_dsi_cmd"

// Notification names
#define N_BLANKED "com.apple.springboard.hasBlankedScreen"

static int zone_fd[ZONE_COUNT] = {-1, -1, -1, -1};
static int zone_type[ZONE_COUNT] = {-1, -1, -1, -1};
static char zone_name[ZONE_COUNT][64];
static int zone_count = 0;

static int therm_state = THERMAL_NORMAL;
static unsigned therm_policy = 0;
static int deep_sleep_active = 0;
static int blank_token = -1;
static dispatch_queue_t main_queue;
static dispatch_source_t poll_timer;
static mach_timebase_info_data_t tb;

static void
logf(const char *fmt, ...)
{
    char msg[512], line[576];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    struct stat st;
    if (stat(LOG_PATH, &st) == 0 && st.st_size > LOG_MAX) {
        rename(LOG_PATH, LOG_PATH ".1");
    }
    int fd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    int n = snprintf(line, sizeof(line), "%02d-%02d %02d:%02d:%02d %s\n",
                     tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, msg);
    if (n > 0) write(fd, line, n < sizeof(line) ? n : sizeof(line) - 1);
    close(fd);
    fprintf(stderr, "%s\n", msg);
}

static uint64_t
now_us(void)
{
    return mach_absolute_time() * tb.numer / tb.denom / 1000;
}

static int
read_temp_file(const char *path)
{
    char buf[32];
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return atoi(buf);  // millicelsius
}

static int
write_sysfs(const char *path, const char *val)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    ssize_t n = write(fd, val, strlen(val));
    close(fd);
    return n > 0 ? 0 : -1;
}

static int
sysctl_set_uint(const char *name, unsigned val)
{
    size_t len = sizeof(val);
    return sysctlbyname(name, NULL, NULL, &val, len);
}

static int
sysctl_set_int(const char *name, int val)
{
    size_t len = sizeof(val);
    return sysctlbyname(name, NULL, NULL, &val, len);
}

static void
update_sysctls(void)
{
    for (int i = 0; i < zone_count; i++) {
        char sysctl_name[64];
        snprintf(sysctl_name, sizeof(sysctl_name), "kern.sweet_thermal_zone%d", i);
        int temp = read_temp_file(zone_name[i]);
        if (temp >= 0) {
            sysctl_set_int(sysctl_name, temp);
        }
    }
    sysctl_set_int("kern.sweet_thermal_state", therm_state);
    sysctl_set_int("kern.sweet_thermal_policy", therm_policy);
    sysctl_set_int("kern.sweet_deep_sleep", deep_sleep_active);
}

static void
apply_cpu_policy(void)
{
    const char *max_freq_path = CPUFREQ_POLICY4 "/scaling_max_freq";
    const char *min_freq_path = CPUFREQ_POLICY4 "/scaling_min_freq";
    const char *governor_path = CPUFREQ_POLICY4 "/scaling_governor";

    if (therm_policy & POLICY_A73_MIN_FREQ) {
        // Force minimum frequency (typically ~300-400MHz)
        write_sysfs(max_freq_path, "400000");
        write_sysfs(min_freq_path, "300000");
        write_sysfs(governor_path, "powersave");
    } else if (therm_policy & POLICY_A73_LIMIT_1900) {
        write_sysfs(max_freq_path, "1900000");
        write_sysfs(governor_path, "schedutil");
    } else if (therm_policy & POLICY_A73_LIMIT_2400) {
        write_sysfs(max_freq_path, "2400000");
        write_sysfs(governor_path, "schedutil");
    } else {
        // Normal: full performance
        write_sysfs(max_freq_path, "2803200");  // 2.8GHz
        write_sysfs(governor_path, "performance");
    }
}

static void
apply_gpu_policy(void)
{
    if (therm_policy & POLICY_GPU_MIN_FREQ) {
        write_sysfs(GPU_MAX_FREQ, "310000000");  // 310MHz
    } else if (therm_policy & POLICY_GPU_LIMIT_610) {
        write_sysfs(GPU_MAX_FREQ, "610000000");  // 610MHz
    } else if (therm_policy & POLICY_GPU_LIMIT_900) {
        write_sysfs(GPU_MAX_FREQ, "900000000");  // 900MHz
    } else {
        write_sysfs(GPU_MAX_FREQ, "1113600000"); // 1114MHz (max)
    }
}

static void
apply_boost_policy(void)
{
    if (therm_policy & POLICY_DISABLE_BOOST) {
        sysctl_set_int("kern.sweet_touch_boost_enabled", 0);
        sysctl_set_int("kern.sweet_launch_boost_enabled", 0);
    } else {
        sysctl_set_int("kern.sweet_touch_boost_enabled", 1);
        sysctl_set_int("kern.sweet_launch_boost_enabled", 1);
    }
}

static void
send_dsi_cmd(uint8_t cmd, const uint8_t *params, int param_count)
{
    // Build sysctl payload: [cmd][param_count][params...]
    uint8_t payload[32];
    payload[0] = cmd;
    payload[1] = param_count;
    if (param_count > 0 && param_count <= 30) {
        memcpy(payload + 2, params, param_count);
    }
    size_t len = 2 + param_count;
    sysctlbyname("kern.sweet_dsi_cmd", NULL, NULL, payload, len);
}

static void
enter_deep_sleep(void)
{
    if (deep_sleep_active) return;

    logf("Entering deep sleep: DSI Display Off + Sleep In");

    // 1. DSI Display Off (0x28)
    send_dsi_cmd(0x28, NULL, 0);

    // 2. DSI Sleep In (0x10) - puts panel in lowest power state
    send_dsi_cmd(0x10, NULL, 0);

    // 3. Park CPU/GPU to minimum
    write_sysfs(CPUFREQ_POLICY4 "/scaling_max_freq", "400000");
    write_sysfs(CPUFREQ_POLICY4 "/scaling_min_freq", "300000");
    write_sysfs(CPUFREQ_POLICY4 "/scaling_governor", "powersave");
    write_sysfs(GPU_MAX_FREQ, "310000000");

    // 4. Disable boosts
    sysctl_set_int("kern.sweet_touch_boost_enabled", 0);
    sysctl_set_int("kern.sweet_launch_boost_enabled", 0);

    deep_sleep_active = 1;
    therm_policy |= POLICY_DEEP_SLEEP;
    update_sysctls();
}

static void
exit_deep_sleep(void)
{
    if (!deep_sleep_active) return;

    logf("Exiting deep sleep: DSI Sleep Out + Display On");

    // 1. DSI Sleep Out (0x11) - exit sleep mode
    send_dsi_cmd(0x11, NULL, 0);
    usleep(120000);  // 120ms delay per DSI spec

    // 2. DSI Display On (0x29)
    send_dsi_cmd(0x29, NULL, 0);

    // 3. Restore CPU/GPU frequencies
    apply_cpu_policy();
    apply_gpu_policy();
    apply_boost_policy();

    deep_sleep_active = 0;
    therm_policy &= ~POLICY_DEEP_SLEEP;
    update_sysctls();
}

static void
blank_changed(int token)
{
    uint64_t state = 0;
    notify_get_state(token, &state);
    logf("Screen blank state changed: %llu", state);

    if (state == 1) {
        // Screen blanked -> enter deep sleep
        enter_deep_sleep();
    } else {
        // Screen unblanked -> exit deep sleep
        exit_deep_sleep();
    }
}

static void
evaluate_thermal_state(void)
{
    int max_temp = 0;
    int hottest_zone = -1;

    for (int i = 0; i < zone_count; i++) {
        int temp = read_temp_file(zone_name[i]);
        if (temp > max_temp) {
            max_temp = temp;
            hottest_zone = i;
        }
    }

    int new_state = THERMAL_NORMAL;
    unsigned new_policy = 0;

    if (max_temp >= TRIP_HOT_MAX) {
        new_state = THERMAL_CRITICAL;
        new_policy = POLICY_A73_MIN_FREQ | POLICY_GPU_MIN_FREQ | POLICY_DISABLE_BOOST;
        logf("THERMAL CRITICAL: zone %d at %d m°C", hottest_zone, max_temp);
    } else if (max_temp >= TRIP_WARM_MAX) {
        new_state = THERMAL_HOT;
        new_policy = POLICY_A73_LIMIT_1900 | POLICY_GPU_LIMIT_610 | POLICY_DISABLE_BOOST;
        logf("THERMAL HOT: zone %d at %d m°C", hottest_zone, max_temp);
    } else if (max_temp >= TRIP_NORMAL_MAX) {
        new_state = THERMAL_WARM;
        new_policy = POLICY_A73_LIMIT_2400 | POLICY_GPU_LIMIT_900;
        logf("THERMAL WARM: zone %d at %d m°C", hottest_zone, max_temp);
    } else {
        new_state = THERMAL_NORMAL;
        new_policy = 0;
        logf("THERMAL NORMAL: max %d m°C", max_temp);
    }

    // Only apply changes if state actually changed
    if (new_state != therm_state || new_policy != therm_policy) {
        therm_state = new_state;
        therm_policy = new_policy & ~POLICY_DEEP_SLEEP; // Preserve deep sleep bit

        if (!deep_sleep_active) {
            apply_cpu_policy();
            apply_gpu_policy();
            apply_boost_policy();
        }
        update_sysctls();
    }
}

static void
discover_thermal_zones(void)
{
    DIR *d = opendir(THERMAL_BASE);
    if (!d) {
        logf("Cannot open %s: %s", THERMAL_BASE, strerror(errno));
        return;
    }

    struct dirent *e;
    while ((e = readdir(d)) != NULL && zone_count < ZONE_COUNT) {
        if (e->d_name[0] == '.') continue;
        if (strncmp(e->d_name, "thermal_zone", 12) != 0) continue;

        char path[256], type_path[256], temp_path[256];
        snprintf(path, sizeof(path), "%s/%s", THERMAL_BASE, e->d_name);
        snprintf(type_path, sizeof(type_path), "%s/type", path);
        snprintf(temp_path, sizeof(temp_path), "%s/temp", path);

        char type_buf[64];
        int fd = open(type_path, O_RDONLY);
        if (fd >= 0) {
            ssize_t n = read(fd, type_buf, sizeof(type_buf) - 1);
            close(fd);
            if (n > 0) {
                type_buf[n] = '\0';
                char *nl = strchr(type_buf, '\n');
                if (nl) *nl = '\0';
            }
        } else {
            strcpy(type_buf, "unknown");
        }

        // Map zone types to our indices
        int idx = -1;
        if (strstr(type_buf, "cpu") || strstr(type_buf, "soc") || strstr(type_buf, "cluster")) {
            idx = ZONE_SOC;
        } else if (strstr(type_buf, "gpu") || strstr(type_buf, "adreno")) {
            idx = ZONE_GPU;
        } else if (strstr(type_buf, "battery") || strstr(type_buf, "pmic")) {
            idx = ZONE_BATTERY;
        } else if (strstr(type_buf, "skin")) {
            idx = ZONE_SKIN;
        } else {
            idx = zone_count; // Assign sequentially
        }

        if (idx >= 0 && idx < ZONE_COUNT) {
            strncpy(zone_name[idx], temp_path, sizeof(zone_name[idx]) - 1);
            strncpy(zone_name[idx], path, sizeof(zone_name[idx]) - 1);
            zone_type[idx] = idx;
            zone_count = idx + 1;
            logf("Found thermal zone %d: %s (type: %s)", idx, e->d_name, type_buf);
        }
    }
    closedir(d);

    // Add PMIC battery temperature if available
    if (access(PMIC_TEMP_PATH, R_OK) == 0 && zone_count < ZONE_COUNT) {
        strncpy(zone_name[ZONE_BATTERY], PMIC_TEMP_PATH, sizeof(zone_name[ZONE_BATTERY]) - 1);
        zone_type[ZONE_BATTERY] = ZONE_BATTERY;
        if (ZONE_BATTERY + 1 > zone_count) zone_count = ZONE_BATTERY + 1;
        logf("Found PMIC battery temp at %s", PMIC_TEMP_PATH);
    }

    logf("Total thermal zones: %d", zone_count);
}

static void
poll_timer_callback(void *ctx)
{
    (void)ctx;
    evaluate_thermal_state();
    update_sysctls();
}

int
main(void)
{
    mach_timebase_info(&tb);
    setvbuf(stderr, NULL, _IOLBF, 0);

    logf("thermald starting (PID %d)", getpid());

    // Discover thermal zones
    discover_thermal_zones();

    // Register for screen blank notification
    if (notify_register_check(N_BLANKED, &blank_token) == NOTIFY_STATUS_OK) {
        logf("Registered for %s notification", N_BLANKED);
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        notify_register_dispatch(N_BLANKED, &blank_token, q, ^(int token) {
            blank_changed(token);
        });
    } else {
        logf("Failed to register for %s", N_BLANKED);
    }

    // Create main queue for timer
    main_queue = dispatch_queue_create("com.sapphire.thermald", DISPATCH_QUEUE_SERIAL);

    // Poll thermal zones every 3 seconds
    poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, main_queue);
    dispatch_source_set_timer(poll_timer,
        dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC),
        3ull * NSEC_PER_SEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(poll_timer, ^{
        poll_timer_callback(NULL);
    });
    dispatch_resume(poll_timer);

    // Initial evaluation
    evaluate_thermal_state();
    update_sysctls();

    logf("thermald entering main loop");
    dispatch_main();
    return 0;
}