#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Read a single line from a /proc file and print a labelled value. */
static void proc_field(const char *path, const char *field, const char *label)
{
    char line[256];
    FILE *f = fopen(path, "r");
    if (!f) { printf("  %-12s n/a\n", label); return; }
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, field, strlen(field)) == 0) {
            /* value starts after the colon */
            char *v = strchr(line, ':');
            if (v) {
                v++;
                while (*v == ' ' || *v == '\t') v++;
                /* strip trailing newline */
                v[strcspn(v, "\n")] = '\0';
                printf("  %-12s %s\n", label, v);
            }
            break;
        }
    }
    fclose(f);
}

int main(void)
{
    /* uptime */
    {
        FILE *f = fopen("/proc/uptime", "r");
        if (f) {
            double up, idle;
            if (fscanf(f, "%lf %lf", &up, &idle) == 2) {
                long h = (long)up / 3600;
                long m = ((long)up % 3600) / 60;
                long s = (long)up % 60;
                printf("  %-12s %ldh %ldm %lds\n", "uptime", h, m, s);
            }
            fclose(f);
        }
    }

    /* memory */
    proc_field("/proc/meminfo", "MemTotal",     "mem total");
    proc_field("/proc/meminfo", "MemFree",      "mem free");
    proc_field("/proc/meminfo", "MemAvailable", "mem avail");

    /* cpu model */
    proc_field("/proc/cpuinfo", "Hardware",  "hardware");
    proc_field("/proc/cpuinfo", "model name","cpu");

    /* load average */
    {
        FILE *f = fopen("/proc/loadavg", "r");
        if (f) {
            char buf[64];
            if (fgets(buf, sizeof(buf), f)) {
                buf[strcspn(buf, "\n")] = '\0';
                printf("  %-12s %s\n", "load avg", buf);
            }
            fclose(f);
        }
    }

    return 0;
}
