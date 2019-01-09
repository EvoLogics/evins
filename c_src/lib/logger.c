#ifdef LOGGER
#include <stdio.h>
#include <stdarg.h>
#endif

#include "logger.h"

uint16_t log_level = 0x03FFu;

void logger_init(uint16_t level) {
    log_level = level;
}

#ifdef LOGGER
void logger_(uint16_t level, const char *msg,
             const char *file, int line, const char *func, ...) {
    va_list ap;

    if ((log_level & LOG_LOCATION))
        fprintf(stderr, "%s:%d:(%s)", file, line, func);

    if ((log_level & LOG_PREFIX))
        switch (level) {
            case LOG_FATAL:     fprintf(stderr, "[FATAL]");     break;
            case LOG_ERROR:     fprintf(stderr, "[ERROR]");     break;
            case LOG_WARNING:   fprintf(stderr, "[WARNING]");   break;
            case LOG_INFO:      fprintf(stderr, "[INFO]");      break;
            case LOG_DEBUG:     fprintf(stderr, "[DEBUG]");     break;
            case LOG_TRACE:     fprintf(stderr, "[TRACE]");     break;
            case LOG_PERIODIC1: fprintf(stderr, "[PERIODIC1]"); break;
            case LOG_PERIODIC2: fprintf(stderr, "[PERIODIC2]"); break;
        }

    if ((log_level & (LOG_LOCATION | LOG_PREFIX)))
        fprintf(stderr, ": ");

    va_start(ap, func);
    vfprintf(stderr, msg, ap);
    va_end(ap);

    fflush(stderr);
}

void logger_mat_(uint16_t level, size_t m, size_t n, const double *data, const char *name,
                 const char *file, int line, const char *func) {
    const double *p = data;
    logger_(level, "matrix %zux%zu, name = \"%s\":\r\n", file, line, func, m, n, name);

    for (size_t i = 0; i < m; ++i) {
        fprintf(stderr, "    [ ");

        for (size_t j = 0; j < n; ++j)
            fprintf(stderr, "%+9.4f ", *p++);

        fprintf(stderr, "]\r\n");
    }

    fprintf(stderr, "\r\n");
    fflush(stderr);
}
#else
void logger_(uint16_t level, const char *msg,
             const char *file, int line, const char *func, ...) {
    (void)level;
    (void)msg;
    (void)file;
    (void)line;
    (void)func;
}

void logger_mat_(uint16_t level, size_t m, size_t n, const double *data, const char *name,
                 const char *file, int line, const char *func) {
    (void)level;
    (void)m;
    (void)n;
    (void)data;
    (void)name;
    (void)file;
    (void)line;
    (void)func;
}
#endif
