# check=skip=InvalidDefaultArgInFrom
# ComfyUI pod: Runpod's official ComfyUI image + Tailscale.
#
# Only COPY steps on top of the base: no RUN, so the ~6 GB base never has to be
# unpacked in the builder. The base's start script has no pre/post-start hook,
# so the Tailscale wrapper becomes the entrypoint and execs the original /start.sh.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/local/bin/
COPY --from=scripts --chmod=755 ts-entrypoint.sh /usr/local/bin/ts-entrypoint

ENTRYPOINT ["/usr/local/bin/ts-entrypoint"]
CMD ["/start.sh"]
