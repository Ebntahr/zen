/* A plain POSIX C program. Build on a host with the Zen SDK:
 *     zig cc -target riscv64-linux-musl -static -O2 hello.c -o hello
 * or inside Zen OS:
 *     cc hello.c -o hello && ./hello
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/utsname.h>
#include <dirent.h>

int main(int argc, char **argv) {
    struct utsname u;
    if (uname(&u) == 0)
        printf("Hello from C on %s %s (%s)!\n", u.sysname, u.release, u.machine);

    printf("pid %d, uid %d, cwd %s\n", (int)getpid(), (int)getuid(), getcwd(NULL, 0));

    /* Everything is a URL: list the process table through the sys: scheme. */
    DIR *d = opendir(argc > 1 ? argv[1] : "sys:proc");
    if (d) {
        struct dirent *e;
        int n = 0;
        while ((e = readdir(d)) != NULL) n++;
        closedir(d);
        printf("%d entries in %s\n", n, argc > 1 ? argv[1] : "sys:proc");
    }

    char *buf = malloc(64);
    strcpy(buf, "malloc works");
    puts(buf);
    free(buf);
    return 0;
}
