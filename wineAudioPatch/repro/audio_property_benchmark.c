#include <CoreAudio/CoreAudio.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <time.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_SECONDS 15
#define REPETITIONS 3
#define RATE_COUNT 4

typedef struct {
    uint64_t call_ns;
    uint64_t lateness_ns;
    int selector;
    int status;
} TickResult;

typedef struct {
    double user;
    double system;
} CPUTime;

static mach_timebase_info_data_t timebase;
static FILE *summary_file;
static FILE *calls_file;

static uint64_t ticks_to_ns(uint64_t ticks)
{
    return (uint64_t)((double)ticks * (double)timebase.numer / (double)timebase.denom);
}

static uint64_t ns_to_ticks(uint64_t ns)
{
    return (uint64_t)((double)ns * (double)timebase.denom / (double)timebase.numer);
}

static double timeval_seconds(struct timeval value)
{
    return (double)value.tv_sec + (double)value.tv_usec / 1000000.0;
}

static CPUTime process_cpu_time(void)
{
    struct rusage usage;
    CPUTime result = {0, 0};
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        result.user = timeval_seconds(usage.ru_utime);
        result.system = timeval_seconds(usage.ru_stime);
    }
    return result;
}

static CPUTime current_thread_cpu_time(void)
{
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    thread_t thread = mach_thread_self();
    CPUTime result = {0, 0};
    if (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS) {
        result.user = (double)info.user_time.seconds + (double)info.user_time.microseconds / 1000000.0;
        result.system = (double)info.system_time.seconds + (double)info.system_time.microseconds / 1000000.0;
    }
    mach_port_deallocate(mach_task_self(), thread);
    return result;
}

static int compare_u64(const void *left, const void *right)
{
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static uint64_t percentile(uint64_t *values, size_t count, double fraction)
{
    if (count == 0) return 0;
    qsort(values, count, sizeof(*values), compare_u64);
    size_t index = (size_t)ceil(fraction * (double)count);
    if (index == 0) index = 1;
    if (index > count) index = count;
    return values[index - 1];
}

static double one_minute_load(void)
{
    double loads[3] = {0, 0, 0};
    if (getloadavg(loads, 3) < 1) return -1;
    return loads[0];
}

static int query_default_device(int selector, OSStatus *status)
{
    AudioObjectPropertyAddress address = {
        .mSelector = selector == 0 ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    *status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    return 0;
}

static const char *flow_name(int flow_mode)
{
    switch (flow_mode) {
        case 0: return "output";
        case 1: return "input";
        case 2: return "alternating";
        default: return "none";
    }
}

static void write_sample(int run_id, int is_query, int rate, int flow_mode, TickResult *results, size_t count,
                         uint64_t wall_ns, CPUTime process_before, CPUTime process_after,
                         CPUTime thread_before, CPUTime thread_after, double load_before,
                         double load_after)
{
    uint64_t *calls = calloc(count ? count : 1, sizeof(*calls));
    uint64_t *lateness = calloc(count ? count : 1, sizeof(*lateness));
    if (!calls || !lateness) {
        fprintf(stderr, "out of memory while summarizing sample\n");
        exit(2);
    }

    size_t call_count = 0;
    int errors = 0;
    uint64_t call_max = 0;
    uint64_t call_min = UINT64_MAX;
    uint64_t lateness_max = 0;
    for (size_t i = 0; i < count; ++i) {
        if (is_query) calls[call_count++] = results[i].call_ns;
        if (results[i].status != noErr) ++errors;
        if (is_query && results[i].call_ns < call_min) call_min = results[i].call_ns;
        if (results[i].call_ns > call_max) call_max = results[i].call_ns;
        if (results[i].lateness_ns > lateness_max) lateness_max = results[i].lateness_ns;
        fprintf(calls_file, "%d,%s,%d,%s,%zu,%s,%d,%llu,%llu\n",
                run_id, is_query ? "query" : "baseline", rate, flow_name(flow_mode), i,
                results[i].selector < 0 ? "none" : results[i].selector == 0 ? "output" : "input",
                results[i].status,
                (unsigned long long)results[i].call_ns,
                (unsigned long long)results[i].lateness_ns);
    }
    for (size_t i = 0; i < count; ++i) lateness[i] = results[i].lateness_ns;

    double wall_seconds = (double)wall_ns / 1000000000.0;
    double process_user = process_after.user - process_before.user;
    double process_system = process_after.system - process_before.system;
    double thread_user = thread_after.user - thread_before.user;
    double thread_system = thread_after.system - thread_before.system;
    double process_pct = 100.0 * (process_user + process_system) / wall_seconds;
    double thread_pct = 100.0 * (thread_user + thread_system) / wall_seconds;
    uint64_t call_p50 = percentile(calls, call_count, 0.50);
    uint64_t call_p95 = percentile(calls, call_count, 0.95);
    uint64_t call_p99 = percentile(calls, call_count, 0.99);
    uint64_t late_p50 = percentile(lateness, count, 0.50);
    uint64_t late_p95 = percentile(lateness, count, 0.95);

    fprintf(summary_file,
            "%d,%s,%d,%s,%zu,%.6f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%d,%.2f,%.2f\n",
            run_id, is_query ? "query" : "baseline", rate, flow_name(flow_mode), count, wall_seconds,
            process_user, process_system, thread_user, thread_system, process_pct, thread_pct,
            (unsigned long long)(call_count ? call_min : 0),
            (unsigned long long)call_p50,
            (unsigned long long)call_p95,
            (unsigned long long)call_p99,
            (unsigned long long)call_max,
            (unsigned long long)late_p50,
            (unsigned long long)late_p95,
            (unsigned long long)lateness_max,
            errors, load_before, load_after);
    fflush(summary_file);
    fflush(calls_file);
    free(calls);
    free(lateness);
}

static void run_sample(int run_id, int is_query, int rate, int flow_mode, uint64_t start_delay_ns)
{
    size_t count = (size_t)rate * SAMPLE_SECONDS;
    TickResult *results = calloc(count, sizeof(*results));
    if (!results) {
        fprintf(stderr, "out of memory while collecting sample\n");
        exit(2);
    }

    mach_timebase_info(&timebase);
    uint64_t period_ns = 1000000000ULL / (uint64_t)rate;
    uint64_t start = mach_absolute_time() + ns_to_ticks(start_delay_ns);
    mach_wait_until(start);
    start = mach_absolute_time();
    uint64_t wall_start = start;
    CPUTime process_before = process_cpu_time();
    CPUTime thread_before = current_thread_cpu_time();
    double load_before = one_minute_load();

    for (size_t i = 0; i < count; ++i) {
        uint64_t deadline = start + ns_to_ticks((uint64_t)(i + 1) * period_ns);
        mach_wait_until(deadline);
        uint64_t before = mach_absolute_time();
        results[i].lateness_ns = ticks_to_ns(before > deadline ? before - deadline : 0);
        results[i].selector = -1;
        results[i].status = noErr;
        if (is_query) {
            // A 10 Hz sample targets one stream's single flow. Higher rates
            // model multiple existing streams and alternate flow so both
            // default properties are represented without opening audio.
            int selector = flow_mode == 2 ? (int)(i % 2) : flow_mode;
            OSStatus status = noErr;
            results[i].selector = selector;
            query_default_device(selector, &status);
            results[i].status = status;
            results[i].call_ns = ticks_to_ns(mach_absolute_time() - before);
        }
    }

    uint64_t end = mach_absolute_time();
    CPUTime process_after = process_cpu_time();
    CPUTime thread_after = current_thread_cpu_time();
    double load_after = one_minute_load();
    write_sample(run_id, is_query, rate, flow_mode, results, count, ticks_to_ns(end - wall_start),
                 process_before, process_after, thread_before, thread_after,
                 load_before, load_after);
    fprintf(stderr, "sample %d %s %d/s complete\n", run_id, is_query ? "query" : "baseline", rate);
    free(results);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s SUMMARY.csv CALLS.csv\n", argv[0]);
        return 2;
    }
    summary_file = fopen(argv[1], "w");
    calls_file = fopen(argv[2], "w");
    if (!summary_file || !calls_file) {
        perror("open output CSV");
        return 2;
    }
    mach_timebase_info(&timebase);
    fprintf(summary_file,
            "run,mode,rate_per_sec,flow_mode,ticks,wall_seconds,process_user_s,process_system_s,thread_user_s,thread_system_s,process_cpu_pct,thread_cpu_pct,call_min_ns,call_p50_ns,call_p95_ns,call_p99_ns,call_max_ns,lateness_p50_ns,lateness_p95_ns,lateness_max_ns,status_errors,load1_before,load1_after\n");
    fprintf(calls_file, "run,mode,rate_per_sec,flow_mode,tick,flow,status,call_ns,lateness_ns\n");
    fflush(summary_file);
    fflush(calls_file);

    int run_id = 0;
    for (int rep = 0; rep < REPETITIONS; ++rep) {
        for (int flow = 0; flow < 2; ++flow) {
            ++run_id; run_sample(run_id, 0, 10, flow, 100000000ULL);
            ++run_id; run_sample(run_id, 1, 10, flow, 100000000ULL);
        }
        const int rates[RATE_COUNT - 1] = {20, 40, 80};
        for (int r = 0; r < RATE_COUNT - 1; ++r) {
            ++run_id; run_sample(run_id, 0, rates[r], 2, 100000000ULL);
            ++run_id; run_sample(run_id, 1, rates[r], 2, 100000000ULL);
        }
    }
    fclose(summary_file);
    fclose(calls_file);
    return 0;
}
