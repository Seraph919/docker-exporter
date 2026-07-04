FROM alpine:latest
RUN apk add --no-cache curl jq busybox-extras bash
COPY script.sh /
COPY ./.httpd.conf /tmp/metrics_www/.httpd.conf
RUN chmod +x /script.sh
ENTRYPOINT ["bash", "/script.sh"]