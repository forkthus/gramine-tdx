#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define README_PATH "/home/ubuntu/readme"

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

int main(void) {
    while (1) {
        printf("Select an action:\n");
        printf("  0) Exit\n");
        printf("  1) Read %s and print\n", README_PATH);
        printf("  2) Write to %s\n", README_PATH);
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

        fprintf(stderr, "Unknown choice: '%s'\n\n", choice);
    }
}
