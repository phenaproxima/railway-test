#!/usr/bin/env bash
# ==========================================================================
# Entrypoint for Drupal CMS Docker containers.
# ==========================================================================
#
# Commands:
#
#   docker run mysite            Start Apache (the default). Installs Drupal
#                                automatically on first run.
#   docker run mysite release    Deploy: run database updates and config import.
#   docker run mysite bash       Run an arbitrary command.
#
# ==========================================================================

set -euo pipefail

# Returns 0 if Drupal is installed and can bootstrap.
is_installed() {
  drush status --field=bootstrap 2>/dev/null | grep -q "Successful"
}

case "${1:-}" in
  release)
    # Run database updates and import config. Used by Fly.io's
    # release_command (see fly.toml), but works anywhere.
    #
    # If Drupal isn't installed yet (e.g., the very first deploy), skip
    # gracefully. It will be installed automatically when the container starts.
    if is_installed; then
      drush deploy
    else
      echo "Drupal is not installed yet. Skipping release."
    fi
    ;;

  ""|apache2-foreground)
    # No arguments or the default CMD: install if needed, and start Apache.
    mkdir -p /opt/drupal/web/sites/default/files

    # If Drupal isn't installed yet, install it and import content.
    if ! is_installed; then
      drush site:install --existing-config --yes
      drush content:import /opt/drupal/content --yes

      # Lock down settings.php now that install is done.
      chmod 444 /opt/drupal/web/sites/default/settings.php
    fi

    # Make sure the files directory is writable.
    chown -R www-data:www-data /opt/drupal/web/sites/default/files

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
