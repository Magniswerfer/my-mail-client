#!/bin/sh
# Self-signed localhost certificate for Mailpit's STARTTLS (test server only; not committed).
cd "$(dirname "$0")" && mkdir -p certs && [ -f certs/localhost.pem ] || \
  openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/localhost.key -out certs/localhost.pem \
    -days 3650 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
