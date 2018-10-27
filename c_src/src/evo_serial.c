#include <string.h>
#include <stdlib.h>
#include <stdint.h>

#ifdef _WIN32
  #include <io.h>
  #include <stdio.h>
  #include <fcntl.h>
#endif

#include "evo-io.h"
#include "logger.h"

typedef enum {
    COPEN           = 0,
    CSEND           = 1,
    CRECV           = 2,
    CERROR          = 3
} erl_cmd_l;

typedef struct {
    uint8_t len, done;
    enum { CHDR, CDATA, CREADY } state;
    uint8_t data[256];
} erl_chunk_t;

typedef struct {
    uint8_t data[1024];
    uint8_t *head, *tail, empty;
} cbuf_t;

ssize_t erl_read(context_t *ctx, erl_chunk_t *chunk);

size_t cbuf_used(cbuf_t *cbuf);
size_t cbuf_free(cbuf_t *cbuf);
void cbuf_norm(cbuf_t *cbuf);

int main(void) {
#ifdef _WIN32
    setmode(fileno(stdout),O_BINARY);
    setmode(fileno(stdin),O_BINARY);
#endif

    erl_chunk_t erl_inp = { 0xFF, 0, CHDR, {0} };
    cbuf_t erl_outp, rs_outp;
    uint8_t rs_inp[254];
    context_t *ctx[3];
    portconf_t portconf = {
        .path = "",
        .baudrate = 115200,
        .databits = 8,
        .stopbits = 1,
        .flowcontrol = 0,
        .parity = SPNONE
    };
    ssize_t rs;

    erl_outp.head = erl_outp.tail = erl_outp.data;
    rs_outp.head  = rs_outp.tail  = rs_outp.data;
    erl_outp.empty = rs_outp.empty = 1;

    ctx[0] = io_stdin();
    ctx[1] = io_stdout();
    ctx[2] = NULL;

    for (;;) {
        if ((rs = erl_read(ctx[0], &erl_inp)) < 0 && rs == -1)
            return 1;
        else if (rs > 0 && erl_inp.state == CREADY) {
            erl_inp.state = CHDR;
            erl_inp.done = 0;
            switch (erl_inp.data[0]) {
            case COPEN:
                erl_inp.data[erl_inp.len] = '\0';
                portconf.baudrate    =  erl_inp.data[1] |
                                       (erl_inp.data[2] << 8) |
                                       (erl_inp.data[3] << 16);
                portconf.databits    = ((erl_inp.data[4] >> 5) & 0x07) + 1;
                portconf.parity      = (erl_inp.data[4] >> 3) & 0x03;
                portconf.stopbits    = ((erl_inp.data[4] >> 2) & 0x01) + 1;
                portconf.flowcontrol = (erl_inp.data[4] >> 1) & 0x01;

                strncpy((char *)portconf.path, (char *)erl_inp.data + 5, sizeof(portconf.path) - 1);
                portconf.path[sizeof(portconf.path) - 1] = '\0';

                if (!(ctx[2] = io_open_rs232(&portconf)))
                    return 1;

                break;

            case CSEND:
                if (cbuf_free(&rs_outp) < erl_inp.len) // TODO: prevent this situation
                    return 1;

                memcpy(rs_outp.head, erl_inp.data + 1, erl_inp.len - 1);
                rs_outp.head += erl_inp.len - 1;
                break;
            }
        }

        if (ctx[2]) {
            if ((rs = io_read(ctx[2], rs_inp, sizeof(rs_inp))) < 0 && rs == -1)
                return 1;
            else if (rs > 0) {
                size_t len = 1 + 1 + rs;

                if (cbuf_free(&erl_outp) < len)
                    return 1;

                erl_outp.head[0] = len - 1;
                erl_outp.head[1] = CRECV;
                memcpy(erl_outp.head + 2, rs_inp, len);
                erl_outp.head += len;
            }

            while (ctx[2] && cbuf_used(&rs_outp)) {
                if ((rs = io_write(ctx[2], rs_outp.tail, cbuf_used(&rs_outp))) < 0 && rs == -1)
                    return 1;
                else if (rs > 0) {
                    rs_outp.tail += rs;
                    cbuf_norm(&rs_outp);
                } else
                    break;
            }
        }

        while (cbuf_used(&erl_outp)) {
            if ((rs = io_write(ctx[1], erl_outp.tail, cbuf_used(&erl_outp))) < 0 && rs == -1)
                return 1;
            else if (rs > 0) {
                erl_outp.tail += rs;
                cbuf_norm(&erl_outp);
            } else
                break;
        }

        if (!ctx[0]->req[0] || (ctx[2] && !ctx[2]->req[0]))
            continue;

        io_poll(ctx, 3);
    }

    return 0;
}

ssize_t erl_read(context_t *ctx, erl_chunk_t *chunk) {
    ssize_t rs;

    switch (chunk->state) {
    case CHDR:
        if ((rs = io_read(ctx, &chunk->len, 1)) < 0)
            return rs;

        if (rs == 0)
            break;

        chunk->state = CDATA;
        chunk->done = 0;
        // no break
    case CDATA:
        if ((rs = io_read(ctx, chunk->data + chunk->done, chunk->len - chunk->done)) < 0)
            return rs;

        chunk->done += rs;
        if (chunk->done == chunk->len)
            chunk->state = CREADY;
        break;

    case CREADY:
        break;
    }

    return chunk->state == CREADY;
}

size_t cbuf_used(cbuf_t *cbuf) {
    return cbuf->head - cbuf->tail;
}

size_t cbuf_free(cbuf_t *cbuf) {
    return sizeof(cbuf->data) / 2 - cbuf_used(cbuf);
}

void cbuf_norm(cbuf_t *cbuf) {
    static const size_t hsz = sizeof(cbuf->data) / 2;
    const uint8_t *hdata = cbuf->data + hsz;

    if (cbuf->tail >= hdata) {
        memcpy(cbuf->tail - hsz, cbuf->tail, cbuf->head - cbuf->tail);
        cbuf->head -= hsz;
        cbuf->tail -= hsz;
    }
}
