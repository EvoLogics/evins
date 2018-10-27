#include "evo-io.h"

#ifdef __unix

#include <sys/types.h>
#include <sys/poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <assert.h>
#include <errno.h>
#include <ctype.h>
#include <stdio.h>

static int io_set_params(context_t *ctx);

context_t *io_stdin(void) {
    static context_t ctx;
    ctx.fd = STDIN_FILENO;
    fcntl(ctx.fd, F_SETFL, fcntl(ctx.fd, F_GETFL, 0) | O_NONBLOCK);
    return &ctx;
}

context_t *io_stdout(void) {
    static context_t ctx;
    ctx.fd = STDOUT_FILENO;
    fcntl(ctx.fd, F_SETFL, fcntl(ctx.fd, F_GETFL, 0) | O_NONBLOCK);
    return &ctx;
}

context_t *io_open_rs232(const portconf_t *pconf) {
    context_t *ctx = malloc(sizeof(context_t));

    if (ctx == NULL)
        return NULL;

    memset(ctx, '\0', sizeof(*ctx));
    int m_errno;
    if ((ctx->fd = open((char *)pconf->path, O_RDWR | O_NOCTTY | O_NONBLOCK)) < 0
            || io_set_params(ctx) < 0
            || io_set_baudrate(ctx, pconf->baudrate) < 0
            || io_set_databits(ctx, pconf->databits) < 0
            || io_set_parity(ctx, pconf->parity) < 0
            || io_set_stopbits(ctx, pconf->stopbits) < 0
            || io_set_flowcontrol(ctx, pconf->flowcontrol) < 0) {
        m_errno = errno;
        goto error;
    }

    return ctx;

error:
    close(ctx->fd);
    free(ctx);
    errno = m_errno;
    return NULL;
}

void io_close_rs232(context_t *ctx) {
    close(ctx->fd);
    free(ctx);
}

int io_poll(context_t *ctx[], unsigned n) {
    struct pollfd fds[3];
    unsigned i, flag = 0;

    for (i = 0; i < n; ++i) {
        if (!ctx[i])
            break;

        fds[i].fd = ctx[i]->fd;
        fds[i].events = 0;
        fds[i].revents = 0;

        if (ctx[i]->req[0]) { flag = 1; fds[i].events |= POLLIN; }
        if (ctx[i]->req[1]) { flag = 1; fds[i].events |= POLLOUT; }
    }

    if (!flag)
        return 0;

    if (poll(fds, i, -1) < 0)
        return -1;

    for (i = 0; i < n; ++i) {
        if (!ctx[i])
            break;

        ctx[i]->repl[0] = fds[i].revents & POLLIN;
        ctx[i]->repl[1] = fds[i].revents & POLLOUT;
    }

    return 0;
}

ssize_t io_read(context_t *ctx, void *ptr, ssize_t len) {
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    ssize_t rs = read(ctx->fd, ptr, len);
    if (rs < 0 && errno == EAGAIN) {
        ctx->req[0] = 1;
        return -2;
    }

    ctx->req[0] = 0;
    return rs;
}

ssize_t io_write(context_t *ctx, const void *ptr, ssize_t len) {
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    ssize_t rs = write(ctx->fd, ptr, len);
    if (rs < 0 && errno == EAGAIN) {
        ctx->req[1] = 1;
        return -2;
    }

    ctx->req[1] = 0;
    return rs;
}

int io_set_baudrate(const context_t *ctx, int baudrate) {
    struct termios opts;
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    if (tcgetattr(ctx->fd, &opts) < 0)
        return -1;

    int rate;
    switch (baudrate) {
        case 300:    rate = B300;      break;
        case 600:    rate = B600;      break;
        case 1200:   rate = B1200;     break;
        case 2400:   rate = B2400;     break;
        case 4800:   rate = B4800;     break;
        case 9600:   rate = B9600;     break;
        case 19200:  rate = B19200;    break;
        case 38400:  rate = B38400;    break;
        case 57600:  rate = B57600;    break;
        case 115200: rate = B115200;   break;
        default: return -1;
    }

    cfsetispeed(&opts, rate);
    cfsetospeed(&opts, rate);

    return tcsetattr(ctx->fd, TCSANOW, &opts);
}

int io_set_databits(const context_t *ctx, int databits) {
    struct termios opts;
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    if (tcgetattr(ctx->fd, &opts) < 0)
        return -1;

    opts.c_cflag &= ~CSIZE;

    switch (databits) {
        case 8: opts.c_cflag |= CS8; break;
        case 7: opts.c_cflag |= CS7; break;
        case 6: opts.c_cflag |= CS6; break;
        case 5: opts.c_cflag |= CS5; break;
        default: return -1;
    }

    return tcsetattr(ctx->fd, TCSANOW, &opts);
}

int io_set_parity(const context_t *ctx, sparity_t parity) {
    struct termios opts;
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    if (tcgetattr(ctx->fd, &opts) < 0)
        return -1;

    switch (parity) {
    case SPNONE:
        opts.c_cflag &= ~PARENB;
        break;

    case SPODD:
        opts.c_cflag |= PARENB;
        opts.c_cflag |= PARODD;
        break;

    case SPEVEN:
        opts.c_cflag |= PARENB;
        opts.c_cflag &= ~PARODD;
        break;

    default:
        return -1;
    }

    return tcsetattr(ctx->fd, TCSANOW, &opts);
}

int io_set_stopbits(const context_t *ctx, int stopbits) {
    struct termios opts;
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    if (tcgetattr(ctx->fd, &opts) < 0)
        return -1;

    switch (stopbits) {
        case 1: opts.c_cflag &= ~CSTOPB; break;
        case 2: opts.c_cflag |= CSTOPB; break;
        default: return -1;
    }

    return tcsetattr(ctx->fd, TCSANOW, &opts);
}

int io_set_flowcontrol(const context_t *ctx, int flowcontrol) {
    struct termios opts;
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    if (tcgetattr(ctx->fd, &opts) < 0)
        return -1;

    if (flowcontrol)
        opts.c_cflag |=  CRTSCTS;
    else
        opts.c_cflag &= ~CRTSCTS;

    return tcsetattr(ctx->fd, TCSANOW, &opts);
}

int io_enumerate(char *buf, size_t len) {
    DIR *dirp;
    struct dirent *direntp;
    size_t d_len;

    buf[0] = '\0';
    len -= 1;

    if ((dirp = opendir("/dev")) == NULL)
        return -1;

    while ((direntp = readdir(dirp)) != NULL) {
        if (direntp->d_name[0] == '.')
            continue;

        if (!strncmp(direntp->d_name, "ttyS", 4) ||
            !strncmp(direntp->d_name, "ttyUSB", 6) ||
            !strncmp(direntp->d_name, "ttyACM", 6)) {
            if (len < (d_len = strlen(direntp->d_name) + 5 + (buf[0] ? 1 : 0)))
                break;

            if (buf[0])
                strcat(buf, ",");

            strcat(buf, "/dev/");
            strcat(buf, direntp->d_name);

            len -= d_len;
            buf += d_len - 1; // leave last non-zero byte
        }
    }

    closedir(dirp);
    return 0;
}

static int io_set_params(context_t *ctx) {
    struct termios opts;
    if (ctx == NULL || ctx->fd < 0)
        return -1;

    if (tcgetattr(ctx->fd, &opts) < 0)
        return -1;

    opts.c_iflag = 0;
    opts.c_oflag = 0;
    opts.c_cflag |= CLOCAL;
    opts.c_cflag |= CREAD;
    opts.c_lflag = 0;
    opts.c_cc[VMIN] = 1;
    opts.c_cc[VTIME] = 0;

    return tcsetattr(ctx->fd, TCSANOW, &opts);
}

#endif
