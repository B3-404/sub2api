#!/bin/sh
# =============================================================================
# init-letsencrypt.sh — one-time HTTPS bootstrap for the Sub2API nginx overlay
# =============================================================================
# Solves the certbot/nginx chicken-and-egg problem:
#   nginx won't start without a certificate, but certbot needs nginx running to
#   answer the ACME HTTP-01 challenge. So we:
#     1. create a throwaway self-signed cert (lets nginx start)
#     2. start nginx (serves the /.well-known/acme-challenge/ path)
#     3. delete the throwaway cert
#     4. request the real Let's Encrypt cert via the webroot challenge
#     5. reload nginx and bring the whole stack up
#
# Usage (run from the deploy/ directory):
#   DOMAIN=api.example.com CERTBOT_EMAIL=you@example.com ./nginx/init-letsencrypt.sh
#
# Or set DOMAIN / CERTBOT_EMAIL in .env, then just: ./nginx/init-letsencrypt.sh
#
# Environment overrides:
#   STAGING=1          use Let's Encrypt staging (avoid rate limits while testing)
#   RSA_KEY_SIZE=4096  certificate key size
#   BASE_COMPOSE=...   base compose file (default: docker-compose.local.yml)
# =============================================================================
set -eu

# Run from deploy/ regardless of where the script was invoked.
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# Load .env if present (fills DOMAIN / CERTBOT_EMAIL / TZ / etc.).
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

DOMAIN="${DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
STAGING="${STAGING:-0}"
RSA_KEY_SIZE="${RSA_KEY_SIZE:-4096}"
BASE_COMPOSE="${BASE_COMPOSE:-docker-compose.local.yml}"
NGINX_COMPOSE="docker-compose.nginx.yml"

: "${DOMAIN:?Set DOMAIN, e.g. DOMAIN=api.example.com ./nginx/init-letsencrypt.sh}"
: "${CERTBOT_EMAIL:?Set CERTBOT_EMAIL, e.g. CERTBOT_EMAIL=you@example.com ./nginx/init-letsencrypt.sh}"

export DOMAIN

compose() { docker compose -f "$BASE_COMPOSE" -f "$NGINX_COMPOSE" "$@"; }

cert_path="/etc/letsencrypt/live/$DOMAIN"

echo "### 1/5 Creating a temporary self-signed certificate for ${DOMAIN} ..."
compose run --rm --entrypoint sh certbot -c \
    "mkdir -p '$cert_path' && \
     openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
       -keyout '$cert_path/privkey.pem' \
       -out    '$cert_path/fullchain.pem' \
       -subj '/CN=localhost'"

echo "### 2/5 Starting nginx (to answer the ACME challenge) ..."
compose up -d nginx

echo "### 3/5 Removing the temporary certificate ..."
compose run --rm --entrypoint sh certbot -c \
    "rm -rf '/etc/letsencrypt/live/$DOMAIN' \
            '/etc/letsencrypt/archive/$DOMAIN' \
            '/etc/letsencrypt/renewal/$DOMAIN.conf'"

echo "### 4/5 Requesting the Let's Encrypt certificate for ${DOMAIN} ..."
staging_arg=""
[ "$STAGING" != "0" ] && staging_arg="--staging"

# shellcheck disable=SC2086
compose run --rm --entrypoint certbot certbot certonly \
    --webroot -w /var/www/certbot \
    $staging_arg \
    --email "$CERTBOT_EMAIL" \
    -d "$DOMAIN" \
    --rsa-key-size "$RSA_KEY_SIZE" \
    --agree-tos --no-eff-email --non-interactive --force-renewal

echo "### 5/5 Reloading nginx and bringing up the full stack ..."
compose exec nginx nginx -s reload
compose up -d

cat <<EOF

-----------------------------------------------------------------------------
 HTTPS is ready:  https://${DOMAIN}
-----------------------------------------------------------------------------
 Verify:   curl -I https://${DOMAIN}/health
 Logs:     docker compose -f ${BASE_COMPOSE} -f ${NGINX_COMPOSE} logs -f nginx
 Renewal:  automatic — the certbot container renews near expiry and nginx
           reloads every 6h to pick up the new certificate.

 NOTE: if you tested with STAGING=1, browsers will not trust the cert. Re-run
       without STAGING to obtain a real (trusted) certificate.
-----------------------------------------------------------------------------
EOF
