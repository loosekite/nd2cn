/*
 * nd2cn-dashd — Track Dash data daemon, native version
 *
 * Collects live vehicle data from the CMU service D-Bus and publishes it as
 * one small JSON file for app/dashboard.html:
 *
 *     /tmp/nd2cn/dashboard.json      (tmpfs; written to a temporary file and
 *                                     renamed, so a reader never sees half)
 *
 * It replaces app/dashboard-daemon.sh where it runs; the shell script stays
 * as the fallback and starts this program if it passes its self-test.
 *
 * Why native: the shell version has to launch a process for every question
 * it asks (dbus-send, smdb-read), which cost it most of a CPU core and held
 * it at 5 to 6 updates a second on the car. This program speaks the D-Bus
 * wire protocol itself over one socket: no process is launched for the
 * signals or for GPS, and a frame is forwarded the moment it is complete.
 *
 * It is READ-ONLY towards the car: it subscribes to signals and calls
 * "Get..." methods. It writes only below its run directory (/tmp/nd2cn).
 *
 * What the car sends (measured on the car, MX-5 ND2 RF, firmware 74.00.324A,
 * 2026-11-17, 13 s at idle): the vehicle bus services push their data in
 * frames, 10 a second. One frame, in this order:
 *     com.jci.vbs.bcm  CarSpeedResp(u)            every frame; 0.01 km/h per
 *                                                 bit, 0 km/h = 10000
 *     com.jci.vbs.bcm  WheelSpeedNotification((qqqqqqt))   every frame: a
 *                                                 0.1 s counter, 0, four wheel
 *                                                 speeds (as CarSpeedResp), 0
 *     com.jci.vbs.vdt  VehLong_A_Actl(q), EngAout_N_Actl(q),
 *                      Lateral_Acceleration(q)    only when the value changed
 *     com.jci.vbs.eem  CylinderDeactivation((yyy)) every frame, usually last
 * Also only on change: ApedPos_Pc_ActlArb, Veh_V_ActlEng, SteWhlComp_An_Est
 * (vdt), BrakePedalDepressedStatus, GearPosNotification,
 * TransmChangeLeverPositionNotification (bcm), and the telltales (vwm).
 * A value that only comes "on change" is unknown until it changes, so the
 * start values are asked for once (BCM Get... methods; smdb-read for the
 * three vdt ones). GPS (com.jci.lds.data GetPosition) is asked for 10 times
 * a second; coolant is only in the shared memory database (SMDB).
 *
 * The SMDB is read straight from its shared memory object, read-only (layout:
 * native/smdb-layout.md, worked out from libjcismdb.so; reader:
 * smdb_reader.h). That layout has never been seen on a car, so it has to
 * prove itself first: the firmware's own smdb-read tool is run as a child
 * process (as the shell version does, every 2 s), and only once both have
 * agreed on the coolant value twice is the tool no longer launched.
 *
 * Besides "run" there are two read-only helpers for exploring the car:
 *     nd2cn-dashd smdb [DB ...]            print every entry of the databases
 *     nd2cn-dashd smdbwatch SECONDS [DB]   sample a database 10 times a second
 *                                          and print what each entry did
 *
 * Build: see native/build.sh (static, musl, ARMv7 soft-float ABI: no
 * dependency on anything installed on the car).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <dirent.h>

#include "smdb_reader.h"

#define DASHD_VERSION "1"

/* ───────────────────────── configuration ───────────────────────── */

static struct {
    char bus[160];          /* unix socket of the service bus */
    char dir[160];          /* run directory (tmpfs) */
    char conf[200];         /* optional calibration file, KEY=VALUE lines */
    char smdb_read[200];    /* the firmware's smdb-read tool */
    char shm[160];          /* where the shared memory databases live */
    int  verbose;

    double rpm_scale, rpm_offset;
    double thr_scale, thr_offset;
    double steer_scale, steer_offset; int steer_signed;
    double latg_scale, latg_offset;   int latg_signed;
    double long_scale, long_offset;   int long_signed;
    double cool_scale, cool_offset;
    double vss_scale;
    double speed_offset, speed_div;
    char   gearbox[4];      /* "" = find out, "at", "mt" */
    int    idle_auto;       /* sleep while nobody reads the file */
    int    linger_s;        /* seconds without a reader before going idle */
    int    gps_ms;          /* period of the GPS question */
    int    cool_s;          /* period of the coolant read */
} cfg = {
    .bus = "/tmp/dbus_service_socket",
    .dir = "/tmp/nd2cn",
    .conf = "/data/nd2cn/dashboard.conf",
    .smdb_read = "/jci/smdb/smdb-read",
    .shm = "/dev/shm",
    /* Scales: see app/dashboard-daemon.sh for where each one comes from. */
    .rpm_scale = 2, .rpm_offset = 0,
    .thr_scale = 0.1, .thr_offset = 0,
    .steer_scale = 0.1, .steer_offset = -1600, .steer_signed = 0,
    .latg_scale = 0.001019716, .latg_offset = -4.078864, .latg_signed = 0,
    .long_scale = 0.001019716, .long_offset = -4.078864, .long_signed = 0,
    .cool_scale = 1, .cool_offset = -40,
    .vss_scale = 0.01,
    .speed_offset = 10000, .speed_div = 100,
    .gearbox = "",
    .idle_auto = 1, .linger_s = 30, .gps_ms = 100, .cool_s = 2,
};

static char path_out[200], path_tmp[200], path_pid[200], path_lock[200];

static void vlog(const char *fmt, ...)
{
    va_list ap;
    if (!cfg.verbose) return;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* KEY=VALUE lines as in a shell script; quotes and trailing comments are
 * dropped, anything else on the line is ignored. Unknown keys are ignored. */
static void conf_set(const char *k, const char *v)
{
    static const struct { const char *k; double *d; } nums[] = {
        { "RPM_SCALE", &cfg.rpm_scale }, { "RPM_OFFSET", &cfg.rpm_offset },
        { "THR_SCALE", &cfg.thr_scale }, { "THR_OFFSET", &cfg.thr_offset },
        { "STEER_SCALE", &cfg.steer_scale }, { "STEER_OFFSET", &cfg.steer_offset },
        { "LATG_SCALE", &cfg.latg_scale }, { "LATG_OFFSET", &cfg.latg_offset },
        { "LONG_SCALE", &cfg.long_scale }, { "LONG_OFFSET", &cfg.long_offset },
        { "COOL_SCALE", &cfg.cool_scale }, { "COOL_OFFSET", &cfg.cool_offset },
        { "VSS_SCALE", &cfg.vss_scale },
        { "SPEED_OFFSET", &cfg.speed_offset }, { "SPEED_DIV", &cfg.speed_div },
    };
    static const struct { const char *k; int *i; int lo, hi; } ints[] = {
        { "STEER_SIGNED", &cfg.steer_signed, 0, 1 }, { "LATG_SIGNED", &cfg.latg_signed, 0, 1 },
        { "LONG_SIGNED", &cfg.long_signed, 0, 1 },
        { "DASH_LINGER", &cfg.linger_s, 0, 86400 }, { "DASH_GPS_MS", &cfg.gps_ms, 50, 5000 },
        { "DASH_COOL_S", &cfg.cool_s, 1, 600 },
    };
    size_t i;
    char *end;
    for (i = 0; i < sizeof nums / sizeof nums[0]; i++) {
        if (strcmp(k, nums[i].k) == 0) {
            double d = strtod(v, &end);
            if (end != v && *end == 0 && d == d && d > -1e12 && d < 1e12) *nums[i].d = d;
            return;
        }
    }
    for (i = 0; i < sizeof ints / sizeof ints[0]; i++) {
        if (strcmp(k, ints[i].k) == 0) {
            long l = strtol(v, &end, 10);
            if (end != v && *end == 0 && l >= ints[i].lo && l <= ints[i].hi) *ints[i].i = (int)l;
            return;
        }
    }
    if (strcmp(k, "DASH_GEARBOX") == 0) {
        if (strcmp(v, "at") == 0 || strcmp(v, "mt") == 0) strcpy(cfg.gearbox, v);
        else cfg.gearbox[0] = 0;
    } else if (strcmp(k, "DASH_IDLE") == 0) {
        cfg.idle_auto = strcmp(v, "off") != 0;
    }
}

static void conf_load(const char *path)
{
    char line[256];
    FILE *f = fopen(path, "r");
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        char *p = line, *k, *v, *e;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == 0 || *p == '\n' || *p == '\r') continue;
        k = p;
        while (*p && *p != '=' && *p != ' ' && *p != '\t' && *p != '\n') p++;
        if (*p != '=') continue;
        *p++ = 0;
        if (*p == '"' || *p == '\'') {
            char q = *p++;
            v = p;
            e = strchr(v, q);
            if (!e) continue;
            *e = 0;
        } else {
            v = p;
            while (*p && *p != ' ' && *p != '\t' && *p != '#' && *p != '\n' && *p != '\r') p++;
            *p = 0;
        }
        conf_set(k, v);
    }
    fclose(f);
    if (cfg.speed_div == 0) cfg.speed_div = 100;
}

/* ───────────────────────── vehicle state ───────────────────────── */

enum {
    C_RPM, C_THR, C_STEER, C_LATG, C_LONG, C_VSS, C_SPD,
    C_BRAKE, C_GEAR, C_LEVER, C_OIL, C_BATT, C_N
};
static long raw[C_N];
static unsigned char have[C_N];
static long wheel[4];
static int have_wheels;

static struct { int have, fix; double lat, lon, hdg, spd; } gps;
static struct { int have_raw, have_val; long raw; double val; } cool;

static char gearbox[4];                 /* "", "at", "mt" */

/* kinds of signal */
enum { K_START, K_WHEELS, K_END, K_EVENT, K_SLOW, K_FAST };

static const struct sigdef {
    const char *iface, *member;
    int kind, chan;
} SIGS[] = {
    { "com.jci.vbs.bcm", "CarSpeedResp",              K_START,  C_SPD },
    { "com.jci.vbs.bcm", "WheelSpeedNotification",    K_WHEELS, -1 },
    { "com.jci.vbs.eem", "CylinderDeactivation",      K_END,    -1 },
    { "com.jci.vbs.bcm", "BrakePedalDepressedStatus", K_EVENT,  C_BRAKE },
    { "com.jci.vbs.bcm", "GearPosNotification",       K_EVENT,  C_GEAR },
    { "com.jci.vbs.bcm", "TransmChangeLeverPositionNotification", K_EVENT, C_LEVER },
    { "com.jci.vbs.vdt", "EngAout_N_Actl",            K_FAST,   C_RPM },
    { "com.jci.vbs.vdt", "ApedPos_Pc_ActlArb",        K_FAST,   C_THR },
    { "com.jci.vbs.vdt", "SteWhlComp_An_Est",         K_FAST,   C_STEER },
    { "com.jci.vbs.vdt", "Lateral_Acceleration",      K_FAST,   C_LATG },
    { "com.jci.vbs.vdt", "VehLong_A_Actl",            K_FAST,   C_LONG },
    { "com.jci.vbs.vdt", "Veh_V_ActlEng",             K_FAST,   C_VSS },
    { "com.jci.vbs.vwm", "OilPressureWarning",        K_SLOW,   C_OIL },
    { "com.jci.vbs.vwm", "OilPressureWarning_2",      K_SLOW,   C_OIL },
    { "com.jci.vbs.vwm", "BatteryChargingTelltale",   K_SLOW,   C_BATT },
    { "com.jci.vbs.vwm", "BatteryChargingTelltale2",  K_SLOW,   C_BATT },
};
#define NSIGS ((int)(sizeof SIGS / sizeof SIGS[0]))

/* Which gearbox is this? GearPos is the manual gearbox position (the
 * firmware calls it GearPosMt). The lever is the selector of an automatic,
 * but it reads 1 ("P") on a manual car as well: that is the value
 * libjcimod_bcm.so starts with.
 *     lever 2..6           -> automatic (a manual never gets there)
 *     a gear, lever 0 or 1 -> manual
 * Until then the answer is open ("gearbox":null) and the page decides by
 * the same rule for itself: lever 2..6 reads as an automatic, anything else
 * as a manual (gearText() in dashboard.html). */
static void detect_gearbox(void)
{
    long g = have[C_GEAR] ? raw[C_GEAR] : -1, l = have[C_LEVER] ? raw[C_LEVER] : -1;
    if (cfg.gearbox[0]) { strcpy(gearbox, cfg.gearbox); return; }
    if (l >= 2 && l <= 6) strcpy(gearbox, "at");
    else if ((l == 0 || l == 1) && !gearbox[0] && ((g >= 1 && g <= 8) || g == 14)) strcpy(gearbox, "mt");
}

/* ───────────────────────── publishing ───────────────────────── */

static uint32_t seq;
static int pub_count, pub_hz;           /* publishes in the running / last second */
static uint32_t nsig;                   /* signals received (calibration panel) */
static int frame_dirty;                 /* frame data newer than the file. What changes
                                           slowly (GPS, coolant, telltales, start values)
                                           does not set it: it rides along with the next
                                           frame, 0.1 s later at most */
static int64_t deadline;                /* 0, or when a dirty frame goes out at the latest */
static int64_t last_pub;

static int atime_ok;                    /* reads of the file can be seen */
static int active = 1;
static int64_t last_reader;             /* when the page last read the file */

#define ATIME_MARK 1                    /* "not read yet": 1970-01-01 00:00:01.
                                           Older than any modification time, so
                                           the kernel updates it on the first
                                           read even with relatime, and even
                                           while the CMU clock still says 1970 */

struct jbuf { char s[1400]; size_t n; };

static void jput(struct jbuf *j, const char *fmt, ...)
{
    va_list ap;
    int r;
    if (j->n >= sizeof j->s - 1) return;
    va_start(ap, fmt);
    r = vsnprintf(j->s + j->n, sizeof j->s - j->n, fmt, ap);
    va_end(ap);
    if (r > 0) j->n += (size_t)r < sizeof j->s - j->n ? (size_t)r : sizeof j->s - j->n - 1;
}

/* raw * scale + offset, or null. lim: the largest raw value the firmware
 * itself accepts for an unsigned channel (0 = none). */
static void jconv(struct jbuf *j, int c, double scale, double offset, int sgn, int prec, long lim)
{
    double v;
    if (!have[c]) { jput(j, "null"); return; }
    v = (double)raw[c];
    if (v < 0) { jput(j, "null"); return; }
    if (sgn) { if (v > 32767) v -= 65536; }
    else if (lim > 0 && v > lim) { jput(j, "null"); return; }
    jput(j, "%.*f", prec, v * scale + offset);
}

static void jraw(struct jbuf *j, int c)
{
    if (have[c]) jput(j, "%ld", raw[c]); else jput(j, "null");
}

static void jflag(struct jbuf *j, int c)
{
    if (have[c]) jput(j, "%d", raw[c] != 0); else jput(j, "null");
}

/* BCM speed and wheel speeds: raw 10000 = 0 km/h */
static void jkmh(struct jbuf *j, long v)
{
    double k;
    if (v < 0 || v >= 65535) { jput(j, "null"); return; }
    k = ((double)v - cfg.speed_offset) / cfg.speed_div;
    jput(j, "%.2f", k < 0 ? 0.0 : k);
}

/* Was the file that is about to be replaced read by anyone? */
static int check_reader(int64_t now)
{
    struct stat st;
    if (!atime_ok) return 0;
    if (stat(path_out, &st) != 0 || st.st_atime == ATIME_MARK) return 0;
    last_reader = now;
    return 1;
}

static int write_file(const char *text, size_t len)
{
    struct timespec ts[2];
    int fd = open(path_tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    if (write(fd, text, len) != (ssize_t)len) { close(fd); return -1; }
    ts[0].tv_sec = ATIME_MARK; ts[0].tv_nsec = 0;
    ts[1].tv_sec = 0;          ts[1].tv_nsec = UTIME_OMIT;
    futimens(fd, ts);
    close(fd);
    return rename(path_tmp, path_out);
}

static const char *smdb_source(void);

static void publish(int64_t now)
{
    struct jbuf j;
    int i;
    j.n = 0;
    seq++; pub_count++;
    frame_dirty = 0; deadline = 0; last_pub = now;

    jput(&j, "{\"speed\":");
    /* The engine-side speed (Veh_V_ActlEng) is what the dashboard has always
     * shown; it only arrives when it changes, so until then the BCM speed
     * (in every frame) fills in. */
    if (have[C_VSS]) jput(&j, "%.2f", (double)raw[C_VSS] * cfg.vss_scale);
    else if (have[C_SPD]) jkmh(&j, raw[C_SPD]);
    else jput(&j, "null");
    jput(&j, ",\"rpm\":");      jconv(&j, C_RPM, cfg.rpm_scale, cfg.rpm_offset, 0, 0, 0);
    jput(&j, ",\"gear\":");     jraw(&j, C_GEAR);
    jput(&j, ",\"lever\":");    jraw(&j, C_LEVER);
    if (gearbox[0]) jput(&j, ",\"gearbox\":\"%s\"", gearbox); else jput(&j, ",\"gearbox\":null");
    jput(&j, ",\"throttle\":"); jconv(&j, C_THR, cfg.thr_scale, cfg.thr_offset, 0, 1, 0);
    jput(&j, ",\"brake\":");    jraw(&j, C_BRAKE);
    jput(&j, ",\"steering\":");
    /* 32766 (0x7FFE) is what the firmware holds before the first CAN frame,
     * 32767 the invalid marker */
    if (have[C_STEER] && (raw[C_STEER] == 32766 || raw[C_STEER] == 32767)) jput(&j, "null");
    else jconv(&j, C_STEER, cfg.steer_scale, cfg.steer_offset, cfg.steer_signed, 1, 32765);
    jput(&j, ",\"lat_g\":");    jconv(&j, C_LATG, cfg.latg_scale, cfg.latg_offset, cfg.latg_signed, 3, 8191);
    jput(&j, ",\"lon_g\":");    jconv(&j, C_LONG, cfg.long_scale, cfg.long_offset, cfg.long_signed, 3, 8191);
    if (cool.have_val) jput(&j, ",\"coolant\":%.0f", cool.val); else jput(&j, ",\"coolant\":null");
    jput(&j, ",\"ambient\":null,\"oil_warn\":"); jflag(&j, C_OIL);
    jput(&j, ",\"batt_warn\":"); jflag(&j, C_BATT);
    jput(&j, ",\"wheels\":");
    if (have_wheels) {
        for (i = 0; i < 4; i++) { jput(&j, i ? "," : "["); jkmh(&j, wheel[i]); }
        jput(&j, "]");
    } else {
        jput(&j, "null");
    }
    if (gps.have && gps.fix != 0)
        jput(&j, ",\"gps_lat\":%.7f,\"gps_lon\":%.7f,\"gps_heading\":%.1f,\"gps_speed\":%.2f,\"gps_fix\":%d",
             gps.lat, gps.lon, gps.hdg, gps.spd, gps.fix);
    else if (gps.have)
        jput(&j, ",\"gps_lat\":null,\"gps_lon\":null,\"gps_heading\":null,\"gps_speed\":null,\"gps_fix\":0");
    else
        jput(&j, ",\"gps_lat\":null,\"gps_lon\":null,\"gps_heading\":null,\"gps_speed\":null,\"gps_fix\":null");
    /* "t": when this sample was made, in milliseconds on a clock that never
     * jumps. The page places the sample in time by it; the moment its poll
     * happens to read the file is up to one poll period late, and uneven. */
    jput(&j, ",\"ts\":%ld,\"t\":%lld,\"seq\":%u,\"hz\":%d,\"sig\":%u,\"src\":\"native\",\"smdb\":\"%s\",\"raw\":{\"rpm\":",
         (long)time(NULL), (long long)now, (unsigned)seq, pub_hz, (unsigned)nsig, smdb_source());
    jraw(&j, C_RPM);
    jput(&j, ",\"thr\":");   jraw(&j, C_THR);
    jput(&j, ",\"steer\":"); jraw(&j, C_STEER);
    jput(&j, ",\"latg\":");  jraw(&j, C_LATG);
    jput(&j, ",\"lon\":");   jraw(&j, C_LONG);
    if (cool.have_raw) jput(&j, ",\"cool\":%ld", cool.raw); else jput(&j, ",\"cool\":null");
    jput(&j, ",\"vss\":");   jraw(&j, C_VSS);
    jput(&j, ",\"spd\":");   jraw(&j, C_SPD);
    jput(&j, ",\"gear\":");  jraw(&j, C_GEAR);
    jput(&j, ",\"lever\":"); jraw(&j, C_LEVER);
    jput(&j, "}}\n");

    check_reader(now);
    write_file(j.s, j.n);
}

/* The heartbeat while nobody is looking. Returns 1 if the previous one was read. */
static int publish_idle(int64_t now)
{
    char s[96];
    int n, was_read;
    seq++;
    n = snprintf(s, sizeof s, "{\"idle\":true,\"ts\":%ld,\"seq\":%u,\"src\":\"native\"}\n",
                 (long)time(NULL), (unsigned)seq);
    was_read = check_reader(now);
    write_file(s, (size_t)n);
    last_pub = now;
    return was_read;
}

/* ───────────────────────── D-Bus, just enough of it ───────────────────────── */

#define ALIGN(n, a) (((n) + ((a) - 1)) & ~((size_t)(a) - 1))
#define RX_CAP 65536

static int bus_fd = -1;
static uint32_t bus_serial;
static uint8_t rx[RX_CAP];
static size_t rx_len;
static size_t rx_skip;                  /* bytes of an oversized message still to drop */

static uint32_t ser_gps, ser_seed[3];   /* serials of the questions that are out */
static int64_t gps_asked;

static void bus_close(void)
{
    if (bus_fd >= 0) close(bus_fd);
    bus_fd = -1;
    rx_len = 0; rx_skip = 0;
    ser_gps = 0; ser_seed[0] = ser_seed[1] = ser_seed[2] = 0;
    /* what was known is no longer true: show nothing rather than frozen values */
    memset(have, 0, sizeof have);
    have_wheels = 0;
    gps.have = 0;
}

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    int tries = 0;
    while (len > 0) {
        ssize_t r = send(fd, p, len, MSG_NOSIGNAL);
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN && tries++ < 50) {
                struct pollfd pf = { fd, POLLOUT, 0 };
                poll(&pf, 1, 20);
                continue;
            }
            return -1;
        }
        p += r; len -= (size_t)r;
    }
    return 0;
}

/* One line of the authentication dialogue (it ends with \r\n). Read byte by
 * byte: nothing of the binary stream that follows may be swallowed. */
static int auth_line(char *out, size_t cap)
{
    size_t n = 0;
    int64_t until = now_ms() + 2000;
    for (;;) {
        struct pollfd pf = { bus_fd, POLLIN, 0 };
        int64_t left = until - now_ms();
        char c;
        ssize_t r;
        if (left <= 0 || poll(&pf, 1, (int)left) <= 0) return -1;
        r = recv(bus_fd, &c, 1, 0);
        if (r <= 0) return -1;
        if (c == '\n') break;
        if (c != '\r' && n < cap - 1) out[n++] = c;
    }
    out[n] = 0;
    return 0;
}

static int bus_auth(void)
{
    char line[256], cmd[96], uid[16], hex[40];
    size_t i;
    snprintf(uid, sizeof uid, "%u", (unsigned)getuid());
    for (i = 0; uid[i]; i++) snprintf(hex + 2 * i, 3, "%02x", (unsigned char)uid[i]);
    if (write_all(bus_fd, "\0", 1) < 0) return -1;
    snprintf(cmd, sizeof cmd, "AUTH EXTERNAL %s\r\n", hex);
    if (write_all(bus_fd, cmd, strlen(cmd)) < 0 || auth_line(line, sizeof line) < 0) return -1;
    if (strncmp(line, "OK", 2) != 0) {
        /* the service bus allows anonymous clients (allow_anonymous in
         * /etc/dbus-1/service.conf); the trace is "nd2cn" in hex */
        vlog("auth: EXTERNAL refused (%s), trying ANONYMOUS", line);
        if (write_all(bus_fd, "AUTH ANONYMOUS 6e6432636e\r\n", 27) < 0 || auth_line(line, sizeof line) < 0) return -1;
        if (strncmp(line, "OK", 2) != 0) return -1;
    }
    return write_all(bus_fd, "BEGIN\r\n", 7);
}

/* message building */
struct wbuf { uint8_t b[1024]; size_t n; };

static void w_pad(struct wbuf *w, size_t a) { while (w->n % a) w->b[w->n++] = 0; }
static void w_u32(struct wbuf *w, uint32_t v) { w_pad(w, 4); memcpy(w->b + w->n, &v, 4); w->n += 4; }
static void w_str(struct wbuf *w, const char *s)
{
    size_t l = strlen(s);
    w_u32(w, (uint32_t)l);
    memcpy(w->b + w->n, s, l + 1);
    w->n += l + 1;
}
static void w_field(struct wbuf *w, uint8_t code, char type, const char *s)
{
    w_pad(w, 8);
    w->b[w->n++] = code; w->b[w->n++] = 1; w->b[w->n++] = (uint8_t)type; w->b[w->n++] = 0;
    if (type == 'g') {
        size_t l = strlen(s);
        w->b[w->n++] = (uint8_t)l;
        memcpy(w->b + w->n, s, l + 1);
        w->n += l + 1;
    } else {
        w_str(w, s);
    }
}

/* A method call with no arguments, or with one string argument. Returns the
 * serial (0 on failure). Host byte order: the bus accepts either. */
static uint32_t bus_call(const char *dest, const char *path, const char *iface,
                         const char *member, const char *arg)
{
    struct wbuf w;
    uint32_t serial, flen, blen = 0;
    const uint16_t one = 1;
    size_t fields_at;
    if (bus_fd < 0) return 0;
    if (strlen(dest) + strlen(path) + strlen(iface) + strlen(member) + (arg ? strlen(arg) : 0) > 800) return 0;
    serial = ++bus_serial;
    if (serial == 0) serial = ++bus_serial;
    w.n = 0;
    w.b[w.n++] = *(const uint8_t *)&one ? 'l' : 'B';
    w.b[w.n++] = 1;                     /* METHOD_CALL */
    w.b[w.n++] = 0;
    w.b[w.n++] = 1;                     /* protocol version */
    w_u32(&w, 0);                       /* body length, filled in below */
    w_u32(&w, serial);
    w_u32(&w, 0);                       /* length of the header fields */
    fields_at = w.n;
    w_field(&w, 1, 'o', path);
    w_field(&w, 6, 's', dest);
    w_field(&w, 2, 's', iface);
    w_field(&w, 3, 's', member);
    if (arg) w_field(&w, 8, 'g', "s");
    flen = (uint32_t)(w.n - fields_at);
    memcpy(w.b + 12, &flen, 4);
    w_pad(&w, 8);
    if (arg) {
        size_t at = w.n;
        w_str(&w, arg);
        blen = (uint32_t)(w.n - at);
    }
    memcpy(w.b + 4, &blen, 4);
    if (write_all(bus_fd, w.b, w.n) < 0) { vlog("bus: write failed"); bus_close(); return 0; }
    return serial;
}

/* message parsing */
struct msg {
    int type, swap;                     /* 1 call, 2 return, 3 error, 4 signal */
    uint32_t reply_serial;
    const char *iface, *member, *sig, *errname;
    const uint8_t *body;
    size_t body_len;
};

static uint16_t rd16(const uint8_t *p, int swap)
{
    uint16_t v; memcpy(&v, p, 2);
    return (uint16_t)(swap ? ((v >> 8) | (v << 8)) : v);
}
static uint32_t rd32(const uint8_t *p, int swap)
{
    uint32_t v; memcpy(&v, p, 4);
    return swap ? __builtin_bswap32(v) : v;
}
static uint64_t rd64(const uint8_t *p, int swap)
{
    uint64_t v; memcpy(&v, p, 8);
    return swap ? __builtin_bswap64(v) : v;
}

/* Total length of the message at m, 0 if the fixed header is not complete,
 * -1 if this is not a D-Bus message. */
static long msg_total(const uint8_t *m, size_t avail)
{
    const uint16_t one = 1;
    int host_le = *(const uint8_t *)&one, swap;
    uint32_t blen, flen;
    if (avail < 16) return 0;
    if (m[0] != 'l' && m[0] != 'B') return -1;
    swap = (m[0] == 'l') != host_le;
    blen = rd32(m + 4, swap); flen = rd32(m + 12, swap);
    if (flen > (1u << 20) || blen > (1u << 27)) return -1;
    return (long)(16 + ALIGN(flen, 8) + blen);
}

static int msg_parse(const uint8_t *m, size_t total, struct msg *o)
{
    const uint16_t one = 1;
    int host_le = *(const uint8_t *)&one;
    size_t pos = 16, end;
    uint32_t flen;
    memset(o, 0, sizeof *o);
    o->swap = (m[0] == 'l') != host_le;
    o->type = m[1];
    flen = rd32(m + 12, o->swap);
    end = 16 + flen;
    if (end > total) return -1;
    o->body = m + ALIGN(end, 8);
    o->body_len = rd32(m + 4, o->swap);
    if (ALIGN(end, 8) + o->body_len > total) return -1;
    while (pos < end) {
        uint8_t code, slen;
        char t;
        pos = ALIGN(pos, 8);
        if (pos + 4 > end) break;
        code = m[pos]; slen = m[pos + 1];
        if (slen != 1 || m[pos + 3] != 0) return -1;      /* every header field is a basic type */
        t = (char)m[pos + 2];
        pos += 4;
        if (t == 's' || t == 'o') {
            uint32_t l;
            if (pos + 4 > end) return -1;
            l = rd32(m + pos, o->swap);
            if (l > end || pos + 4 + l + 1 > end || m[pos + 4 + l] != 0) return -1;
            if (code == 2) o->iface = (const char *)m + pos + 4;
            else if (code == 3) o->member = (const char *)m + pos + 4;
            else if (code == 4) o->errname = (const char *)m + pos + 4;
            pos += 4 + l + 1;
        } else if (t == 'g') {
            uint8_t l;
            if (pos + 1 > end) return -1;
            l = m[pos];
            if (pos + 1 + l + 1 > end || m[pos + 1 + l] != 0) return -1;
            if (code == 8) o->sig = (const char *)m + pos + 1;
            pos += 1 + (size_t)l + 1;
        } else if (t == 'u') {
            if (pos + 4 > end) return -1;
            if (code == 5) o->reply_serial = rd32(m + pos, o->swap);
            pos += 4;
        } else {
            return -1;
        }
    }
    return 0;
}

static size_t type_align(char t)
{
    switch (t) {
    case 'y': case 'g': case 'v': return 1;
    case 'n': case 'q': return 2;
    case 'x': case 't': case 'd': case '(': case '{': return 8;
    default: return 4;
    }
}

/* Length of the single complete type that starts at s (0 if malformed). */
static size_t sig_one(const char *s)
{
    if (*s == 'a') { size_t n = sig_one(s + 1); return n ? n + 1 : 0; }
    if (*s == '(' || *s == '{') {
        char close_c = *s == '(' ? ')' : '}';
        size_t n = 1;
        while (s[n] && s[n] != close_c) {
            size_t k = sig_one(s + n);
            if (!k) return 0;
            n += k;
        }
        return s[n] ? n + 1 : 0;
    }
    return (*s && *s != ')' && *s != '}') ? 1 : 0;
}

/* The numbers in a message body, in order, structs flattened. Strings and
 * arrays are stepped over. Returns how many were found. */
static int body_values(const struct msg *m, double *vals, int max)
{
    const char *s = m->sig ? m->sig : "";
    const uint8_t *b = m->body;
    size_t p = 0, len = m->body_len;
    int n = 0;
    while (*s && n < max) {
        char t = *s++;
        size_t a = type_align(t);
        if (t == ')' || t == '}') continue;
        p = ALIGN(p, a);
        if (t == '(' || t == '{') continue;
        switch (t) {
        case 'y': if (p + 1 > len) return n; vals[n++] = b[p]; p += 1; break;
        case 'n': if (p + 2 > len) return n; vals[n++] = (int16_t)rd16(b + p, m->swap); p += 2; break;
        case 'q': if (p + 2 > len) return n; vals[n++] = rd16(b + p, m->swap); p += 2; break;
        case 'i': if (p + 4 > len) return n; vals[n++] = (int32_t)rd32(b + p, m->swap); p += 4; break;
        case 'b':
        case 'u': if (p + 4 > len) return n; vals[n++] = rd32(b + p, m->swap); p += 4; break;
        case 'x': if (p + 8 > len) return n; vals[n++] = (double)(int64_t)rd64(b + p, m->swap); p += 8; break;
        case 't': if (p + 8 > len) return n; vals[n++] = (double)rd64(b + p, m->swap); p += 8; break;
        case 'd': {
            uint64_t u; double d;
            if (p + 8 > len) return n;
            u = rd64(b + p, m->swap); memcpy(&d, &u, 8);
            vals[n++] = d; p += 8; break;
        }
        case 's': case 'o': {
            uint32_t l;
            if (p + 4 > len) return n;
            l = rd32(b + p, m->swap);
            if (l >= len - p - 4) return n;              /* the text and its NUL must fit */
            p += 4 + (size_t)l + 1; break;
        }
        case 'g':
            if (p + 1 > len || (size_t)b[p] + 2 > len - p) return n;
            p += 1 + (size_t)b[p] + 1; break;
        case 'a': {
            uint32_t l; size_t k = sig_one(s);
            if (!k || p + 4 > len) return n;
            l = rd32(b + p, m->swap);
            p = ALIGN(p + 4, type_align(*s));
            if (p > len || l > len - p) return n;
            p += l;
            s += k; break;
        }
        default: return n;              /* variant or unknown: stop */
        }
    }
    return n;
}

static int bus_connect(void)
{
    struct sockaddr_un sa;
    char rule[160];
    int i, fl;
    bus_close();
    bus_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (bus_fd < 0) return -1;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strncpy(sa.sun_path, cfg.bus, sizeof sa.sun_path - 1);
    if (connect(bus_fd, (struct sockaddr *)&sa, sizeof sa) < 0 || bus_auth() < 0) {
        vlog("bus: cannot connect to %s (%s)", cfg.bus, strerror(errno));
        bus_close();
        return -1;
    }
    fl = fcntl(bus_fd, F_GETFL);
    fcntl(bus_fd, F_SETFL, fl | O_NONBLOCK);
    if (!bus_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", NULL)) return -1;
    for (i = 0; i < NSIGS; i++) {
        snprintf(rule, sizeof rule, "type='signal',interface='%s',member='%s'", SIGS[i].iface, SIGS[i].member);
        if (!bus_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", rule)) return -1;
    }
    vlog("bus: connected, %d match rules", NSIGS);
    return 0;
}

static const char BCM[] = "com.jci.vbs.bcm", BCM_PATH[] = "/com/jci/vbs/bcm";

static void ask_gps(int64_t now)
{
    /* one question at a time; a lost answer is given up after half a second */
    if (ser_gps && now - gps_asked < 500) return;
    ser_gps = bus_call("com.jci.lds.data", "/com/jci/lds/data", "com.jci.lds.data", "GetPosition", NULL);
    gps_asked = now;
}

static void ask_seeds(void)
{
    ser_seed[0] = bus_call(BCM, BCM_PATH, BCM, "GetBrkPedalDepressedStatus", NULL);
    ser_seed[1] = bus_call(BCM, BCM_PATH, BCM, "GetGearPos", NULL);
    ser_seed[2] = bus_call(BCM, BCM_PATH, BCM, "GetTransmChangeLeverPosition", NULL);
}

static void set_chan(int c, long v) { raw[c] = v; have[c] = 1; }

/* A number from the bus as a raw channel value. Everything this program
 * listens to is an unsigned 8, 16 or 32 bit quantity far below a million;
 * anything else (NaN, a negative, a huge value) is not a reading. */
static int raw_ok(double d, long *out)
{
    if (!(d >= 0 && d <= 1000000)) return 0;
    *out = (long)d;
    return 1;
}

static void mark_dirty(int64_t now)
{
    frame_dirty = 1;
    /* Frames have an end marker, but if it does not come, what is here goes
     * out 25 ms after it started to arrive. */
    if (!deadline) deadline = now + 25;
}

static void on_signal(const struct msg *m, int64_t now)
{
    double v[8];
    long x;
    int i, n;
    const struct sigdef *d = NULL;
    if (!m->iface || !m->member) return;
    for (i = 0; i < NSIGS; i++) {
        if (strcmp(m->member, SIGS[i].member) == 0 && strcmp(m->iface, SIGS[i].iface) == 0) { d = &SIGS[i]; break; }
    }
    if (!d) return;
    n = body_values(m, v, 8);
    nsig++;
    switch (d->kind) {
    case K_START:
        /* A frame that never gets its end marker goes out on the deadline
         * set by mark_dirty(); nothing is flushed here, because on the car a
         * value of the new frame sometimes arrives just before this one. */
        if (n < 1 || !raw_ok(v[0], &x)) return;
        set_chan(d->chan, x);
        mark_dirty(now);
        break;
    case K_WHEELS: {
        long w[4];
        if (n < 6) return;
        /* id, len, front left, front right, rear left, rear right, timestamp */
        for (i = 0; i < 4; i++) if (!raw_ok(v[2 + i], &w[i])) return;
        for (i = 0; i < 4; i++) wheel[i] = w[i];
        have_wheels = 1;
        mark_dirty(now);
        break;
    }
    case K_END:
        /* The frame is complete, except that on the car one frame in seven
         * had a value arrive just after this marker: wait 6 ms for it, so
         * that a frame is one file and not two. */
        if (frame_dirty) deadline = now + 6;
        break;
    case K_EVENT:                                        /* rare, and worth every millisecond */
        if (n < 1 || !raw_ok(v[0], &x)) return;
        set_chan(d->chan, x);
        detect_gearbox();
        if (active) publish(now);
        break;
    case K_SLOW:
        if (n < 1) return;
        set_chan(d->chan, v[0] != 0);                    /* goes out with the next frame */
        break;
    default:
        if (n < 1 || !raw_ok(v[0], &x)) return;
        set_chan(d->chan, x);
        mark_dirty(now);
        break;
    }
}

static void on_reply(const struct msg *m)
{
    static const int seed_chan[3] = { C_BRAKE, C_GEAR, C_LEVER };
    double v[12];
    int i, n;
    if (!m->reply_serial) return;
    if (m->reply_serial == ser_gps) {
        ser_gps = 0;
        if (m->type != 2) return;
        /* accuracy(i) utc(t) lat(d) lon(d) alt(i) heading(d) velocity(d) ... */
        n = body_values(m, v, 12);
        if (n < 7 || !m->sig || strncmp(m->sig, "itddidd", 7) != 0) return;
        gps.have = 1;
        gps.fix = (v[0] >= 0 && v[0] <= 100) ? (int)v[0] : 0;
        gps.lat = v[2]; gps.lon = v[3]; gps.hdg = v[5]; gps.spd = v[6];
        if (!(gps.lat == gps.lat) || !(gps.lon == gps.lon) || !(gps.hdg == gps.hdg) || !(gps.spd == gps.spd) ||
            gps.lat < -90 || gps.lat > 90 || gps.lon < -180 || gps.lon > 180 ||
            gps.hdg < -1e6 || gps.hdg > 1e6 || gps.spd < -1e6 || gps.spd > 1e6) gps.fix = 0;
        return;
    }
    for (i = 0; i < 3; i++) {
        if (m->reply_serial != ser_seed[i]) continue;
        ser_seed[i] = 0;
        if (m->type != 2) return;
        n = body_values(m, v, 2);
        /* a start value; the signal itself wins if it was faster */
        if (n >= 1 && !have[seed_chan[i]] && v[0] >= 0 && v[0] <= 255) { set_chan(seed_chan[i], (long)v[0]); detect_gearbox(); }
        return;
    }
    if (m->type == 3) vlog("bus: error reply %s", m->errname ? m->errname : "?");
}

/* Read what the socket has and handle every complete message. -1: lost. */
static int bus_read(int64_t now)
{
    for (;;) {
        ssize_t r;
        size_t off = 0;
        if (rx_skip) {
            uint8_t junk[4096];
            r = recv(bus_fd, junk, rx_skip < sizeof junk ? rx_skip : sizeof junk, 0);
            if (r > 0) { rx_skip -= (size_t)r; continue; }
        } else {
            r = recv(bus_fd, rx + rx_len, RX_CAP - rx_len, 0);
            if (r > 0) rx_len += (size_t)r;
        }
        if (r == 0) return -1;
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            return -1;
        }
        while (rx_len - off >= 16) {
            long total = msg_total(rx + off, rx_len - off);
            struct msg m;
            if (total < 0) return -1;
            if ((size_t)total > RX_CAP) {               /* nothing we asked for is this big */
                rx_skip = (size_t)total - (rx_len - off);
                off = rx_len;
                break;
            }
            if ((size_t)total > rx_len - off) break;
            if (msg_parse(rx + off, (size_t)total, &m) == 0) {
                if (m.type == 4) on_signal(&m, now);
                else if (m.type == 2 || m.type == 3) on_reply(&m);
            }
            off += (size_t)total;
        }
        if (off) { memmove(rx, rx + off, rx_len - off); rx_len -= off; }
    }
}

/* ───────────────────────── shared memory database, via smdb-read ───────────────────────── */

/* What is read from the database: coolant (it is nowhere else), and the
 * start values of three channels that D-Bus only sends on change. */
enum { Q_COOL, Q_RPM, Q_THR, Q_STEER, Q_N };
static const char *const Q_KEY[Q_N] = { "EngClnt_Te_Actl", "EngineSpeed", "AccelPedalPosition", "SteeringWheel" };
static unsigned char q_want[Q_N];

#define SMDB_DB "vdm_vdt_current_data"
static struct smdb_ro sdb;
static int sdb_open;                    /* the object is mapped and looks like a database */
static int sdb_trust;                   /* 0 not compared yet, 1 agrees with smdb-read, -1 does not */
static int sdb_idx[Q_N], sdb_agree, sdb_differ;
static int64_t sdb_next_try;

/* Where do the databases live? glibc's shm_open() uses /dev/shm if that is a
 * tmpfs and otherwise the first tmpfs it finds in /proc/mounts, so look
 * there too. Sets cfg.shm to the directory that holds DB; returns 1 if it
 * was found. A directory given with DASH_SHM_DIR is taken as it is. */
static int shm_fixed;
/* The object counts once it has a size: its owner creates it empty and
 * fills it afterwards. */
static int has_data(const char *p)
{
    struct stat st;
    return stat(p, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
}
static int shm_locate(const char *db)
{
    char p[300], line[512], mnt[160], type[32];
    FILE *f;
    int found = 0, cut = 0, whole;
    snprintf(p, sizeof p, "%s/smdb_%s", cfg.shm, db);
    if (has_data(p)) return 1;
    if (shm_fixed) return 0;
    f = fopen("/proc/mounts", "r");
    if (!f) return 0;
    while (!found && fgets(line, sizeof line, f)) {
        /* a line too long for the buffer is skipped as a whole, head and rest */
        whole = !cut;
        cut = strchr(line, '\n') == NULL && !feof(f);
        if (!whole || cut) continue;
        if (sscanf(line, "%*s %159s %31s", mnt, type) != 2) continue;
        if (strcmp(type, "tmpfs") != 0 && strcmp(type, "shm") != 0) continue;
        snprintf(p, sizeof p, "%s/smdb_%s", mnt, db);
        if (has_data(p)) { snprintf(cfg.shm, sizeof cfg.shm, "%s", mnt); found = 1; }
    }
    fclose(f);
    return found;
}

static void sdb_try_open(int64_t now)
{
    char p[256];
    int i;
    if (sdb_open || sdb_trust < 0 || now < sdb_next_try) return;
    sdb_next_try = now + 5000;          /* not there yet (early boot): try again later */
    if (!shm_locate(SMDB_DB)) return;
    snprintf(p, sizeof p, "%s/smdb_%s", cfg.shm, SMDB_DB);
    /* An object that is still being filled by its owner fails here (empty,
     * no entries yet, entries still zero) and is simply tried again. */
    if (smdb_ro_open_path(p, &sdb) != SMDB_RO_OK) return;
    for (i = 0; i < Q_N; i++) sdb_idx[i] = smdb_ro_find(&sdb, Q_KEY[i]);
    if (sdb_idx[Q_COOL] < 0) {          /* complete, but not the layout this program knows */
        smdb_ro_close(&sdb);
        sdb_trust = -1;
        vlog("smdb: %s has no %s entry, using smdb-read", p, Q_KEY[Q_COOL]);
        return;
    }
    sdb_open = 1;
    /* without the tool there is nothing to compare with, and nothing else to use */
    if (access(cfg.smdb_read, X_OK) != 0) sdb_trust = 1;
    vlog("smdb: mapped %s (%u bytes, %u entries)%s", p, (unsigned)sdb.total, (unsigned)sdb.count,
         sdb_trust > 0 ? ", no smdb-read to compare with" : "");
}

static int sdb_get(int q, long *v)
{
    return sdb_open && sdb_idx[q] >= 0 && smdb_ro_read_int(&sdb, sdb_idx[q], v) == SMDB_RO_OK;
}

/* The tool said entry Q is V. Does the mapped database say the same?
 * Only coolant is compared: it is the one value that cannot have changed by
 * more than one step while the tool was running (0.4 s during boot). Engine
 * speed, throttle and steering move under the driver's hands, so a
 * difference there would say nothing. A zero proves nothing either: it is
 * what an empty database holds. Trusted after two agreements, given up
 * after two disagreements. */
static void sdb_compare(int q, long v)
{
    long mine;
    if (!sdb_open || sdb_trust != 0 || q != Q_COOL || v <= 0) return;
    if (sdb_get(q, &mine) && mine >= 0 && mine - v <= 1 && v - mine <= 1) {
        if (++sdb_agree >= 2) {
            sdb_trust = 1;
            vlog("smdb: direct reads agree with smdb-read, the tool is no longer launched");
        }
    } else if (++sdb_differ >= 2) {
        sdb_trust = -1;
        sdb_open = 0;
        smdb_ro_close(&sdb);
        vlog("smdb: direct reads differ from smdb-read, staying with the tool");
    }
}

/* Entry Q of the database is V (negative: could not be read). */
static void smdb_apply(int q, long v)
{
    switch (q) {
    case Q_COOL:
        cool.have_raw = v >= 0; cool.have_val = 0;
        if (v >= 0) cool.raw = v;
        /* 0 is the database default (nothing received yet), 255 "invalid" on the bus */
        if (v > 0 && v < 255) { cool.val = (double)v * cfg.cool_scale + cfg.cool_offset; cool.have_val = 1; }
        break;
    /* start values; the signal itself wins if it was faster */
    case Q_RPM:   if (v >= 0 && !have[C_RPM])   set_chan(C_RPM, v);   break;
    case Q_THR:   if (v >= 0 && !have[C_THR])   set_chan(C_THR, v);   break;
    case Q_STEER: if (v >= 0 && !have[C_STEER]) set_chan(C_STEER, v); break;
    }
}

/* Ask for entry Q: at once from the mapping if that is trusted, else by
 * queueing a run of the tool. */
static void smdb_want(int q)
{
    long v;
    if (sdb_trust > 0 && sdb_get(q, &v)) smdb_apply(q, v < 0 || v > 999999 ? -1 : v);
    else q_want[q] = 1;
}

static const char *smdb_source(void) { return sdb_trust > 0 ? "direct" : "tool"; }

/* The tool: one read is a process launch that loads five libraries (0.4 s
 * was measured during boot). The child runs beside the main loop; its output
 * is collected when it is there. One at a time, the rest wait in a queue. */
static struct { pid_t pid; int fd, what; size_t len; char buf[512]; int64_t started; } child = { 0, -1, 0, 0, "", 0 };

/* smdb-read creates the database if it does not exist yet (the vendor
 * library opens it with O_CREAT), and it would do so as root, while the
 * services that own it run as another user: launched too early it could
 * lock them out of their own database. So it only runs once the object is
 * there and has data. The owner makes the semaphore last, after filling the
 * object, so in the first half minute after boot the semaphore must be
 * there too (glibc keeps it next to the object, as "sem.smdb_<name>"; that
 * name is inferred, hence only then). Should the object not be anywhere
 * this program looks, the tool is allowed after two minutes of uptime, by
 * which time the services have long created it wherever it lives. */
static int tool_safe(int64_t now)
{
    char p[300];
    if (shm_locate(SMDB_DB)) {
        if (now >= 30000) return 1;         /* CLOCK_MONOTONIC: time since boot */
        snprintf(p, sizeof p, "%s/sem.smdb_%s", cfg.shm, SMDB_DB);
        return access(p, F_OK) == 0;
    }
    return now >= 120000;
}

static void child_start(int what, int64_t now)
{
    int p[2];
    pid_t pid;
    if (access(cfg.smdb_read, X_OK) != 0 || !tool_safe(now)) return;
    if (pipe(p) < 0) return;
    pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return; }
    if (pid == 0) {
        const char *old = getenv("LD_LIBRARY_PATH");
        char env[512];
        int nul = open("/dev/null", O_RDWR);
        /* the write end becomes stdout; careful if stdout was closed and
         * the pipe itself landed on descriptor 1 */
        if (p[1] != 1) { dup2(p[1], 1); close(p[1]); }
        if (p[0] != 1) close(p[0]);
        if (nul >= 0) { dup2(nul, 0); dup2(nul, 2); if (nul > 2) close(nul); }
        snprintf(env, sizeof env, "/jci/lib%s%s", old && *old ? ":" : "", old && *old ? old : "");
        setenv("LD_LIBRARY_PATH", env, 1);
        /* every other descriptor is close-on-exec */
        execl(cfg.smdb_read, "smdb-read", "-n", "vdm_vdt_current_data", "-e", Q_KEY[what], (char *)NULL);
        _exit(127);
    }
    close(p[1]);
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    child.pid = pid; child.fd = p[0]; child.what = what; child.len = 0; child.started = now;
}

static void child_done(int ok)
{
    long v = -1;
    int status = -1;
    if (child.fd >= 0) close(child.fd);
    child.fd = -1;
    if (!ok) kill(child.pid, SIGKILL);
    while (waitpid(child.pid, &status, 0) < 0 && errno == EINTR) { }
    child.pid = 0;
    /* an error message may end in a number too: only a clean exit counts */
    if (ok && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        /* the value is the last word of the output */
        char *e = child.buf + child.len, *s;
        *e = 0;
        while (e > child.buf && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
        s = e;
        while (s > child.buf && s[-1] >= '0' && s[-1] <= '9') s--;
        if (s < e && e - s <= 6 && (s == child.buf || s[-1] == ' ' || s[-1] == '\t' || s[-1] == '\n' || s[-1] == ':' || s[-1] == '='))
            v = strtol(s, NULL, 10);
    }
    smdb_apply(child.what, v);
    sdb_compare(child.what, v);
}

static void child_poll(int64_t now)
{
    int i;
    if (child.pid) {
        for (;;) {
            ssize_t r;
            if (child.len >= sizeof child.buf - 1) { child_done(0); break; }     /* far too much output */
            r = read(child.fd, child.buf + child.len, sizeof child.buf - 1 - child.len);
            if (r > 0) { child.len += (size_t)r; continue; }
            if (r == 0) { child_done(1); break; }
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) { child_done(0); break; }
            if (now - child.started > 4000) child_done(0);
            break;
        }
    }
    if (!child.pid) {
        for (i = 0; i < Q_N; i++) {
            if (!q_want[i]) continue;
            q_want[i] = 0;
            if (sdb_trust > 0) { smdb_want(i); continue; }    /* trusted in the meantime */
            child_start(i, now);
            break;
        }
    }
}

/* ───────────────────────── main loop ───────────────────────── */

static volatile sig_atomic_t stop_flag;
static void on_term(int s) { (void)s; stop_flag = 1; }

static int atime_selftest(void)
{
    char p[220], c;
    struct timespec ts[2];
    struct stat st;
    int fd, ok = 0;
    /* this process's own name: a self-test of another start may run beside it */
    snprintf(p, sizeof p, "%s/.dashboard.atime.%ld", cfg.dir, (long)getpid());
    fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    if (write(fd, "x", 1) == 1) {
        ts[0].tv_sec = ATIME_MARK; ts[0].tv_nsec = 0;
        ts[1].tv_sec = 0;          ts[1].tv_nsec = UTIME_OMIT;
        if (futimens(fd, ts) == 0) {
            close(fd);
            fd = open(p, O_RDONLY | O_CLOEXEC);
            if (fd >= 0 && read(fd, &c, 1) == 1 && fstat(fd, &st) == 0) ok = st.st_atime != ATIME_MARK;
        }
    }
    if (fd >= 0) close(fd);
    unlink(p);
    return ok;
}

static int64_t next_cool;               /* when the coolant is asked for next */

static void go_active(int64_t now)
{
    active = 1;
    last_reader = now;
    next_cool = now + (int64_t)cfg.cool_s * 1000;   /* it is asked for right here */
    /* what only comes "on change" may have changed unseen: ask again */
    ask_seeds();
    sdb_try_open(now);
    smdb_want(Q_COOL); smdb_want(Q_RPM); smdb_want(Q_THR); smdb_want(Q_STEER);
    publish(now);                       /* what is known right now: the page need not wait for a frame */
    vlog("active");
}

static int run(void)
{
    struct sigaction sa;
    int64_t now, next_sec, next_idle = 0, next_gps = 0, next_connect = 0;
    int lock_fd;
    FILE *f;

    mkdir(cfg.dir, 0755);
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* One daemon per directory. This lock is what decides it, not the
     * launcher: dashboard-daemon.sh start launches one of us every time it is
     * called, however many are called at once. The kernel drops the lock
     * when its holder ends, so it is never left behind; the file itself stays
     * (removing a lock file is how two holders come about). A second daemon
     * waits up to 4 s: it takes over from one that is being stopped (a stop
     * and a start running at the same time), and otherwise leaves, having
     * written nothing. Nothing here may touch the run directory before the
     * lock is held. */
    lock_fd = open(path_lock, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (lock_fd < 0) {
        /* no run directory to work in: nothing could be published */
        fprintf(stderr, "nd2cn-dashd: cannot use %s: %s\n", cfg.dir, strerror(errno));
        return 1;
    }
    {
        int tries = 0;
        while (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
            struct timespec ts = { 0, 100000000L };
            if (errno == EINTR) continue;
            if (errno != EWOULDBLOCK) break;     /* no locks on this file system: go on without */
            if (stop_flag || ++tries > 40) {
                vlog("another nd2cn-dashd is running on %s", cfg.dir);
                return 0;
            }
            nanosleep(&ts, NULL);
        }
    }

    f = fopen(path_pid, "w");
    if (f) { fprintf(f, "%ld\n", (long)getpid()); fclose(f); }

    strcpy(gearbox, cfg.gearbox);
    atime_ok = cfg.idle_auto && atime_selftest();
    now = now_ms();
    next_sec = now + 1000;
    /* Start idle if reads can be seen: the page wakes us within a second. */
    active = !atime_ok;
    last_reader = now;
    if (active) {
        sdb_try_open(now); smdb_want(Q_COOL); smdb_want(Q_RPM); smdb_want(Q_THR); smdb_want(Q_STEER);
        next_cool = now + (int64_t)cfg.cool_s * 1000;
    } else {
        publish_idle(now); next_idle = now + 250;
    }
    vlog("dashd %s: dir %s, bus %s, read detection %s", DASHD_VERSION, cfg.dir, cfg.bus, atime_ok ? "on" : "off (always active)");

    while (!stop_flag) {
        struct pollfd pf[2];
        int npf = 0, timeout;
        int64_t wake;

        now = now_ms();
        if (bus_fd < 0 && now >= next_connect) {
            next_connect = now + 2000;
            if (bus_connect() == 0 && active) ask_seeds();
        }

        /* when to wake up at the latest */
        wake = next_sec;
        if (!active && next_idle < wake) wake = next_idle;
        if (active && deadline && deadline < wake) wake = deadline;
        if (active && last_pub + 450 < wake) wake = last_pub + 450;
        if (active && bus_fd >= 0 && next_gps < wake) wake = next_gps;
        if (child.pid && now + 50 < wake) wake = now + 50;
        if (bus_fd < 0 && next_connect < wake) wake = next_connect;
        timeout = wake > now ? (int)(wake - now) : 0;

        if (bus_fd >= 0) { pf[npf].fd = bus_fd; pf[npf].events = POLLIN; pf[npf].revents = 0; npf++; }
        if (child.pid)   { pf[npf].fd = child.fd; pf[npf].events = POLLIN; pf[npf].revents = 0; npf++; }
        if (poll(pf, (nfds_t)npf, timeout) < 0 && errno != EINTR) break;
        now = now_ms();

        if (bus_fd >= 0 && (pf[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            if (bus_read(now) < 0) {
                vlog("bus: connection lost");
                bus_close();
                next_connect = now + 2000;
            }
        }
        child_poll(now);

        if (active) {
            if (deadline && now >= deadline && frame_dirty) publish(now);
            /* No frames on the bus (ignition off, bus down): still say what is
             * known twice a second. The page greys its values after 0.6 s
             * without a new file, which would otherwise read as "daemon gone". */
            else if (now - last_pub >= 450) publish(now);
            if (bus_fd >= 0 && now >= next_gps) { ask_gps(now); next_gps = now + cfg.gps_ms; }
            if (now >= next_cool) { sdb_try_open(now); smdb_want(Q_COOL); next_cool = now + (int64_t)cfg.cool_s * 1000; }
        } else if (now >= next_idle) {
            /* idle: a heartbeat four times a second. It costs next to nothing,
             * and it is how the page opening is noticed: check_reader() sees
             * that the last heartbeat was read. */
            next_idle = now + 250;
            if (publish_idle(now)) go_active(now);
        }

        if (now >= next_sec) {
            next_sec += 1000;
            if (next_sec <= now) next_sec = now + 1000;
            pub_hz = pub_count; pub_count = 0;
            if (active) {
                if (atime_ok && now - last_reader > (int64_t)cfg.linger_s * 1000) { active = 0; next_idle = now; vlog("idle"); }
            }
        }
    }

    if (child.pid) child_done(0);
    bus_close();
    unlink(path_out); unlink(path_tmp); unlink(path_pid);
    return 0;
}

/* ───────────────────────── exploring the databases ───────────────────────── */

static int db_open(const char *db, struct smdb_ro *h)
{
    char p[300];
    int rc;
    shm_locate(db);
    snprintf(p, sizeof p, "%s/smdb_%s", cfg.shm, db);
    rc = smdb_ro_open_path(p, h);
    if (rc != SMDB_RO_OK) printf("# %s: cannot read %s: %s\n", db, p, smdb_ro_strerror(rc));
    return rc;
}

/* nd2cn-dashd smdb [DB ...] — every entry, one line each:
 *     DB <tab> NAME <tab> int|string|binary <tab> SIZE <tab> VALUE */
static void dump_db(const char *db)
{
    struct smdb_ro h;
    int i, n;
    if (db_open(db, &h) != SMDB_RO_OK) return;
    n = smdb_ro_count(&h);
    printf("# %s: %u bytes, %d entries\n", db, (unsigned)h.total, n);
    for (i = 0; i < n; i++) {
        const char *name;
        int type;
        unsigned size, k, len;
        unsigned char buf[64];
        long v;
        if (smdb_ro_entry(&h, i, &name, &type, &size) != SMDB_RO_OK) continue;
        printf("%s\t%s\t%s\t%u\t", db, name, type == SMDB_RO_TYPE_INT ? "int" : type == SMDB_RO_TYPE_STRING ? "string" : "binary", size);
        if (type == SMDB_RO_TYPE_INT) {
            if (smdb_ro_read_int(&h, i, &v) == SMDB_RO_OK) printf("%ld", v);
        } else {
            /* the first 64 bytes: text as text (what is not printable as '.'), binary as hex */
            len = size < sizeof buf ? size : (unsigned)sizeof buf;
            if (smdb_ro_read_bytes(&h, i, buf, sizeof buf, NULL) != SMDB_RO_OK && size > sizeof buf) {
                /* longer than the buffer: read_bytes refuses, so copy the head by hand */
                struct smdb_ro__ent e;
                if (smdb_ro__entry(&h, i, &e) == SMDB_RO_OK) memcpy(buf, h.base + e.data_off, len);
                else len = 0;
            }
            for (k = 0; k < len; k++) {
                if (type == SMDB_RO_TYPE_STRING) {
                    if (!buf[k]) break;
                    putchar(buf[k] >= 32 && buf[k] < 127 ? buf[k] : '.');
                } else {
                    printf("%02X", buf[k]);
                }
            }
            if (size > len) printf("...");
        }
        putchar('\n');
    }
    smdb_ro_close(&h);
}

static int cmd_smdb(int argc, char **argv)
{
    int i, any = 0;
    for (i = 0; i < argc; i++) {
        if (argv[i][0] == '-' || strcmp(argv[i], "smdb") == 0) continue;
        dump_db(argv[i]);
        any = 1;
    }
    if (!any) {                         /* all of them */
        DIR *d;
        shm_locate(SMDB_DB);
        printf("# databases in %s\n", cfg.shm);
        d = opendir(cfg.shm);
        struct dirent *de;
        if (!d) { printf("# cannot list %s: %s\n", cfg.shm, strerror(errno)); return 1; }
        while ((de = readdir(d)) != NULL) {
            if (strncmp(de->d_name, "smdb_", 5) == 0) dump_db(de->d_name + 5);
        }
        closedir(d);
    }
    return 0;
}

/* nd2cn-dashd smdbwatch SECONDS [DB] — sample every entry of one database 10
 * times a second and say what each one did. One line per entry:
 *     NAME <tab> int <tab> FIRST <tab> MIN <tab> MAX <tab> LAST <tab> CHANGES
 *     NAME <tab> binary|string <tab> SIZE <tab> CHANGES
 * CHANGES counts the samples that differed from the one before. */
#define WATCH_MAX 2048
static int cmd_smdbwatch(int secs, const char *db)
{
    static long first[WATCH_MAX], mn[WATCH_MAX], mx[WATCH_MAX], last[WATCH_MAX];
    static uint32_t sum[WATCH_MAX];
    static unsigned chg[WATCH_MAX];
    struct smdb_ro h;
    int i, n, samples = 0, moved = 0;
    int64_t t0, next;
    if (secs < 1) secs = 1;
    if (secs > 3600) secs = 3600;
    if (db_open(db, &h) != SMDB_RO_OK) return 1;
    n = smdb_ro_count(&h);
    if (n > WATCH_MAX) n = WATCH_MAX;
    t0 = next = now_ms();
    while (!stop_flag && now_ms() - t0 < (int64_t)secs * 1000) {
        for (i = 0; i < n; i++) {
            const char *name;
            int type;
            unsigned size;
            if (smdb_ro_entry(&h, i, &name, &type, &size) != SMDB_RO_OK) continue;
            if (type == SMDB_RO_TYPE_INT) {
                long v;
                if (smdb_ro_read_int(&h, i, &v) != SMDB_RO_OK) continue;
                if (!samples) { first[i] = mn[i] = mx[i] = v; }
                else {
                    if (v != last[i]) chg[i]++;
                    if (v < mn[i]) mn[i] = v;
                    if (v > mx[i]) mx[i] = v;
                }
                last[i] = v;
            } else {
                /* a checksum is enough to see whether the bytes changed */
                struct smdb_ro__ent e;
                uint32_t c = 2166136261u, k;
                if (smdb_ro__entry(&h, i, &e) != SMDB_RO_OK) continue;
                for (k = 0; k < e.size; k++) c = (c ^ h.base[e.data_off + k]) * 16777619u;
                if (samples && c != sum[i]) chg[i]++;
                sum[i] = c;
            }
        }
        samples++;
        next += 100;
        while (!stop_flag && now_ms() < next) {
            struct timespec ts = { 0, 5 * 1000 * 1000 };
            nanosleep(&ts, NULL);
        }
    }
    for (i = 0; i < n; i++) if (chg[i]) moved++;
    printf("# smdbwatch %s: %u bytes, %d entries, %d samples in %.1f s, %d entries changed\n",
           db, (unsigned)h.total, n, samples, (double)(now_ms() - t0) / 1000.0, moved);
    for (i = 0; i < n; i++) {
        const char *name;
        int type;
        unsigned size;
        if (smdb_ro_entry(&h, i, &name, &type, &size) != SMDB_RO_OK) continue;
        if (type == SMDB_RO_TYPE_INT) printf("%s\tint\t%ld\t%ld\t%ld\t%ld\t%u\n", name, first[i], mn[i], mx[i], last[i], chg[i]);
        else printf("%s\t%s\t%u\t%u\n", name, type == SMDB_RO_TYPE_STRING ? "string" : "binary", size, chg[i]);
    }
    smdb_ro_close(&h);
    return 0;
}

/* Can this binary run here at all, and can it do what it needs? Used by the
 * installer and by dashboard-daemon.sh before they rely on it. */
static int selftest(void)
{
    char p[220], q[220];
    int fd, ok;
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) { printf("nd2cn-dashd FAIL clock\n"); return 1; }
    mkdir(cfg.dir, 0755);
    snprintf(p, sizeof p, "%s/.dashd.selftest.%ld", cfg.dir, (long)getpid());
    snprintf(q, sizeof q, "%s/.dashd.selftest2.%ld", cfg.dir, (long)getpid());
    fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    ok = fd >= 0 && write(fd, "x\n", 2) == 2;
    if (fd >= 0) close(fd);
    ok = ok && rename(p, q) == 0;
    unlink(p); unlink(q);
    if (!ok) { printf("nd2cn-dashd FAIL cannot write in %s\n", cfg.dir); return 1; }
    printf("nd2cn-dashd OK version=%s read-detection=%s double=%.3f",
           DASHD_VERSION, atime_selftest() ? "yes" : "no", 4000 * cfg.latg_scale + cfg.latg_offset + 1.5);
    {
        /* the shared memory database: only reported, never a reason to fail */
        struct smdb_ro h;
        char sp[300];
        int rc;
        long v = -1;
        shm_locate(SMDB_DB);
        snprintf(sp, sizeof sp, "%s/smdb_%s", cfg.shm, SMDB_DB);
        rc = smdb_ro_open_path(sp, &h);
        if (rc == SMDB_RO_OK) {
            int ix = smdb_ro_find(&h, "EngClnt_Te_Actl");
            if (ix >= 0) smdb_ro_read_int(&h, ix, &v);
            printf(" smdb=%ubytes/%uentries@%s coolant-raw=%ld", (unsigned)h.total, (unsigned)h.count, cfg.shm, v);
            smdb_ro_close(&h);
        } else {
            printf(" smdb=no(%s)", smdb_ro_strerror(rc));
        }
    }
    putchar('\n');
    return 0;
}

int main(int argc, char **argv)
{
    const char *cmd = NULL, *arg1 = NULL, *arg2 = NULL, *e;
    int i;
    if ((e = getenv("DASH_BUS")) && *e)       snprintf(cfg.bus, sizeof cfg.bus, "%s", e);
    if ((e = getenv("DASH_RUN_DIR")) && *e)   snprintf(cfg.dir, sizeof cfg.dir, "%s", e);
    if ((e = getenv("DASH_CONF")) && *e)      snprintf(cfg.conf, sizeof cfg.conf, "%s", e);
    if ((e = getenv("DASH_SMDB_READ")) && *e) snprintf(cfg.smdb_read, sizeof cfg.smdb_read, "%s", e);
    if ((e = getenv("DASH_SHM_DIR")) && *e) { snprintf(cfg.shm, sizeof cfg.shm, "%s", e); shm_fixed = 1; }
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0) cfg.verbose = 1;
        else if (argv[i][0] == '-') continue;
        else if (!cmd) cmd = argv[i];
        else if (!arg1) arg1 = argv[i];
        else if (!arg2) arg2 = argv[i];
    }
    if (!cmd) cmd = "run";
    conf_load(cfg.conf);
    snprintf(path_out, sizeof path_out, "%s/dashboard.json", cfg.dir);
    snprintf(path_tmp, sizeof path_tmp, "%s/.dashboard.json.tmp", cfg.dir);
    snprintf(path_pid, sizeof path_pid, "%s/dashboard-daemon.pid", cfg.dir);
    snprintf(path_lock, sizeof path_lock, "%s/.daemon.lock", cfg.dir);

    if (strcmp(cmd, "run") == 0) return run();
    if (strcmp(cmd, "selftest") == 0) return selftest();
    if (strcmp(cmd, "smdb") == 0) return cmd_smdb(argc - 1, argv + 1);
    if (strcmp(cmd, "smdbwatch") == 0) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_term;
        sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
        return cmd_smdbwatch(arg1 ? atoi(arg1) : 10, arg2 ? arg2 : SMDB_DB);
    }
    if (strcmp(cmd, "version") == 0) { printf("%s\n", DASHD_VERSION); return 0; }
    fprintf(stderr, "usage: %s [run|selftest|version|smdb [DB ...]|smdbwatch SECONDS [DB]] [-v]\n", argv[0]);
    return 2;
}
