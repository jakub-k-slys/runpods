# Tailscale static binaries, consumed by the images as the `tailscale` build
# context (see docker-bake.hcl). Version and checksum are pinned in the bake file.
FROM alpine:3.22

ARG TAILSCALE_VERSION
ARG TAILSCALE_SHA256

RUN wget -q -O /tmp/tailscale.tgz \
        "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz" && \
    echo "${TAILSCALE_SHA256}  /tmp/tailscale.tgz" | sha256sum -c - && \
    tar xzf /tmp/tailscale.tgz -C /tmp && \
    mv "/tmp/tailscale_${TAILSCALE_VERSION}_amd64/tailscale" \
       "/tmp/tailscale_${TAILSCALE_VERSION}_amd64/tailscaled" /usr/local/bin/ && \
    rm -rf /tmp/tailscale*
