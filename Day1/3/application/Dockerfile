FROM golang:alpine

WORKDIR /app

COPY book-linux-amd64_v1.0.1 book

EXPOSE 8080

RUN chmod +x book

CMD ["./book"]
