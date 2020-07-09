#ifndef __LOGGER_H__
#define __LOGGER_H__

#include <stdint.h>
#include <stdlib.h>
#include <inttypes.h>

#define C_NORM      "\e[0m"
#define C_BLUE      "\e[2;34m"
#define C_CYAN      "\e[0;36m"
#define C_GREEN     "\e[0;32m"
#define C_BGREEN    "\e[1;32m"
#define C_MAGENTA   "\e[0;35m"
#define C_RED       "\e[0;31m"
#define C_BRED      "\e[1;31m"
#define C_YELLOW    "\e[0;33m"
#define C_BYELLOW   "\e[1;33m"

#define LOG_FATAL            (1 << 0)
#define LOG_ERROR            (1 << 1)
#define LOG_WARNING          (1 << 2)
#define LOG_INFO             (1 << 3)
#define LOG_DEBUG            (1 << 4)
#define LOG_TRACE            (1 << 5)
#define LOG_PERIODIC1        (1 << 6)
#define LOG_PERIODIC2        (1 << 7)
#define LOG_PREFIX           (1 << 8)
#define LOG_LOCATION         (1 << 9)

#define logger(level, ...)                                                \
    do {                                                                  \
        if ((level & log_level))                                          \
            logger_(level, __FILE__, __LINE__, __func__, __VA_ARGS__);    \
    } while(0)
#define logger_mat(level, m, n, data, name)                               \
    do {                                                                  \
        if ((level & log_level))                                          \
            logger_mat_(level, m, n, data, name,                          \
                        __FILE__, __LINE__, __func__);                    \
    } while(0)

void logger_init(uint16_t level);
void logger_(uint16_t level, const char *file, int line, const char *func,
             const char *msg, ...);
void logger_mat_(uint16_t level, size_t m, size_t n, const double *data, const char *name,
                 const char *file, int line, const char *func);

extern uint16_t log_level;

#endif
