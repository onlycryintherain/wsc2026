FROM public.ecr.aws/docker/library/alpine:3.20 AS certs
RUN apk add --no-cache ca-certificates

FROM alpine:3.20
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]