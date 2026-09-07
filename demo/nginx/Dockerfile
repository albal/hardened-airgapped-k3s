# The "Node N" demo page. Built on the connected build host, shipped as a tarball,
# and pushed into Harbor by the airgapped installer so the cluster has to pull it
# from the private registry.
ARG BASE_IMAGE=nginx:1.31.5-alpine
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="k3s-node-demo" \
      org.opencontainers.image.description="Per-node nginx page for the airgapped k3s demo"

COPY nginx-default.conf /etc/nginx/conf.d/default.conf
COPY 20-render-node-page.sh /docker-entrypoint.d/20-render-node-page.sh

# Run unprivileged: uid 101 is the 'nginx' user in the official alpine image.
# The pid file and everything the entrypoint writes must live somewhere that
# uid 101 can write to.
RUN chmod +x /docker-entrypoint.d/20-render-node-page.sh \
 && sed -i 's|^pid .*|pid /tmp/nginx.pid;|; /^user /d' /etc/nginx/nginx.conf \
 && chown -R 101:101 /usr/share/nginx/html /var/cache/nginx /etc/nginx/conf.d

USER 101
EXPOSE 8080
