FROM public.ecr.aws/docker/library/alpine:3.20
RUN apk add --no-cache ca-certificates libc6-compat
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
