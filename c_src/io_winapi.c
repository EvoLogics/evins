#include "io.h"

#ifdef _WIN32

#include <stdlib.h>

static int io_set_params(context_t *ctx);

context_t *io_stdin(void) {
    static context_t ctx;
    ctx.fd = GetStdHandle(STD_INPUT_HANDLE);
    ctx.ov_read.hEvent  = CreateEvent(NULL, TRUE, FALSE, NULL);
    return &ctx;
}

context_t *io_stdout(void) {
    static context_t ctx;
    ctx.fd = GetStdHandle(STD_OUTPUT_HANDLE);
    ctx.ov_write.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    return &ctx;
}

context_t *io_open_rs232(const portconf_t *pconf) {
    char path[256 + 4] = "\\\\.\\";
    context_t *ctx = malloc(sizeof(context_t));
    memset(ctx, '\0', sizeof(context_t));

    if (ctx == NULL)
        return NULL;

    strcat(path, pconf->path);

    memset(ctx, '\0', sizeof(*ctx));
    if ((ctx->fd = CreateFile(pconf->path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL)) == INVALID_HANDLE_VALUE
            || io_set_params(ctx) < 0
            || io_set_baudrate(ctx, pconf->baudrate) < 0
            || io_set_databits(ctx, pconf->databits) < 0
            || io_set_parity(ctx, pconf->parity) < 0
            || io_set_stopbits(ctx, pconf->stopbits) < 0
            || io_set_flowcontrol(ctx, pconf->flowcontrol) < 0)
        goto error;

    ctx->ov_read.hEvent  = CreateEvent(NULL, TRUE, FALSE, NULL);
    ctx->ov_write.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    return ctx;

error:
    CloseHandle(ctx->fd);
    free(ctx);
    return NULL;
}

void io_close_rs232(context_t *ctx) {
    CancelIo(ctx->fd);
    CloseHandle(ctx->fd);
    CloseHandle(ctx->ov_read.hEvent);
    CloseHandle(ctx->ov_write.hEvent);
    free(ctx);
}

int io_poll(context_t *ctx[], unsigned n) {
    HANDLE events[4];
    unsigned i, j, k, flag = 0;

    for (i = 0, j = 0; i < n; ++i) {
        if (!ctx[i])
            break;

        ctx[i]->repl[0] = ctx[i]->repl[1] = 0;

        if (ctx[i]->req[0]) { flag = 1; events[j++] = ctx[i]->ov_read.hEvent; }
        if (ctx[i]->req[1]) { flag = 1; events[j++] = ctx[i]->ov_write.hEvent; }
    }

    if (!flag)
        return 0;

    DWORD rs = WaitForMultipleObjects(j, events, FALSE, INFINITE);
    if (rs >= WAIT_OBJECT_0 + j)
        return -1;

    k = rs - WAIT_OBJECT_0;
    for (i = 0, j = 0; i < n; ++i) {
        if (!ctx[i])
            break;

        if (ctx[i]->req[0] && j++ == k) ctx[i]->repl[0] = 1;
        if (ctx[i]->req[1] && j++ == k) ctx[i]->repl[1] = 1;
    }

    return 0;
}

ssize_t io_read(context_t *ctx, void *ptr, ssize_t len) {
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    DWORD read;
    if (ctx->repl[0]) {
        if (!GetOverlappedResult(ctx->fd, &ctx->ov_read, &read, TRUE))
            return -1;

        ctx->repl[0] = 0;
    } else if (!ctx->req[0]) {
        if (!ReadFile(ctx->fd, ptr, len, &read, &ctx->ov_read)) {
            if (GetLastError() == ERROR_IO_PENDING) {
                ctx->req[0] = 1;
                return -2;
            }

            ctx->req[0] = 0;
            return -1;
        }
    } else
        return -2;

    ctx->req[0] = 0;
    return read;
}

ssize_t io_write(context_t *ctx, const void *ptr, ssize_t len) {
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    DWORD written;

    if (ctx->repl[1]) {
        if (!GetOverlappedResult(ctx->fd, &ctx->ov_write, &written, TRUE))
            return -1;

        ctx->repl[1] = 0;
    } else if (!ctx->req[1]) {
        if (!WriteFile(ctx->fd, ptr, len, &written, &ctx->ov_write)) {
            if (GetLastError() == ERROR_IO_PENDING) {
                ctx->req[1] = 1;
                return -2;
            }

            ctx->req[1] = 0;
            return -1;
        }
    } else
        return -2;

    ctx->req[1] = 0;
    return written;
}

int io_set_baudrate(const context_t *ctx, int baudrate) {
    DCB dcb;
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    if (!GetCommState(ctx->fd, &dcb))
        return -1;

    switch (baudrate) {
        case 300:    dcb.BaudRate = CBR_300;      break;
        case 600:    dcb.BaudRate = CBR_600;      break;
        case 1200:   dcb.BaudRate = CBR_1200;     break;
        case 2400:   dcb.BaudRate = CBR_2400;     break;
        case 4800:   dcb.BaudRate = CBR_4800;     break;
        case 9600:   dcb.BaudRate = CBR_9600;     break;
        case 19200:  dcb.BaudRate = CBR_19200;    break;
        case 38400:  dcb.BaudRate = CBR_38400;    break;
        case 57600:  dcb.BaudRate = CBR_57600;    break;
        case 115200: dcb.BaudRate = CBR_115200;   break;
        default: return -1;
    }

    return SetCommState(ctx->fd, &dcb) ? 0 : -1;
}

int io_set_databits(const context_t *ctx, int databits) {
    DCB dcb;
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    if (!GetCommState(ctx->fd, &dcb))
        return -1;

    dcb.ByteSize = databits;

    return SetCommState(ctx->fd, &dcb) ? 0 : -1;
}

int io_set_parity(const context_t *ctx, sparity_t parity) {
    DCB dcb;
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    if (!GetCommState(ctx->fd, &dcb))
        return -1;

    switch (parity) {
        case SPNONE:    dcb.Parity = NOPARITY;      break;
        case SPODD:     dcb.Parity = ODDPARITY;     break;
        case SPEVEN:    dcb.Parity = EVENPARITY;    break;
        default: return -1;
    }

    return SetCommState(ctx->fd, &dcb) ? 0 : -1;
}

int io_set_stopbits(const context_t *ctx, int stopbits) {
    DCB dcb;
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    if (!GetCommState(ctx->fd, &dcb))
        return -1;

    switch (stopbits) {
        case 1: dcb.StopBits = ONESTOPBIT;  break;
        case 2: dcb.StopBits = TWOSTOPBITS; break;
        default: return -1;
    }

    return SetCommState(ctx->fd, &dcb) ? 0 : -1;
}

int io_set_flowcontrol(const context_t *ctx, int flowcontrol) {
    DCB dcb;
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    if (!GetCommState(ctx->fd, &dcb))
        return -1;

    if (flowcontrol) {
        dcb.fOutxCtsFlow = TRUE;
        dcb.fRtsControl = RTS_CONTROL_HANDSHAKE;
    } else {
        dcb.fOutxCtsFlow = FALSE;
        dcb.fRtsControl = RTS_CONTROL_ENABLE;
    }

    return SetCommState(ctx->fd, &dcb) ? 0 : -1;
}

int io_enumerate(char *buf, size_t len) {
    HKEY SERIALCOMM;
    TCHAR *name = NULL;
    BYTE *value = NULL;
    size_t d_len;

    buf[0] = '\0';
    len -= 1;

    if (RegOpenKeyEx(HKEY_LOCAL_MACHINE, "HARDWARE\\DEVICEMAP\\SERIALCOMM", 0, KEY_QUERY_VALUE, &SERIALCOMM) == ERROR_SUCCESS) {
        DWORD maxNameLen, maxValueLen, queryInfo;

        if ((queryInfo = RegQueryInfoKey(SERIALCOMM, NULL, NULL, NULL, NULL, NULL, NULL, NULL, &maxNameLen, &maxValueLen, NULL, NULL)) == ERROR_SUCCESS) {
            DWORD nameLen = maxNameLen + 1, nameSize = nameLen * sizeof(TCHAR),
                  valueLen = maxValueLen / sizeof(TCHAR) + 1, valueSize = valueLen * sizeof(TCHAR);

            if ((name = (TCHAR *)malloc(nameSize)) && (value = (BYTE *)malloc(valueSize))) {
                DWORD idx = 0, type, nameWritten = nameLen, valueWritten = valueSize;
                DWORD nEnum;

                memset(name, '\0', nameSize);
                memset(value, '\0', valueSize);

                while ((nEnum = RegEnumValue(SERIALCOMM, idx++, name, &nameWritten, NULL, &type, value, &valueWritten)) == ERROR_SUCCESS) {
                    if (type == REG_SZ) {
                        if (len < (d_len = strlen((char *)value) + (buf[0] ? 1 : 0)))
                            break;

                        if (buf[0])
                            strcat(buf, ",");

                        strcat(buf, (char *)value);

                        len -= d_len;
                        buf += d_len - 1; // leave last non-zero byte
                    }

                    memset(name, '\0', nameWritten);
                    memset(value, '\0', valueWritten);

                    nameWritten = nameLen;
                    valueWritten = valueSize;
                }
            } else
                return -1;
        } else
            return -1;

        RegCloseKey(SERIALCOMM);
    }

    free(name);
    free(value);
    return 0;
}

static int io_set_params(context_t *ctx) {
    DCB dcb;
    COMMTIMEOUTS timeouts;
    if (ctx == NULL || ctx->fd == INVALID_HANDLE_VALUE)
        return -1;

    if (!GetCommState(ctx->fd, &dcb))
        return -1;

    dcb.fBinary = TRUE;
    dcb.fErrorChar = FALSE;
    dcb.fNull = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fDsrSensitivity = FALSE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;

    if (!SetCommState(ctx->fd, &dcb))
        return -1;

    memset(&timeouts, '\0', sizeof(timeouts));
    timeouts.ReadIntervalTimeout = MAXDWORD;
    timeouts.ReadTotalTimeoutMultiplier = 0;
    timeouts.WriteTotalTimeoutMultiplier = 0;
    timeouts.ReadTotalTimeoutConstant = 1;
    timeouts.WriteTotalTimeoutConstant = 1;

    return SetCommTimeouts(ctx->fd, &timeouts) ? 0 : -1;
}

#endif
