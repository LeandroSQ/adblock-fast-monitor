# syntax=docker/dockerfile:1
# OpenWrt 25.12.6-like userland for host tests: BusyBox (OpenWrt defaults and
# patches only), ucode + modules, uci, ubus/ubusd, jshn, jsonfilter. The final
# image contains nothing else, so a missing applet (stat, timeout, ...) fails
# exactly as it does on a stock router. Built by scripts/build-host-ucode.sh.
FROM alpine:3.21 AS build
RUN apk add --no-cache build-base cmake curl linux-headers perl patch bzip2 \
	json-c-dev zlib-dev libmd-dev bash
COPY pins.env busybox-defaults.awk build-userland.sh /build/
RUN sh /build/build-userland.sh

FROM scratch
COPY --from=build /rootfs/ /
ENV PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
WORKDIR /root
CMD ["/bin/ash"]
