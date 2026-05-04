FROM golang:1.25-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY main.go ./

# Build a static binary (modernc.org/sqlite is pure Go, no CGO needed)
RUN CGO_ENABLED=0 go build -o potluck main.go

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

# Copy the binary from builder
COPY --from=builder /app/potluck .

# Data directory for the SQLite database (mount a volume here)
RUN mkdir -p /app/data
WORKDIR /app/data

# Expose port
EXPOSE 8080

# Run the application
CMD ["/app/potluck"]
