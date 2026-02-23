#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define README_PATH "/home/ubuntu/readme"
#define HTTP_TUNNEL_PORT 34080
#define HTTP_PING_DEFAULT_HOST "www.google.com"
#define HTTP_PING_DEFAULT_PATH "/"

static void strip_newline(char* s) {
    if (!s)
        return;
    size_t n = strlen(s);
    if (n && s[n - 1] == '\n')
        s[n - 1] = '\0';
}

static int write_all(int fd, const void* buf, size_t size) {
    const char* p = (const char*)buf;
    size_t written = 0;
    while (written < size) {
        ssize_t ret = write(fd, p + written, size - written);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        written += (size_t)ret;
    }
    return 0;
}

static int do_read(void) {
    int fd = open(README_PATH, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "open(%s) failed: %s\n", README_PATH, strerror(errno));
        return 1;
    }

    char buf[4096];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "read(%s) failed: %s\n", README_PATH, strerror(errno));
            (void)close(fd);
            return 1;
        }
        if (n == 0)
            break;
        if (write_all(STDOUT_FILENO, buf, (size_t)n) < 0) {
            fprintf(stderr, "write(stdout) failed: %s\n", strerror(errno));
            (void)close(fd);
            return 1;
        }
    }

    (void)close(fd);
    return 0;
}

static int do_write(void) {
    int fd = open(README_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "open(%s) failed: %s\n", README_PATH, strerror(errno));
        return 1;
    }

    printf("Enter text to write to %s.\n", README_PATH);
    printf("Finish by entering a single dot '.' on its own line.\n");
    fflush(stdout);

    char line[4096];
    while (fgets(line, sizeof(line), stdin)) {
        if (!strcmp(line, ".\n") || !strcmp(line, "."))
            break;
        if (write_all(fd, line, strlen(line)) < 0) {
            fprintf(stderr, "write(%s) failed: %s\n", README_PATH, strerror(errno));
            (void)close(fd);
            return 1;
        }
    }

    if (ferror(stdin)) {
        fprintf(stderr, "read(stdin) failed\n");
        (void)close(fd);
        return 1;
    }

    (void)close(fd);
    return 0;
}

static int connect_localhost(unsigned int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "socket(AF_INET) failed: %s\n", strerror(errno));
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) != 1) {
        fprintf(stderr, "inet_pton(127.0.0.1) failed\n");
        (void)close(fd);
        return -1;
    }

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "connect(127.0.0.1:%u) failed: %s\n", port, strerror(errno));
        (void)close(fd);
        return -1;
    }

    return fd;
}

static int read_line_fd(int fd, char* out, size_t out_size) {
    size_t pos = 0;
    while (pos + 1 < out_size) {
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r == 0) {
            break;
        }
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (c == '\n')
            break;
        out[pos++] = c;
    }
    while (pos > 0 && out[pos - 1] == '\r')
        pos--;
    out[pos] = '\0';
    return pos ? 0 : -1;
}

static int do_http_ping(const char* host, const char* path) {
    if (!host || !host[0])
        host = HTTP_PING_DEFAULT_HOST;
    if (!path || !path[0])
        path = HTTP_PING_DEFAULT_PATH;

    struct timespec t0;
    (void)clock_gettime(CLOCK_MONOTONIC, &t0);

    int fd = connect_localhost(HTTP_TUNNEL_PORT);
    if (fd < 0) {
        fprintf(stderr,
                "Hint: make sure the host forwarder listens on port %d and the parent VM runs the http tunnel (socat).\n",
                HTTP_TUNNEL_PORT);
        return 1;
    }

    char req[4096];
    int n = snprintf(req, sizeof(req),
                     "HEAD %s HTTP/1.1\r\n"
                     "Host: %s\r\n"
                     "User-Agent: gramine-tdx-vsock-http-ping\r\n"
                     "Connection: close\r\n"
                     "\r\n",
                     path, host);
    if (n < 0 || (size_t)n >= sizeof(req)) {
        fprintf(stderr, "request too long\n");
        (void)close(fd);
        return 1;
    }

    if (write_all(fd, req, (size_t)n) < 0) {
        fprintf(stderr, "write(sock) failed: %s\n", strerror(errno));
        (void)close(fd);
        return 1;
    }
    (void)shutdown(fd, SHUT_WR);

    char status[4096];
    if (read_line_fd(fd, status, sizeof(status)) < 0) {
        fprintf(stderr, "no response\n");
        (void)close(fd);
        return 1;
    }

    printf("%s\n", status);

    struct timespec t1;
    if (clock_gettime(CLOCK_MONOTONIC, &t1) == 0) {
        double sec = (double)(t1.tv_sec - t0.tv_sec);
        double nsec = (double)(t1.tv_nsec - t0.tv_nsec);
        printf("[local elapsed: %.2f ms]\n", sec * 1000.0 + nsec / 1e6);
    }

    (void)close(fd);
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 2 && strcmp(argv[1], "--http-ping") == 0) {
        const char* host = NULL;
        const char* path = NULL;
        if (argc >= 3)
            host = argv[2];
        if (argc >= 4)
            path = argv[3];
        return do_http_ping(host, path);
    }

    while (1) {
        printf("Select an action:\n");
        printf("  0) Exit\n");
        printf("  1) Read %s and print\n", README_PATH);
        printf("  2) Write to %s\n", README_PATH);
        printf("  3) HTTP ping (via parent VM tunnel on 127.0.0.1:%d)\n", HTTP_TUNNEL_PORT);
        printf("> ");
        fflush(stdout);

        char choice[32];
        if (!fgets(choice, sizeof(choice), stdin)) {
            fprintf(stderr, "No input\n");
            return 1;
        }
        strip_newline(choice);

        if (!strcmp(choice, "0")) {
            printf("Bye.\n");
            return 0;
        }

        if (!strcmp(choice, "1")) {
            int ret = do_read();
            if (ret)
                return ret;
            printf("\n");
            continue;
        }

        if (!strcmp(choice, "2")) {
            int ret = do_write();
            if (ret)
                return ret;
            printf("\n");
            continue;
        }

        if (!strcmp(choice, "3")) {
            printf("Host header (default: %s): ", HTTP_PING_DEFAULT_HOST);
            fflush(stdout);
            char host[1024];
            if (!fgets(host, sizeof(host), stdin)) {
                fprintf(stderr, "No input\n");
                return 1;
            }
            strip_newline(host);

            printf("Path (default: %s): ", HTTP_PING_DEFAULT_PATH);
            fflush(stdout);
            char path[1024];
            if (!fgets(path, sizeof(path), stdin)) {
                fprintf(stderr, "No input\n");
                return 1;
            }
            strip_newline(path);

            int ret = do_http_ping(host, path);
            if (ret)
                return ret;
            printf("\n");
            continue;
        }

        fprintf(stderr, "Unknown choice: '%s'\n\n", choice);
    }
}
