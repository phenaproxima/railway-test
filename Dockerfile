FROM docker.io/library/drupal:11-php8.4-apache

WORKDIR /opt/drupal

# The base image runs Composer as root during its own build. We need the
# same permission here.
ENV COMPOSER_ALLOW_SUPERUSER=1

# Install unzip and git for Composer.
RUN apt-get update
RUN apt-get install -y git unzip
RUN rm -r -f /var/lib/apt/lists/*

# Enable mod_headers so the security headers in apache.conf work.
RUN a2enmod headers

# Replace the base image's Composer files with the site's own, along with
# any patch files. The archive always contains these directories (even if
# empty), so these COPY instructions are safe.
COPY composer.* patches.* ./
COPY config/ ./config/
COPY content/ ./content/
COPY patches/ ./patches/

# Install the site's dependencies. Because we have a lock file, this
# installs exactly what the lock file says, adding or removing packages
# as needed to match. The base image's Drupal core stays if the versions
# are compatible; otherwise Composer replaces it.
RUN composer install --no-dev --no-interaction --prefer-dist

# Add Drush for deploy, install, and cron commands. The site might not
# have Drush in its own composer.json (it may be in require-dev only),
# so we add it here. If it's already present, Composer keeps the
# existing version.
RUN composer require --no-interaction --update-no-dev drush/drush

# Add Drupal-specific PHP settings.
RUN cat <<'EOF' > /usr/local/etc/php/conf.d/drupal.ini
; Drupal recommends at least 256M for sites with many modules.
memory_limit = 512M

; Give long operations enough time to finish.
max_execution_time = 300

; Allow reasonably large file uploads.
upload_max_filesize = 64M
post_max_size = 64M

; Errors should be logged, not shown to visitors.
display_errors = Off
display_startup_errors = Off
log_errors = On

; Send PHP errors to stderr, which Docker captures as container logs.
error_log = /dev/stderr

; Use UTC everywhere. The site's display timezone is set by Drupal.
date.timezone = UTC

; Drupal has many files. A longer TTL reduces filesystem lookups.
realpath_cache_ttl = 600
EOF

# Add basic security and compression headers that every site should have.
RUN cat <<'EOF' > /etc/apache2/conf-enabled/drupal.conf
# Prevent browsers from guessing the content type.
Header always set X-Content-Type-Options "nosniff"

# Only send the origin (not the full URL) as the referrer when navigating
# to a different site.
Header always set Referrer-Policy "strict-origin-when-cross-origin"

# Compress text-based responses. Binary files are already compressed.
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/plain text/css
  AddOutputFilterByType DEFLATE text/xml application/xml application/xhtml+xml
  AddOutputFilterByType DEFLATE application/javascript text/javascript application/json
  AddOutputFilterByType DEFLATE image/svg+xml
</IfModule>
EOF

# Create `settings.php` by adding Docker-specific stuff to default settings.
RUN <<'SHELL'
{
  cat web/sites/default/default.settings.php
  cat <<'EOF'
// If DRUPAL_HASH_SALT is not set, Drupal falls back to whatever hash
// salt is in the main settings.php (which is fine for local demos).
$hash_salt = getenv('DRUPAL_HASH_SALT');
if ($hash_salt) {
  $settings['hash_salt'] = $hash_salt;
}

// If a DATABASE_URL environment variable is not set, fall back to an inline
// SQLite database for demos and testing. Standard Postgres URLs use the
// "postgres://" or "postgresql://" scheme, but Drupal's driver is called "pgsql".
use Drupal\Core\Database\Database;
$db_url = preg_replace('|^postgres(ql)?://|', 'pgsql://', getenv('DATABASE_URL'));
$databases['default']['default'] = Database::convertDbUrlToConnectionInfo($db_url);

$settings['config_sync_directory'] = getenv('DRUPAL_CONFIG_SYNC_DIRECTORY');

// Drupal rejects requests whose Host header doesn't match a known pattern.
// This prevents certain HTTP host header attacks.
// @see https://www.drupal.org/docs/getting-started/installing-drupal/trusted-host-settings
//
// Localhost is always trusted (for health checks, local development, and
// SSH console access).
$settings['trusted_host_patterns'] = [
  '^localhost$',
];
// To trust additional domains (your own custom domains, for example), set
// the DRUPAL_TRUSTED_HOSTS environment variable to a comma-separated list
// of hostnames:
//
//   DRUPAL_TRUSTED_HOSTS=example.com,www.example.com
//
// Each hostname is escaped and turned into an exact-match regex pattern.
$trusted_hosts = getenv('DRUPAL_TRUSTED_HOSTS');
if ($trusted_hosts) {
  foreach (explode(',', $trusted_hosts) as $host) {
    $host = trim($host);
    if ($host) {
      $settings['trusted_host_patterns'][] = '^' . preg_quote($host, '/') . '$';
    }
  }
}

// When this container runs behind a load balancer or reverse proxy, the
// proxy terminates TLS and forwards plain HTTP to the container. Drupal
// needs to know about this so it can:
//   - Generate https:// URLs (not http://)
//   - Read the real visitor IP from the X-Forwarded-For header
//
// We trust whatever IP address the request came from (REMOTE_ADDR),
// because in a containerized environment the proxy is the only thing
// that can talk to the container directly.
//
// Most hosting platforms that sit behind a proxy should set this.
if (getenv('DRUPAL_REVERSE_PROXY')) {
  $settings['reverse_proxy'] = TRUE;
  $settings['reverse_proxy_addresses'] = [$_SERVER['REMOTE_ADDR']];
}

// Uploaded files are stored on a volume mount at the standard Drupal files
// path. The volume should be mounted at web/sites/default/files when running
// the container.
$settings['file_temp_path'] = '/tmp';

// If your site uses the s3fs module to store uploaded files in an
// S3-compatible bucket, these settings tell Drupal to use S3 for the public://
// file system. The module's own config (bucket name, region, endpoint, etc.) is
// already in your exported config, so you don't need to set those values here.
//
// Make sure to set the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
// environment variables on your container -- the AWS SDK reads them
// automatically.
//
// These settings are ignored if s3fs is not installed.
$settings['s3fs.use_s3_for_public'] = TRUE;
$settings['s3fs.use_s3_for_private'] = TRUE;
EOF
} > web/sites/default/settings.php
SHELL

# Switch Apache from port 80 to 8080. Port 8080 is the standard for
# containers behind a reverse proxy and doesn't require root to bind.
RUN echo "Listen 8080" > /etc/apache2/ports.conf

# Make the default VirtualHost listen on a wildcard port.
RUN cat <<'EOF' > /etc/apache2/sites-enabled/000-default.conf
<VirtualHost *:*>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Ensure the default site directory is set up properly and writable during
# installation, but settings files themselves are read-only to avoid a
# warning from Drupal. The files directory is expected to be a volume mount;
# create it so Drupal doesn't complain if nothing is mounted yet.
RUN mkdir -p web/sites/default/files
RUN chown www-data:www-data web/sites/default/files
RUN chmod 755 web/sites/default

# Drush and other CLI tools live in vendor/bin.
ENV PATH=${PATH}:/opt/drupal/vendor/bin

# By default, run in a SQLite database.
ENV DATABASE_URL=sqlite://localhost/sites/default/files/.ht.sqlite

# Where we copied configuration, relative to the web root.
ENV DRUPAL_CONFIG_SYNC_DIRECTORY=../config

# Apache listens on port 8080 (set in ports.conf).
EXPOSE 8080

# Write the entry point and make it executable.
RUN cat <<'EOF' > /usr/local/bin/start.sh
#!/usr/bin/env bash
# Commands:
#
#   docker run mysite            Start Apache (the default). Installs Drupal
#                                automatically on first run.
#   docker run mysite release    Deploy: run database updates and config import.
#   docker run mysite bash       Run an arbitrary command.

set -euo pipefail

# Returns 0 if Drupal is installed and can bootstrap.
is_installed() {
  drush status --field=bootstrap 2>/dev/null | grep -q "Successful"
}

case "${1:-}" in
  check)
    is_installed
    ;;

  release)
    # Run database updates and import config. If Drupal isn't installed yet
    # (e.g., the very first deploy), skip gracefully. It will be installed
    # automatically when the container starts.
    if is_installed; then
      drush deploy
    fi
    ;;

  ""|apache2-foreground)
    # No arguments or the default CMD: install if needed, and start Apache.
    mkdir -p web/sites/default/files

    # If Drupal isn't installed yet, install it and import content.
    if ! is_installed; then
      drush site:install --existing-config --yes --db-url="$DATABASE_URL"
      drush content:import ../content --yes

      # Lock down settings.php now that install is done.
      chmod 444 web/sites/default/settings.php
    fi

    # Make sure the files directory is writable.
    chown -R www-data:www-data web/sites/default/files

    # Railway, for whatever reason, enables mpm_event, which breaks Apache.
    # PHP needs mpm_prefork, which is already enabled. We also disable
    # mpm_worker for good measure.
    if [ -n "${RAILWAY_SERVICE_ID:-}" ]; then
      a2dismod mpm_event mpm_worker || true
    fi
    exec apache2-foreground
    ;;

  *)
    # Anything else: run it directly.
    exec "$@"
    ;;
esac
EOF
RUN chmod +x /usr/local/bin/start.sh

ENTRYPOINT ["start.sh"]
CMD ["apache2-foreground"]
