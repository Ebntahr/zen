# Zen OS, hosted: the real Zen user space (window server, launchd, apps,
# shell, coreutils) on the Linux kernel of a container. The desktop is shown
# in a browser.
#
#   zig build hosted                       # (add -Dhosted-arch=aarch64 on Apple Silicon)
#   docker build -t zen-os zig-out/hosted
#   docker run --rm --hostname zen-os -p 127.0.0.1:6080:6080 -p 127.0.0.1:5900:5900 zen-os
#   open http://localhost:6080             # user "zen", password "zen"
#
# Every Zen program is a static executable, so the image needs nothing else.
FROM scratch
COPY root/ /
ENV ZEN_HOSTED=/run/zen \
    ZEN_HOSTED_BIND=0.0.0.0 \
    ZEN_HOSTED_SIZE=1280x800 \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
EXPOSE 6080 5900
STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/init"]
