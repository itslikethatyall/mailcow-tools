#!/usr/bin/env bash
#
# 20260209 - Wrapper restore script for mailcow restore domain or mailbox.
# Find my Mailcow tools here:
# https://github.com/itslikethatyall/mailcow-tools/
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335 USA
#

#
# Detects whether the target is a domain or mailbox address
# and calls the appropriate restore script.
#

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <backup_location> <domain_or_mailbox> [options]"
  echo ""
  echo "Automatically detects whether to restore a domain or individual mailbox."
  echo ""
  echo "Examples:"
  echo "  $0 /backups/2026-02-06/mailcow-2026-02-06-21-17-15 example.com"
  echo "  $0 /backups/2026-02-06/mailcow-2026-02-06-21-17-15 mailbox@example.com"
  echo ""
  echo "All additional flags are passed through to the underlying script."
  echo "Run restore_domain.sh or restore_mailbox.sh with no arguments to see their options."
  exit 1
fi

TARGET="$2"

if [[ "${TARGET}" == *"@"* ]]; then
  if [[ ! -x "${SCRIPT_DIR}/restore_mailbox.sh" ]]; then
    echo "ERROR: restore_mailbox.sh not found or not executable in ${SCRIPT_DIR}"
    exit 1
  fi
  echo "Detected mailbox address: ${TARGET}"
  echo "Calling restore_mailbox.sh..."
  echo
  exec "${SCRIPT_DIR}/restore_mailbox.sh" "$@"
else
  if [[ ! -x "${SCRIPT_DIR}/restore_domain.sh" ]]; then
    echo "ERROR: restore_domain.sh not found or not executable in ${SCRIPT_DIR}"
    exit 1
  fi
  echo "Detected domain: ${TARGET}"
  echo "Calling restore_domain.sh..."
  echo
  exec "${SCRIPT_DIR}/restore_domain.sh" "$@"
fi
