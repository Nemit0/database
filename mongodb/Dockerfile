FROM mongo:8.0

LABEL maintainer="aspalt8@gmail.com" \
      description="Custom MongoDB 7 image with optional init scripts."

# Optional: Copy any initialization scripts.
# Comment this line out if you do not need seeding.
COPY ./initdb /docker-entrypoint-initdb.d

# Expose the default MongoDB port.
EXPOSE 27017
