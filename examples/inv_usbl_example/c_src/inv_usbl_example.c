/* example based on http://erlang.org/doc/tutorial/c_port.html */
#include <stdint.h>
#include <unistd.h>

static int read_cmd(int8_t *buf);
static int write_cmd(int8_t *buf, uint8_t len);
static int read_exact(int8_t *buf, uint8_t len);
static int write_exact(int8_t *buf, uint8_t len);
static void encode(int8_t *inbuf, uint8_t ilen, int8_t *outbuf, uint8_t *olen);

int read_cmd(int8_t *buf)
{
    uint8_t len;

    if (read_exact(buf, 1) != 1)
        return -1;
    len = (uint8_t)buf[0];
    return read_exact(buf, len);
}

int write_cmd(int8_t *buf, uint8_t len)
{
    write_exact((int8_t*)&len, 1);
    return write_exact(buf, len);
}

int read_exact(int8_t *buf, uint8_t len)
{
    int i, got=0;
    
    do {
        if ((i = read(0, buf + got, len - got)) <= 0)
            return i;
        got += i;
    } while (got < len);
    
    return (int)len;
}

int write_exact(int8_t *buf, uint8_t len)
{
    int i, wrote = 0;
    
    do {
        if ((i = write(1, buf+wrote, len-wrote)) <= 0)
            return i;
        wrote += i;
    } while (wrote < len);
    
    return (int)len;
}

void encode(int8_t *inbuf, uint8_t ilen, int8_t *outbuf, uint8_t *olen)
{
    int i;

    for (i = 0; i < ilen; i++) {
        outbuf[i] = inbuf[ilen - i - 1];
    }
    *olen = ilen;
}

int main()
{
    uint8_t len, olen;
    int8_t buf[256], obuf[256];

    do {
        len = read_cmd(buf);
        if (len > 0) {
            encode(buf, len, obuf, &olen);
            write_cmd(obuf, olen);
        }
    } while (len > 0);
    return 0;
}
