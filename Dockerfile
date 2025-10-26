# Multi-stage Dockerfile for Den Shell
# Produces minimal Alpine-based image with Den Shell

# Stage 1: Download binary
FROM alpine:latest as downloader

ARG TARGETARCH
ARG VERSION=0.1.0

WORKDIR /tmp

# Install dependencies
RUN apk add --no-cache curl tar

# Download appropriate binary based on architecture
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      ARCH="linux-arm64"; \
    else \
      ARCH="linux-x64"; \
    fi && \
    curl -fsSL "https://github.com/stacksjs/den/releases/download/v${VERSION}/den-${VERSION}-${ARCH}.tar.gz" \
      -o den.tar.gz && \
    tar -xzf den.tar.gz

# Stage 2: Final minimal image
FROM alpine:latest

LABEL maintainer="Stacks.js <support@stacksjs.org>"
LABEL description="Den Shell - Modern POSIX shell written in Zig"
LABEL version="0.1.0"

# Install runtime dependencies
RUN apk add --no-cache \
    libgcc \
    libstdc++ \
    ca-certificates

# Copy den binary from downloader stage
COPY --from=downloader /tmp/den/den /usr/local/bin/den

# Create non-root user
RUN addgroup -g 1000 den && \
    adduser -D -u 1000 -G den -s /usr/local/bin/den den

# Add den to /etc/shells
RUN echo "/usr/local/bin/den" >> /etc/shells

# Set up home directory
WORKDIR /home/den
USER den

# Set den as default shell
SHELL ["/usr/local/bin/den", "-c"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=1 \
  CMD den version || exit 1

# Default command
CMD ["/usr/local/bin/den"]
