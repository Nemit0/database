# mysql/Dockerfile
# Builds a thin wrapper around the official MySQL 8 image.
# Copy SQL or shell files into ./mysql/initdb/ to seed or configure the DB.
# The base image handles all server startup logic.

FROM mysql:8.3

LABEL maintainer="aspalt8@gmail.com" \
      description="Custom MySQL 8 image with optional init scripts."

# Keep container time in sync with host (optional).
ARG TZ=Asia/Seoul
ENV TZ=${TZ}

# Optional: seed database on first run.
COPY ./initdb /docker-entrypoint-initdb.d

# Expose default MySQL port.
EXPOSE 3306
