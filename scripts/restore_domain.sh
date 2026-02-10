#!/usr/bin/env bash
#
# 20260209b - Domain restore script for mailcow
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
# Restore individual domain from mailcow backup
# Usage: ./restore_domain.sh <backup_location> <domain_name> [--force] [--confirm] [--forcemailcrypt]
# A pre-restore backup is always created before overwriting existing data.
#

# Validate arguments
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <backup_location> <domain_name> <flag>"
  echo ""
  echo "Example: $0 /backups/2026-02-06/mailcow-2026-02-06-21-17-15 example.com"
  echo ""
  echo "Flags:"
  echo "--force           Overwrite existing domain"
  echo "--confirm         Skip confirmations before restoring"
  echo "--forcemailcrypt  Proceed even if mail_crypt keys differ (mail may be unreadable)"
  exit 1
fi

BACKUP_LOCATION="${1}"
TARGET_DOMAIN="${2}"
FORCE=0
CONFIRM_RESTORE=0
FORCE_MAILCRYPT=0

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --confirm) CONFIRM_RESTORE=1 ;;
    --forcemailcrypt) FORCE_MAILCRYPT=1 ;;
  esac
  shift
done

# Get script directory and source configuration
MAILCOW_DIR="/opt/mailcow-dockerized"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
COMPOSE_FILE="${MAILCOW_DIR}/docker-compose.yml"
ENV_FILE="${MAILCOW_DIR}/.env"
LOCK_FILE="/tmp/restore_domain_${TARGET_DOMAIN}.lock"
PREBACKUP_DIR="${SCRIPT_DIR}/rundata/backups/domain_restores"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found"
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Environment file not found"
  exit 1
fi

# Validate backup location
if [[ ! -d "${BACKUP_LOCATION}" ]]; then
  echo "Backup location does not exist: ${BACKUP_LOCATION}"
  exit 1
fi

# Create temporary working directory
TEMP_DIR=$(mktemp -d)
chmod 755 "${TEMP_DIR}"

# Helper Functions

function get_archive_info() {
  local backup_name="$1"
  local location="$2"

  if [[ -f "${location}/${backup_name}.tar.zst" ]]; then
    echo "${backup_name}.tar.zst|zstd -d"
  elif [[ -f "${location}/${backup_name}.tar.gz" ]]; then
    echo "${backup_name}.tar.gz|pigz -d"
  else
    echo ""
  fi
}

function cleanup() {
  rm -f "${LOCK_FILE}"
  rm -rf "${TEMP_DIR}"
}

function error_exit() {
  echo "Error: $1" >&2
  echo ""
  echo "Restore failed. Your mailcow data is intact and unchanged."
  echo "Check the error above and try again."
  cleanup
  exit 1
}

trap cleanup EXIT

# Detect Borg/borgmatic backups (not supported by this script)
if [[ -f "${BACKUP_LOCATION}/config" && -d "${BACKUP_LOCATION}/data" ]]; then
  echo "ERROR: ${BACKUP_LOCATION} appears to be a Borg backup repository."
  echo ""
  echo "This script currently only supports native mailcow backups"
  echo "created by mailcow's built-in backup (backup_and_restore.sh)."
  echo ""
  error_exit "Borg backups are not supported by this script"
fi

if [[ ! -f "${BACKUP_LOCATION}/mailcow.conf" ]]; then
  echo "No mailcow.conf found in backup location. Invalid backup?"
  exit 1
fi

echo "Using ${BACKUP_LOCATION} as backup/restore location."
echo "Using temporary directory: ${TEMP_DIR}"
echo

source ${MAILCOW_DIR}/mailcow.conf

if [[ -z ${COMPOSE_PROJECT_NAME} ]]; then
  echo "Could not determine compose project name"
  exit 1
else
  echo "Found project name ${COMPOSE_PROJECT_NAME}"
  CMPS_PRJ=$(echo ${COMPOSE_PROJECT_NAME} | tr -cd "[0-9A-Za-z-_]")
fi

if grep --help 2>&1 | head -n 1 | grep -q -i "busybox"; then
  >&2 echo -e "\e[31mBusyBox grep detected on local system, please install GNU grep\e[0m"
  exit 1
fi

# Determine the SQL image from docker-compose.yml (same image mailcow uses)
SQLIMAGE=$(grep -iEo '(mysql|mariadb)\:.+' ${COMPOSE_FILE})
if [[ -z "${SQLIMAGE}" ]]; then
  echo "Could not determine SQL image version from docker-compose.yml, defaulting to mariadb:10.11"
  SQLIMAGE="mariadb:10.11"
else
  echo "Using SQL image: ${SQLIMAGE}"
fi

# Check for concurrent restores of the same domain

if [[ -f "${LOCK_FILE}" ]]; then
  LOCK_PID=$(cat "${LOCK_FILE}")
  if kill -0 "${LOCK_PID}" 2>/dev/null; then
    error_exit "Another restore for ${TARGET_DOMAIN} is already in progress (PID: ${LOCK_PID})"
  fi
  rm -f "${LOCK_FILE}"
fi

echo $$ > "${LOCK_FILE}"

# Check for docker binary
for bin in docker; do
  if [[ -z $(which ${bin}) ]]; then
    error_exit "Cannot find ${bin} in local PATH"
  fi
done

# Get docker-compose command
if [ "${DOCKER_COMPOSE_VERSION}" == "native" ]; then
  COMPOSE_COMMAND="docker compose"
elif [ "${DOCKER_COMPOSE_VERSION}" == "standalone" ]; then
  COMPOSE_COMMAND="docker-compose"
else
  error_exit "Can not read DOCKER_COMPOSE_VERSION variable from mailcow.conf! Is your mailcow up to date?"
fi

echo "Restoring domain: ${TARGET_DOMAIN}"
echo "From backup: ${BACKUP_LOCATION}"
echo

# Step 1: Validate backup integrity

echo "Step 1: Validating backup integrity..."

# Check if backup has required files
if [[ ! -d "${BACKUP_LOCATION}/mysql" && -z $(find "${BACKUP_LOCATION}" -maxdepth 1 -name "backup_mariadb*" 2>/dev/null) ]]; then
  error_exit "No MySQL/MariaDB backup found in backup location"
fi

# Validate backup.conf values
if ! grep -q "^DBNAME=" "${BACKUP_LOCATION}/mailcow.conf"; then
  error_exit "Invalid mailcow.conf in backup - missing database configuration"
fi

echo "Backup validation passed"
echo

# Step 2: Preparing backup database

echo "Step 2: Preparing backup database..."

# Check if backup database is a directory or archive
if [[ -d "${BACKUP_LOCATION}/mysql" ]]; then
  echo "Found mysql directory backup, using it directly..."
  BACKUP_MYSQL_DIR="${BACKUP_LOCATION}/mysql"
else
  echo "Backup archive detected, will extract in container..."
  BACKUP_MYSQL_DIR=""
fi

echo

# Step 3: Extract domain-specific data from backup database

echo "Step 3: Extracting domain data from backup..."

# Write the SQL extraction query to a temp file on the host
# Column names match the mailcow schema from data/web/inc/init_db.inc.php

cat > "${TEMP_DIR}/domain_query.sql" << 'DOMAINEOF'
SET sql_mode='';
SET FOREIGN_KEY_CHECKS=0;
USE mailcow;

-- Domain configuration
-- Schema: domain, description, aliases, mailboxes, defquota, maxquota, quota, relayhost, backupmx, gal, relay_all_recipients, relay_unknown_only, created, modified, active
SELECT CONCAT(
  'INSERT INTO domain (domain, description, aliases, mailboxes, defquota, maxquota, quota, relayhost, backupmx, gal, relay_all_recipients, relay_unknown_only, created, modified, active) VALUES (',
  QUOTE(domain), ',',
  QUOTE(description), ',',
  QUOTE(aliases), ',',
  QUOTE(mailboxes), ',',
  QUOTE(defquota), ',',
  QUOTE(maxquota), ',',
  QUOTE(quota), ',',
  QUOTE(relayhost), ',',
  QUOTE(backupmx), ',',
  QUOTE(gal), ',',
  QUOTE(relay_all_recipients), ',',
  QUOTE(relay_unknown_only), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(active),
  ') ON DUPLICATE KEY UPDATE description=VALUES(description), aliases=VALUES(aliases), mailboxes=VALUES(mailboxes), defquota=VALUES(defquota), maxquota=VALUES(maxquota), quota=VALUES(quota), relayhost=VALUES(relayhost), backupmx=VALUES(backupmx), gal=VALUES(gal), relay_all_recipients=VALUES(relay_all_recipients), relay_unknown_only=VALUES(relay_unknown_only), active=VALUES(active);'
) AS sql_stmt
FROM domain WHERE domain = '__TARGET_DOMAIN__';

-- Mailboxes for this domain
-- Schema: username, password, name, description, mailbox_path_prefix, quota, local_part, domain, attributes, custom_attributes, kind, multiple_bookings, authsource, created, modified, active
SELECT CONCAT(
  'INSERT INTO mailbox (username, password, name, description, mailbox_path_prefix, quota, local_part, domain, attributes, custom_attributes, kind, multiple_bookings, authsource, created, modified, active) VALUES (',
  QUOTE(username), ',',
  QUOTE(password), ',',
  QUOTE(name), ',',
  QUOTE(description), ',',
  QUOTE(mailbox_path_prefix), ',',
  QUOTE(quota), ',',
  QUOTE(local_part), ',',
  QUOTE(domain), ',',
  QUOTE(attributes), ',',
  QUOTE(custom_attributes), ',',
  QUOTE(kind), ',',
  QUOTE(multiple_bookings), ',',
  QUOTE(authsource), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(active),
  ') ON DUPLICATE KEY UPDATE password=VALUES(password), name=VALUES(name), description=VALUES(description), mailbox_path_prefix=VALUES(mailbox_path_prefix), quota=VALUES(quota), attributes=VALUES(attributes), custom_attributes=VALUES(custom_attributes), kind=VALUES(kind), multiple_bookings=VALUES(multiple_bookings), authsource=VALUES(authsource), active=VALUES(active);'
) AS sql_stmt
FROM mailbox WHERE domain = '__TARGET_DOMAIN__';

-- Aliases for this domain
-- Schema: id, address, goto, domain, created, modified, private_comment, public_comment, sogo_visible, internal, sender_allowed, active
SELECT CONCAT(
  'INSERT INTO alias (address, goto, domain, created, modified, private_comment, public_comment, sogo_visible, `internal`, sender_allowed, active) VALUES (',
  QUOTE(address), ',',
  QUOTE(goto), ',',
  QUOTE(domain), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(private_comment), ',',
  QUOTE(public_comment), ',',
  QUOTE(sogo_visible), ',',
  QUOTE(`internal`), ',',
  QUOTE(sender_allowed), ',',
  QUOTE(active),
  ') ON DUPLICATE KEY UPDATE goto=VALUES(goto), modified=VALUES(modified), private_comment=VALUES(private_comment), public_comment=VALUES(public_comment), sogo_visible=VALUES(sogo_visible), sender_allowed=VALUES(sender_allowed), active=VALUES(active);'
) AS sql_stmt
FROM alias WHERE domain = '__TARGET_DOMAIN__';

-- Alias domains (domain aliases)
-- Schema: alias_domain, target_domain, created, modified, active
SELECT CONCAT(
  'INSERT INTO alias_domain (alias_domain, target_domain, created, modified, active) VALUES (',
  QUOTE(alias_domain), ',',
  QUOTE(target_domain), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(active),
  ') ON DUPLICATE KEY UPDATE target_domain=VALUES(target_domain), active=VALUES(active);'
) AS sql_stmt
FROM alias_domain WHERE target_domain = '__TARGET_DOMAIN__' OR alias_domain = '__TARGET_DOMAIN__';

-- Sender ACL entries for mailboxes in this domain
-- Schema: id, logged_in_as, send_as, external
SELECT CONCAT(
  'INSERT INTO sender_acl (logged_in_as, send_as, external) VALUES (',
  QUOTE(logged_in_as), ',',
  QUOTE(send_as), ',',
  QUOTE(external),
  ');'
) AS sql_stmt
FROM sender_acl WHERE logged_in_as LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- TLS policy overrides for this domain
-- Schema: id, dest, policy, parameters, created, modified, active
SELECT CONCAT(
  'INSERT INTO tls_policy_override (dest, policy, parameters, created, modified, active) VALUES (',
  QUOTE(dest), ',',
  QUOTE(policy), ',',
  QUOTE(parameters), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(active),
  ') ON DUPLICATE KEY UPDATE policy=VALUES(policy), parameters=VALUES(parameters), active=VALUES(active);'
) AS sql_stmt
FROM tls_policy_override WHERE dest = '__TARGET_DOMAIN__';

-- BCC maps for this domain
-- Schema: id, local_dest, bcc_dest, domain, type, created, modified, active
SELECT CONCAT(
  'INSERT INTO bcc_maps (local_dest, bcc_dest, domain, type, created, modified, active) VALUES (',
  QUOTE(local_dest), ',',
  QUOTE(bcc_dest), ',',
  QUOTE(domain), ',',
  QUOTE(type), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(active),
  ');'
) AS sql_stmt
FROM bcc_maps WHERE domain = '__TARGET_DOMAIN__';

-- Domain-wide footer
-- Schema: domain, html, plain, mbox_exclude, alias_domain_exclude, skip_replies
SELECT CONCAT(
  'INSERT INTO domain_wide_footer (domain, html, plain, mbox_exclude, alias_domain_exclude, skip_replies) VALUES (',
  QUOTE(domain), ',',
  QUOTE(html), ',',
  QUOTE(plain), ',',
  QUOTE(mbox_exclude), ',',
  QUOTE(alias_domain_exclude), ',',
  QUOTE(skip_replies),
  ') ON DUPLICATE KEY UPDATE html=VALUES(html), plain=VALUES(plain), mbox_exclude=VALUES(mbox_exclude), alias_domain_exclude=VALUES(alias_domain_exclude), skip_replies=VALUES(skip_replies);'
) AS sql_stmt
FROM domain_wide_footer WHERE domain = '__TARGET_DOMAIN__';

-- Domain tags
SELECT CONCAT(
  'INSERT IGNORE INTO tags_domain (tag_name, domain) VALUES (',
  QUOTE(tag_name), ',',
  QUOTE(domain),
  ');'
) AS sql_stmt
FROM tags_domain WHERE domain = '__TARGET_DOMAIN__';

-- Mailbox tags for users in this domain
SELECT CONCAT(
  'INSERT IGNORE INTO tags_mailbox (tag_name, username) VALUES (',
  QUOTE(tag_name), ',',
  QUOTE(username),
  ');'
) AS sql_stmt
FROM tags_mailbox WHERE username LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- =====================================================================
-- SOGo: Calendar, Contacts, and User Preferences
-- =====================================================================

-- Generate SOGo cleanup DELETEs (clear existing data before restore to avoid c_folder_id conflicts)
-- Order matters: dependent tables first, then folder_info last
SELECT 'DELETE FROM sogo_store WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 LIKE ''%@__TARGET_DOMAIN__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_quick_appointment WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 LIKE ''%@__TARGET_DOMAIN__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_quick_contact WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 LIKE ''%@__TARGET_DOMAIN__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_acl WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 LIKE ''%@__TARGET_DOMAIN__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_alarms_folder WHERE c_uid LIKE ''%@__TARGET_DOMAIN__'';' AS sql_stmt;
SELECT 'DELETE FROM sogo_user_profile WHERE c_uid LIKE ''%@__TARGET_DOMAIN__'';' AS sql_stmt;
SELECT 'DELETE FROM sogo_folder_info WHERE c_path2 LIKE ''%@__TARGET_DOMAIN__'';' AS sql_stmt;

-- SOGo folder info (central folder registry - calendars, address books)
SELECT CONCAT(
  'INSERT INTO sogo_folder_info (c_folder_id, c_path, c_path1, c_path2, c_path3, c_path4, c_foldername, c_location, c_quick_location, c_acl_location, c_folder_type) VALUES (',
  QUOTE(c_folder_id), ',',
  QUOTE(c_path), ',',
  QUOTE(c_path1), ',',
  QUOTE(c_path2), ',',
  QUOTE(c_path3), ',',
  QUOTE(c_path4), ',',
  QUOTE(c_foldername), ',',
  QUOTE(c_location), ',',
  QUOTE(c_quick_location), ',',
  QUOTE(c_acl_location), ',',
  QUOTE(c_folder_type),
  ') ON DUPLICATE KEY UPDATE c_foldername=VALUES(c_foldername), c_location=VALUES(c_location), c_quick_location=VALUES(c_quick_location), c_acl_location=VALUES(c_acl_location), c_folder_type=VALUES(c_folder_type);'
) AS sql_stmt
FROM sogo_folder_info WHERE c_path2 LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- SOGo store (actual iCal/vCard data blobs)
SELECT CONCAT(
  'INSERT INTO sogo_store (c_folder_id, c_name, c_content, c_creationdate, c_lastmodified, c_version, c_deleted) VALUES (',
  QUOTE(s.c_folder_id), ',',
  QUOTE(s.c_name), ',',
  QUOTE(s.c_content), ',',
  QUOTE(s.c_creationdate), ',',
  QUOTE(s.c_lastmodified), ',',
  QUOTE(s.c_version), ',',
  QUOTE(s.c_deleted),
  ') ON DUPLICATE KEY UPDATE c_content=VALUES(c_content), c_lastmodified=VALUES(c_lastmodified), c_version=VALUES(c_version), c_deleted=VALUES(c_deleted);'
) AS sql_stmt
FROM sogo_store s
INNER JOIN sogo_folder_info f ON s.c_folder_id = f.c_folder_id
WHERE f.c_path2 LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- SOGo quick appointment cache (calendar event search/display data)
SELECT CONCAT(
  'INSERT INTO sogo_quick_appointment (c_folder_id, c_name, c_uid, c_startdate, c_enddate, c_cycleenddate, c_title, c_participants, c_isallday, c_iscycle, c_cycleinfo, c_classification, c_isopaque, c_status, c_priority, c_location, c_orgmail, c_partmails, c_partstates, c_category, c_sequence, c_component, c_nextalarm, c_description) VALUES (',
  QUOTE(qa.c_folder_id), ',',
  QUOTE(qa.c_name), ',',
  QUOTE(qa.c_uid), ',',
  QUOTE(qa.c_startdate), ',',
  QUOTE(qa.c_enddate), ',',
  QUOTE(qa.c_cycleenddate), ',',
  QUOTE(qa.c_title), ',',
  QUOTE(qa.c_participants), ',',
  QUOTE(qa.c_isallday), ',',
  QUOTE(qa.c_iscycle), ',',
  QUOTE(qa.c_cycleinfo), ',',
  QUOTE(qa.c_classification), ',',
  QUOTE(qa.c_isopaque), ',',
  QUOTE(qa.c_status), ',',
  QUOTE(qa.c_priority), ',',
  QUOTE(qa.c_location), ',',
  QUOTE(qa.c_orgmail), ',',
  QUOTE(qa.c_partmails), ',',
  QUOTE(qa.c_partstates), ',',
  QUOTE(qa.c_category), ',',
  QUOTE(qa.c_sequence), ',',
  QUOTE(qa.c_component), ',',
  QUOTE(qa.c_nextalarm), ',',
  QUOTE(qa.c_description),
  ') ON DUPLICATE KEY UPDATE c_startdate=VALUES(c_startdate), c_enddate=VALUES(c_enddate), c_title=VALUES(c_title), c_participants=VALUES(c_participants), c_status=VALUES(c_status), c_component=VALUES(c_component);'
) AS sql_stmt
FROM sogo_quick_appointment qa
INNER JOIN sogo_folder_info f ON qa.c_folder_id = f.c_folder_id
WHERE f.c_path2 LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- SOGo quick contact cache (contacts search/display data)
SELECT CONCAT(
  'INSERT INTO sogo_quick_contact (c_folder_id, c_name, c_givenname, c_cn, c_sn, c_screenname, c_l, c_mail, c_o, c_ou, c_telephonenumber, c_categories, c_component, c_hascertificate) VALUES (',
  QUOTE(qc.c_folder_id), ',',
  QUOTE(qc.c_name), ',',
  QUOTE(qc.c_givenname), ',',
  QUOTE(qc.c_cn), ',',
  QUOTE(qc.c_sn), ',',
  QUOTE(qc.c_screenname), ',',
  QUOTE(qc.c_l), ',',
  QUOTE(qc.c_mail), ',',
  QUOTE(qc.c_o), ',',
  QUOTE(qc.c_ou), ',',
  QUOTE(qc.c_telephonenumber), ',',
  QUOTE(qc.c_categories), ',',
  QUOTE(qc.c_component), ',',
  QUOTE(qc.c_hascertificate),
  ') ON DUPLICATE KEY UPDATE c_givenname=VALUES(c_givenname), c_cn=VALUES(c_cn), c_sn=VALUES(c_sn), c_mail=VALUES(c_mail), c_o=VALUES(c_o), c_telephonenumber=VALUES(c_telephonenumber), c_component=VALUES(c_component);'
) AS sql_stmt
FROM sogo_quick_contact qc
INNER JOIN sogo_folder_info f ON qc.c_folder_id = f.c_folder_id
WHERE f.c_path2 LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- SOGo ACL (shared calendar/contacts permissions)
SELECT CONCAT(
  'INSERT INTO sogo_acl (c_folder_id, c_object, c_uid, c_role) VALUES (',
  QUOTE(a.c_folder_id), ',',
  QUOTE(a.c_object), ',',
  QUOTE(a.c_uid), ',',
  QUOTE(a.c_role),
  ');'
) AS sql_stmt
FROM sogo_acl a
INNER JOIN sogo_folder_info f ON a.c_folder_id = f.c_folder_id
WHERE f.c_path2 LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- SOGo email alarms
SELECT CONCAT(
  'INSERT INTO sogo_alarms_folder (c_path, c_name, c_uid, c_recurrence_id, c_alarm_number, c_alarm_date) VALUES (',
  QUOTE(c_path), ',',
  QUOTE(c_name), ',',
  QUOTE(c_uid), ',',
  QUOTE(c_recurrence_id), ',',
  QUOTE(c_alarm_number), ',',
  QUOTE(c_alarm_date),
  ');'
) AS sql_stmt
FROM sogo_alarms_folder WHERE c_uid LIKE CONCAT('%@', '__TARGET_DOMAIN__');

-- SOGo user profiles (user preferences, timezone, display settings)
SELECT CONCAT(
  'INSERT INTO sogo_user_profile (c_uid, c_defaults, c_settings) VALUES (',
  QUOTE(c_uid), ',',
  QUOTE(c_defaults), ',',
  QUOTE(c_settings),
  ') ON DUPLICATE KEY UPDATE c_defaults=VALUES(c_defaults), c_settings=VALUES(c_settings);'
) AS sql_stmt
FROM sogo_user_profile WHERE c_uid LIKE CONCAT('%@', '__TARGET_DOMAIN__');
DOMAINEOF

# Replace the placeholder with the actual domain (safe: domain names can't contain SQL injection chars)
sed -i "s/__TARGET_DOMAIN__/${TARGET_DOMAIN}/g" "${TEMP_DIR}/domain_query.sql"

# Build the correct mount options
if [[ -n "${BACKUP_MYSQL_DIR}" ]]; then
  MOUNT_OPTS="-v ${BACKUP_MYSQL_DIR}:/backup_source:ro"
else
  MOUNT_OPTS="-v ${BACKUP_LOCATION}:/backup_archive:ro"
fi

docker run --rm \
  ${MOUNT_OPTS} \
  -v "${TEMP_DIR}/domain_query.sql:/tmp/domain_query.sql:Z" \
  --entrypoint="" \
  ${SQLIMAGE} \
  bash -c '
    set -e

    echo "=== Preparing Backup ===" >&2

    mkdir -p /backup

    # Extract or copy backup data
    if [[ -d /backup_source ]]; then
      echo "Copying backup data..." >&2
      cp -a /backup_source/. /backup/
    elif [[ -d /backup_archive ]]; then
      echo "Extracting backup archive..." >&2
      cd /backup
      if [[ -f /backup_archive/backup_mariadb.tar.zst ]]; then
        echo "Extracting zstd archive..." >&2
        zstd -d < /backup_archive/backup_mariadb.tar.zst | tar -xf - --strip-components=1
      elif [[ -f /backup_archive/backup_mariadb.tar.gz ]]; then
        echo "Extracting gz archive..." >&2
        gzip -d < /backup_archive/backup_mariadb.tar.gz | tar -xf - --strip-components=1
      else
        echo "ERROR: No backup_mariadb archive found!" >&2
        exit 1
      fi
      cd - > /dev/null
    else
      echo "ERROR: No backup data mounted!" >&2
      exit 1
    fi

    echo "Verifying backup contents..." >&2
    ls -la /backup/ >&2
    echo "" >&2

    # Prepare the backup (mariabackup --prepare makes data consistent and creates ib_logfile*)
    # Always run prepare - it is idempotent and safe on already-prepared backups
    echo "Preparing backup..." >&2
    if command -v mariabackup &> /dev/null; then
      echo "Running mariabackup --prepare..." >&2
      mariabackup --prepare --target-dir=/backup --use-memory=512M >/dev/null 2>&1 || true
    else
      echo "WARNING: mariabackup not found, skipping prepare step" >&2
    fi

    # Ensure correct ownership for mysqld
    chown -R mysql:mysql /backup

    # Start mysqld with the backup data directory
    echo "Starting MariaDB with backup data..." >&2
    mysqld --user=mysql --datadir=/backup --socket=/tmp/mysql_backup.sock \
      --skip-grant-tables --skip-networking --innodb-force-recovery=1 \
      --log-error=/tmp/mysqld.log &
    MYSQLD_PID=$!
    echo "mysqld started with PID $MYSQLD_PID" >&2

    # Wait for socket to appear
    WAITED=0
    while [[ ! -S /tmp/mysql_backup.sock ]] && [[ $WAITED -lt 120 ]]; do
      sleep 0.5
      ((WAITED=WAITED+1))
      if [[ $((WAITED % 20)) -eq 0 ]]; then
        echo "Waiting for socket... (${WAITED}/120)" >&2
      fi
      # Check if mysqld crashed
      if ! kill -0 $MYSQLD_PID 2>/dev/null; then
        echo "ERROR: mysqld process exited unexpectedly" >&2
        cat /tmp/mysqld.log >&2
        exit 1
      fi
    done

    if [[ ! -S /tmp/mysql_backup.sock ]]; then
      echo "ERROR: mysqld socket not created after 60s" >&2
      cat /tmp/mysqld.log >&2
      kill $MYSQLD_PID 2>/dev/null || true
      wait $MYSQLD_PID 2>/dev/null || true
      exit 1
    fi

    # Verify mysqld is still running
    if ! kill -0 $MYSQLD_PID 2>/dev/null; then
      echo "ERROR: mysqld process exited after socket creation" >&2
      cat /tmp/mysqld.log >&2
      exit 1
    fi

    echo "MariaDB started successfully" >&2
    echo "" >&2

    # Verify the mailcow database exists
    BACKUP_DBNAME=$(mysql --socket=/tmp/mysql_backup.sock -u root -N -e "SHOW DATABASES LIKE '"'"'mailcow'"'"';" 2>/dev/null)
    if [[ -z "$BACKUP_DBNAME" ]]; then
      echo "ERROR: mailcow database not found in backup" >&2
      echo "Available databases:" >&2
      mysql --socket=/tmp/mysql_backup.sock -u root -e "SHOW DATABASES;" 2>&1 >&2 || true
      kill $MYSQLD_PID 2>/dev/null || true
      wait $MYSQLD_PID 2>/dev/null || true
      exit 1
    fi
    echo "Found database: $BACKUP_DBNAME" >&2

    # Run the domain extraction query
    echo "Running domain extraction query..." >&2

    if ! OUTPUT=$(cat /tmp/domain_query.sql | mysql --socket=/tmp/mysql_backup.sock -u root -N 2>/tmp/query.err); then
      echo "ERROR: Query execution failed" >&2
      cat /tmp/query.err >&2
      echo "" >&2
      echo "mysqld log (last 50 lines):" >&2
      tail -50 /tmp/mysqld.log >&2
      kill $MYSQLD_PID 2>/dev/null || true
      wait $MYSQLD_PID 2>/dev/null || true
      exit 1
    fi

    if [[ -z "$OUTPUT" ]]; then
      echo "WARNING: Query returned no results for domain" >&2
      echo "Checking available domains in backup database..." >&2
      echo "AVAILABLE_DOMAINS_START" >&2
      mysql --socket=/tmp/mysql_backup.sock -u root -N -e "SELECT domain FROM mailcow.domain ORDER BY domain;" >&2 2>&1 || true
      echo "AVAILABLE_DOMAINS_END" >&2
    fi

    echo "$OUTPUT"

    # Cleanup
    echo "Cleaning up..." >&2
    kill $MYSQLD_PID 2>/dev/null || true
    wait $MYSQLD_PID 2>/dev/null || true
  ' 2>"${TEMP_DIR}/db_error.log" > "${TEMP_DIR}/domain_insert.sql"

# Check if extraction produced valid SQL (must contain at least one INSERT)
if [[ ! -s "${TEMP_DIR}/domain_insert.sql" ]] || ! grep -q "^INSERT INTO" "${TEMP_DIR}/domain_insert.sql" 2>/dev/null; then
  echo "Domain '${TARGET_DOMAIN}' was NOT found in the backup database."
  echo ""

  # Extract available domains from the error log if present
  if grep -q "AVAILABLE_DOMAINS_START" "${TEMP_DIR}/db_error.log" 2>/dev/null; then
    echo "Domains available in this backup:"
    sed -n '/AVAILABLE_DOMAINS_START/,/AVAILABLE_DOMAINS_END/{/AVAILABLE_DOMAINS/d;p}' "${TEMP_DIR}/db_error.log" | sed 's/^/  - /'
    echo ""
  else
    echo "Error output from database extraction:"
    echo "==========================================="
    cat "${TEMP_DIR}/db_error.log"
    echo "==========================================="
    echo ""
  fi
  error_exit "Domain '${TARGET_DOMAIN}' not found in backup. Check the domain name and try again."
else
  echo "Successfully extracted domain data"

  # Parse and show preview
  # Note: grep -c outputs "0" and exits 1 when no match, so use || true (not || echo 0)
  DOMAIN_COUNT=$(grep -c "INSERT INTO domain " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  MAILBOX_COUNT=$(grep -c "INSERT INTO mailbox " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  ALIAS_COUNT=$(grep -c "INSERT INTO alias " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  SENDER_ACL_COUNT=$(grep -c "INSERT INTO sender_acl " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  TLS_COUNT=$(grep -c "INSERT INTO tls_policy_override " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  BCC_COUNT=$(grep -c "INSERT INTO bcc_maps " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  FOOTER_COUNT=$(grep -c "INSERT INTO domain_wide_footer " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  # Default to 0 if empty
  DOMAIN_COUNT=${DOMAIN_COUNT:-0}
  MAILBOX_COUNT=${MAILBOX_COUNT:-0}
  ALIAS_COUNT=${ALIAS_COUNT:-0}
  SENDER_ACL_COUNT=${SENDER_ACL_COUNT:-0}
  TLS_COUNT=${TLS_COUNT:-0}
  BCC_COUNT=${BCC_COUNT:-0}
  FOOTER_COUNT=${FOOTER_COUNT:-0}

  # SOGo calendar/contacts counts
  SOGO_FOLDER_COUNT=$(grep -c "INSERT INTO sogo_folder_info " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  SOGO_STORE_COUNT=$(grep -c "INSERT INTO sogo_store " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  SOGO_CAL_COUNT=$(grep -c "INSERT INTO sogo_quick_appointment " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  SOGO_CONTACT_COUNT=$(grep -c "INSERT INTO sogo_quick_contact " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  SOGO_PROFILE_COUNT=$(grep -c "INSERT INTO sogo_user_profile " "${TEMP_DIR}/domain_insert.sql" 2>/dev/null || true)
  SOGO_FOLDER_COUNT=${SOGO_FOLDER_COUNT:-0}
  SOGO_STORE_COUNT=${SOGO_STORE_COUNT:-0}
  SOGO_CAL_COUNT=${SOGO_CAL_COUNT:-0}
  SOGO_CONTACT_COUNT=${SOGO_CONTACT_COUNT:-0}
  SOGO_PROFILE_COUNT=${SOGO_PROFILE_COUNT:-0}

  echo "Preview of data to be restored:"
  echo "- Domain configurations: ${DOMAIN_COUNT}"
  echo "- Mailboxes: ${MAILBOX_COUNT}"
  echo "- Email aliases: ${ALIAS_COUNT}"
  [[ ${SENDER_ACL_COUNT} -gt 0 ]] && echo "- Sender ACL entries: ${SENDER_ACL_COUNT}"
  [[ ${TLS_COUNT} -gt 0 ]] && echo "- TLS policy overrides: ${TLS_COUNT}"
  [[ ${BCC_COUNT} -gt 0 ]] && echo "- BCC maps: ${BCC_COUNT}"
  [[ ${FOOTER_COUNT} -gt 0 ]] && echo "- Domain-wide footers: ${FOOTER_COUNT}"
  [[ ${SOGO_CAL_COUNT} -gt 0 ]] && echo "- Calendar events/tasks: ${SOGO_CAL_COUNT}"
  [[ ${SOGO_CONTACT_COUNT} -gt 0 ]] && echo "- Contacts: ${SOGO_CONTACT_COUNT}"
  [[ ${SOGO_PROFILE_COUNT} -gt 0 ]] && echo "- SOGo user profiles: ${SOGO_PROFILE_COUNT}"
fi

# Step 3b: Extract DKIM keys from backup Redis

# Detect Redis backup archive before attempting extraction
REDIS_ARCHIVE_INFO=$(get_archive_info "backup_redis" "${BACKUP_LOCATION}")
if [[ -z "${REDIS_ARCHIVE_INFO}" ]]; then
  echo "No Redis backup found (DKIM keys cannot be restored)"
  SKIP_DKIM=1
else
  echo "Found Redis backup: $(echo ${REDIS_ARCHIVE_INFO} | cut -d'|' -f1)"
  SKIP_DKIM=0
fi

DKIM_FOUND=0
if [[ ${SKIP_DKIM} -eq 0 ]]; then
  echo
  echo "Step 3b: Extracting DKIM keys from backup Redis..."

  REDIS_ARCHIVE_FILE=$(echo "${REDIS_ARCHIVE_INFO}" | cut -d'|' -f1)
  REDIS_DECOMPRESS=$(echo "${REDIS_ARCHIVE_INFO}" | cut -d'|' -f2)

  # Step 1: Extract dump.rdb using mariadb image (has working GNU tar + zstd)
  docker run --rm \
    -v "${BACKUP_LOCATION}:/backup:ro" \
    -v "${TEMP_DIR}:/output:Z" \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c '
      set -e
      mkdir -p /extract
      cd /extract
      echo "Decompressing Redis archive..." >&2
      '"${REDIS_DECOMPRESS}"' < /backup/'"${REDIS_ARCHIVE_FILE}"' | tar -xf -
      echo "Extraction complete, finding dump.rdb..." >&2
      DUMP_FILE=$(find /extract -name "dump.rdb" -type f 2>/dev/null | head -1)
      if [[ -z "$DUMP_FILE" ]]; then
        echo "ERROR: No dump.rdb found in Redis backup" >&2
        find /extract -type f >&2
        exit 1
      fi
      cp "$DUMP_FILE" /output/dump.rdb
      echo "dump.rdb extracted successfully" >&2
    ' 2>"${TEMP_DIR}/dkim_extract.log"

  if [[ ! -f "${TEMP_DIR}/dump.rdb" ]]; then
    echo "Warning: Could not extract dump.rdb from Redis backup"
    if [[ -s "${TEMP_DIR}/dkim_extract.log" ]]; then
      cat "${TEMP_DIR}/dkim_extract.log" | sed 's/^/    /'
    fi
    SKIP_DKIM=1
  else
    echo "Redis dump extracted"

    # Step 2: Load dump.rdb in redis-alpine and query DKIM keys
    docker run --rm \
      -v "${TEMP_DIR}/dump.rdb:/data/dump.rdb:ro,Z" \
      --entrypoint="" \
      redis:7-alpine \
      sh -c '
        set -e

        # Copy dump.rdb so redis can write to the directory
        mkdir -p /rdata
        cp /data/dump.rdb /rdata/dump.rdb

        # Start Redis with the backup data
        redis-server --daemonize yes --dir /rdata --dbfilename dump.rdb --port 6399 --loglevel warning

        # Wait for Redis to load the RDB
        WAITED=0
        while ! redis-cli -p 6399 ping 2>/dev/null | grep -q PONG; do
          sleep 0.5
          ((WAITED=WAITED+1))
          if [[ $WAITED -ge 60 ]]; then
            echo "ERROR: Redis did not start" >&2
            exit 1
          fi
        done

        DOMAIN="'"${TARGET_DOMAIN}"'"

        # Get DKIM selector
        SELECTOR=$(redis-cli -p 6399 HGET DKIM_SELECTORS "$DOMAIN" 2>/dev/null)
        if [[ -z "$SELECTOR" || "$SELECTOR" == "(nil)" ]]; then
          echo "NO_DKIM" >&2
          exit 0
        fi

        # Get public key
        PUBKEY=$(redis-cli -p 6399 HGET DKIM_PUB_KEYS "$DOMAIN" 2>/dev/null)

        # Get private key (field is selector.domain)
        PRIVKEY=$(redis-cli -p 6399 HGET DKIM_PRIV_KEYS "${SELECTOR}.${DOMAIN}" 2>/dev/null)

        if [[ -z "$PRIVKEY" || "$PRIVKEY" == "(nil)" ]]; then
          echo "NO_DKIM" >&2
          exit 0
        fi

        # Output as delimited sections
        echo "DKIM_SELECTOR=${SELECTOR}"
        echo "DKIM_PUBKEY=${PUBKEY}"
        echo "DKIM_PRIVKEY_START"
        echo "${PRIVKEY}"
        echo "DKIM_PRIVKEY_END"

        redis-cli -p 6399 shutdown nosave 2>/dev/null || true
      ' 2>"${TEMP_DIR}/dkim_error.log" > "${TEMP_DIR}/dkim_export.txt"
  fi

  if grep -q "NO_DKIM" "${TEMP_DIR}/dkim_error.log" 2>/dev/null; then
    echo "No DKIM keys found for ${TARGET_DOMAIN} in backup"
    SKIP_DKIM=1
  elif grep -q "DKIM_SELECTOR=" "${TEMP_DIR}/dkim_export.txt" 2>/dev/null; then
    DKIM_SELECTOR=$(grep "^DKIM_SELECTOR=" "${TEMP_DIR}/dkim_export.txt" | cut -d= -f2)
    DKIM_PUBKEY=$(grep "^DKIM_PUBKEY=" "${TEMP_DIR}/dkim_export.txt" | cut -d= -f2)
    # Extract multi-line private key
    DKIM_PRIVKEY=$(sed -n '/^DKIM_PRIVKEY_START$/,/^DKIM_PRIVKEY_END$/{ /^DKIM_PRIVKEY_START$/d; /^DKIM_PRIVKEY_END$/d; p }' "${TEMP_DIR}/dkim_export.txt")
    DKIM_FOUND=1
    echo "Found DKIM key (selector: ${DKIM_SELECTOR})"
    echo "- DKIM keys: 1 (selector: ${DKIM_SELECTOR})"
  else
    echo "Warning: Could not extract DKIM keys from backup Redis"
    if [[ -s "${TEMP_DIR}/dkim_error.log" ]]; then
      echo "Error details:"
      cat "${TEMP_DIR}/dkim_error.log" | sed 's/^/    /'
    fi
    SKIP_DKIM=1
  fi
fi

echo

# Step 4: Pre-restore validation - Check current state

echo "Step 4: Checking current mailcow state..."

DOMAIN_EXISTS=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs -e "SELECT COUNT(*) FROM domain WHERE domain='${TARGET_DOMAIN}'" 2>/dev/null)

if [[ ${DOMAIN_EXISTS} -gt 0 ]]; then
  echo "Domain ${TARGET_DOMAIN} currently exists in mailcow"
  if [[ ${FORCE} -eq 0 ]]; then
    error_exit "Use --force flag to overwrite existing domain"
  fi

  # Create pre-restore backup
  echo "Creating backup of current domain state before restore..."
  mkdir -p "${PREBACKUP_DIR}"

  PREBACKUP_FILE="${PREBACKUP_DIR}/${TARGET_DOMAIN}_$(date +%Y%m%d_%H%M%S).sql"
  docker exec $(docker ps -qf name=mysql-mailcow) mysql -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs -N -e "
    SELECT CONCAT('INSERT INTO domain (domain, description, aliases, mailboxes, defquota, maxquota, quota, relayhost, backupmx, gal, relay_all_recipients, relay_unknown_only, created, modified, active) VALUES (', QUOTE(domain), ',', QUOTE(description), ',', QUOTE(aliases), ',', QUOTE(mailboxes), ',', QUOTE(defquota), ',', QUOTE(maxquota), ',', QUOTE(quota), ',', QUOTE(relayhost), ',', QUOTE(backupmx), ',', QUOTE(gal), ',', QUOTE(relay_all_recipients), ',', QUOTE(relay_unknown_only), ',', QUOTE(created), ',', QUOTE(modified), ',', QUOTE(active), ') ON DUPLICATE KEY UPDATE description=VALUES(description), aliases=VALUES(aliases), mailboxes=VALUES(mailboxes), defquota=VALUES(defquota), maxquota=VALUES(maxquota), quota=VALUES(quota), relayhost=VALUES(relayhost), backupmx=VALUES(backupmx), gal=VALUES(gal), relay_all_recipients=VALUES(relay_all_recipients), relay_unknown_only=VALUES(relay_unknown_only), active=VALUES(active);')
    FROM domain WHERE domain='${TARGET_DOMAIN}';
    SELECT CONCAT('INSERT INTO mailbox (username, password, name, description, mailbox_path_prefix, quota, local_part, domain, attributes, custom_attributes, kind, multiple_bookings, authsource, created, modified, active) VALUES (', QUOTE(username), ',', QUOTE(password), ',', QUOTE(name), ',', QUOTE(description), ',', QUOTE(mailbox_path_prefix), ',', QUOTE(quota), ',', QUOTE(local_part), ',', QUOTE(domain), ',', QUOTE(attributes), ',', QUOTE(custom_attributes), ',', QUOTE(kind), ',', QUOTE(multiple_bookings), ',', QUOTE(authsource), ',', QUOTE(created), ',', QUOTE(modified), ',', QUOTE(active), ') ON DUPLICATE KEY UPDATE password=VALUES(password), name=VALUES(name), description=VALUES(description), quota=VALUES(quota), attributes=VALUES(attributes), custom_attributes=VALUES(custom_attributes), kind=VALUES(kind), active=VALUES(active);')
    FROM mailbox WHERE domain='${TARGET_DOMAIN}';
    SELECT CONCAT('INSERT INTO alias (address, goto, domain, created, modified, private_comment, public_comment, sogo_visible, \`internal\`, sender_allowed, active) VALUES (', QUOTE(address), ',', QUOTE(goto), ',', QUOTE(domain), ',', QUOTE(created), ',', QUOTE(modified), ',', QUOTE(private_comment), ',', QUOTE(public_comment), ',', QUOTE(sogo_visible), ',', QUOTE(\`internal\`), ',', QUOTE(sender_allowed), ',', QUOTE(active), ') ON DUPLICATE KEY UPDATE goto=VALUES(goto), active=VALUES(active);')
    FROM alias WHERE domain='${TARGET_DOMAIN}';
  " 2>/dev/null > "${PREBACKUP_FILE}"

  echo "Pre-restore backup created: ${PREBACKUP_FILE}"
else
  echo "Domain ${TARGET_DOMAIN} does not currently exist (new domain restore)"
fi

echo

# Step 5: Check vmail backup

echo "Step 5: Checking vmail backup..."

# Check if vmail backup exists
ARCHIVE_INFO=$(get_archive_info "backup_vmail" "${BACKUP_LOCATION}")
if [[ -z "${ARCHIVE_INFO}" ]]; then
  echo "Warning: No vmail backup found (will restore database only)"
  SKIP_VMAIL=1
else
  echo "Found vmail backup: $(echo ${ARCHIVE_INFO} | cut -d'|' -f1)"
  SKIP_VMAIL=0
fi

# Redis backup already checked in Step 3b
if [[ ${SKIP_DKIM} -eq 0 ]]; then
  echo "Redis backup: available (checked in Step 3b)"
else
  echo "Redis backup: not available (DKIM will need manual setup)"
fi

# Check if crypt backup exists (mail_crypt encryption keys)
CRYPT_ARCHIVE_INFO=$(get_archive_info "backup_crypt" "${BACKUP_LOCATION}")
SKIP_CRYPT=1
CRYPT_MISMATCH=0
if [[ -z "${CRYPT_ARCHIVE_INFO}" ]]; then
  echo "No crypt backup found (mail_crypt keys not in backup)"
else
  echo "Found crypt backup: $(echo ${CRYPT_ARCHIVE_INFO} | cut -d'|' -f1)"

  # Compare backup's public key against live to detect mismatch
  # Mail is encrypted at rest with these keys - if they differ, restored mail is unreadable
  CRYPT_ARCHIVE_FILE=$(echo "${CRYPT_ARCHIVE_INFO}" | cut -d'|' -f1)
  CRYPT_DECOMPRESS=$(echo "${CRYPT_ARCHIVE_INFO}" | cut -d'|' -f2)

  # Extract public key from backup
  BACKUP_PUBKEY=$(docker run --rm \
    -v "${BACKUP_LOCATION}:/backup:ro" \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c '
      mkdir -p /extract && cd /extract
      '"${CRYPT_DECOMPRESS}"' < /backup/'"${CRYPT_ARCHIVE_FILE}"' | tar -xf - 2>/dev/null
      PUBKEY=$(find /extract -name "ecpubkey.pem" -type f 2>/dev/null | head -1)
      if [[ -n "$PUBKEY" ]]; then cat "$PUBKEY"; fi
    ' 2>/dev/null || true)

  # Get live public key from crypt volume
  LIVE_PUBKEY=$(docker run --rm \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_crypt-vol-1$):/crypt:ro \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c 'cat /crypt/ecpubkey.pem 2>/dev/null || true' 2>/dev/null || true)

  if [[ -z "${BACKUP_PUBKEY}" ]]; then
    echo "Warning: Could not read public key from crypt backup"
  elif [[ -z "${LIVE_PUBKEY}" ]]; then
    echo "Warning: Could not read live mail_crypt public key"
    echo "→ Crypt keys may need restoring for mail to be readable"
    SKIP_CRYPT=0
  elif [[ "${BACKUP_PUBKEY}" == "${LIVE_PUBKEY}" ]]; then
    echo "mail_crypt keys match (backup == live) - restored mail will be readable"
  else
    echo "mail_crypt keys DIFFER between backup and live server"
    CRYPT_MISMATCH=1
    SKIP_CRYPT=0
  fi
fi

# Prompt for mail_crypt mismatch before proceeding
if [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo
  if [[ ${FORCE_MAILCRYPT} -eq 0 ]]; then
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "!!! mail_crypt KEY MISMATCH DETECTED"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "The backup was encrypted with a DIFFERENT mail_crypt key than the live server."
    echo "Restored mail files will be UNREADABLE without the matching private key."
    echo ""
    echo "Options:"
    echo "  - Cancel the restore and investigate the key mismatch (recommended)"
    echo "  - Proceed and restore crypt keys from backup"
    echo "  - Use --forcemailcrypt to bypass this check and forcably restore backup keys (not recommended without verifying keys first)"
    echo ""
    read -p "Continue despite mail_crypt key mismatch? [y|N] " -r
    if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
      echo "Restore cancelled due to mail_crypt key mismatch"
      exit 0
    fi
  else
    echo "(Skipping mail_crypt mismatch prompt due to --forcemailcrypt flag)"
  fi
fi

echo

# Step 6: Initial confirmation

echo "About to restore domain: ${TARGET_DOMAIN}"
echo "This will:"
echo "- Add/update domain configuration in database"
echo "- Add/update all mailboxes for this domain"
echo "- Add/update all email aliases for this domain"
if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo "- Restore mail files (vmail) for this domain"
fi
if [[ ${SOGO_CAL_COUNT} -gt 0 || ${SOGO_CONTACT_COUNT} -gt 0 ]]; then
  echo "- Restore SOGo calendars (${SOGO_CAL_COUNT} events) and contacts (${SOGO_CONTACT_COUNT})"
fi
if [[ ${DKIM_FOUND} -eq 1 ]]; then
  echo "- Restore DKIM key (selector: ${DKIM_SELECTOR}) from backup Redis"
elif [[ ${SKIP_DKIM} -eq 1 ]]; then
  echo "- DKIM keys: not available in backup (will need manual setup)"
fi
if [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo "- !!!  Restore mail_crypt keys (REQUIRED - backup/live keys differ!)"
elif [[ ${SKIP_CRYPT} -eq 0 ]]; then
  echo "- Restore mail_crypt encryption keys from backup"
fi
echo

if [[ ${CONFIRM_RESTORE} -eq 0 ]]; then
  read -p "Do you want to proceed? [y|N] " -r
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "Restore cancelled"
    exit 0
  fi
else
  echo "(Skipping confirmation due to --confirm flag)"
fi

echo

# Step 7: FINAL CONFIRMATION - Before touching live mailcow database

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "!!!  FINAL CONFIRMATION - YOU ARE ABOUT TO MODIFY THE LIVE MAILCOW DATABASE !!!"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Domain: ${TARGET_DOMAIN}"
echo "Backup source: ${BACKUP_LOCATION}"
echo "Mailcow project: ${COMPOSE_PROJECT_NAME}"
echo ""
echo "This operation will:"
echo "Restore/modify domain configuration"
echo "Restore/modify ${MAILBOX_COUNT} mailbox(es)"
echo "Restore/modify ${ALIAS_COUNT} alias(es)"
if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo "Restore mail files (vmail) - dovecot will be briefly stopped (~30 seconds)"
fi
if [[ ${SOGO_CAL_COUNT} -gt 0 || ${SOGO_CONTACT_COUNT} -gt 0 ]]; then
  echo "Restore SOGo calendars (${SOGO_CAL_COUNT} events) and contacts (${SOGO_CONTACT_COUNT})"
fi
if [[ ${DKIM_FOUND} -eq 1 ]]; then
  echo "Restore DKIM signing key (selector: ${DKIM_SELECTOR})"
fi
if [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo "!!!  Restore mail_crypt keys (keys differ - mail will be unreadable without this!)"
elif [[ ${SKIP_CRYPT} -eq 0 ]]; then
  echo "Restore mail_crypt encryption keys"
fi
if [[ ${DOMAIN_EXISTS} -gt 0 ]]; then
  echo "!!!  This domain already exists - data will be OVERWRITTEN"
  if [[ -n "${PREBACKUP_FILE}" ]] && [[ -f "${PREBACKUP_FILE}" ]]; then
    echo "Pre-restore backup saved to: ${PREBACKUP_FILE}"
  fi
fi
echo ""

if [[ ${CONFIRM_RESTORE} -eq 0 ]]; then
  read -p "Type 'restore' to confirm and proceed with the restore: " -r CONFIRM_INPUT
  if [[ "${CONFIRM_INPUT}" != "restore" ]]; then
    echo ""
    echo "Restore cancelled. No changes were made to mailcow."
    exit 0
  fi
else
  echo "(Skipping confirmation due to --confirm flag)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Proceeding with restore..."
echo "═══════════════════════════════════════════════════════════════════════════════"
echo

# Step 8: Apply database changes

echo "Step 8: Restoring domain to database..."

# Create a temporary SQL file with transaction wrapper
cat > "${TEMP_DIR}/final_restore.sql" << 'SQLEOF'
SET sql_mode='';
SET FOREIGN_KEY_CHECKS=0;
START TRANSACTION;
SQLEOF

cat "${TEMP_DIR}/domain_insert.sql" >> "${TEMP_DIR}/final_restore.sql"

cat >> "${TEMP_DIR}/final_restore.sql" << 'SQLEOF'
COMMIT;
SET FOREIGN_KEY_CHECKS=1;
SQLEOF

# Load the SQL into the running database
docker exec -i $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" < "${TEMP_DIR}/final_restore.sql" 2>"${TEMP_DIR}/restore_error.log"

if [[ $? -ne 0 ]]; then
  echo "Restore error log:"
  cat "${TEMP_DIR}/restore_error.log"
  error_exit "Database restore failed. See error log above."
fi

# Ensure quota2 and quota2replica rows exist for restored mailboxes
# Without these, the mailcow UI hangs on "Please wait..." because the
# mailbox_details query INNER JOINs mailbox with quota2/quota2replica
echo "Ensuring quota tracking rows exist for restored mailboxes..."
docker exec -i $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -e "
  INSERT IGNORE INTO quota2 (username, bytes, messages)
    SELECT username, 0, 0 FROM mailbox WHERE domain='${TARGET_DOMAIN}';
  INSERT IGNORE INTO quota2replica (username, bytes, messages)
    SELECT username, 0, 0 FROM mailbox WHERE domain='${TARGET_DOMAIN}';
" 2>/dev/null || true

# Update _sogo_static_view so SOGo can authenticate restored mailboxes.
# SOGo reads this table to discover users; without entries, login is
# rejected with "Unauthorized".  The c_password column is intentionally
# set to a random placeholder -- SOGo authenticates via IMAP/dovecot,
# not this hash.  The grouped_* views already exist in the live DB.
echo "Updating SOGo static view for restored mailboxes..."
SOGO_PLACEHOLDER_HASH='{SSHA256}dummy_placeholder_not_used_for_auth'
docker exec -i $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" << SOGOEOF 2>/dev/null
INSERT INTO _sogo_static_view
  (c_uid, domain, c_name, c_password, c_cn, mail, aliases, ad_aliases, ext_acl, kind, multiple_bookings)
SELECT
  mailbox.username,
  mailbox.domain,
  mailbox.username,
  '${SOGO_PLACEHOLDER_HASH}',
  mailbox.name,
  mailbox.username,
  IFNULL(GROUP_CONCAT(ga.aliases ORDER BY ga.aliases SEPARATOR ' '), ''),
  IFNULL(gda.ad_alias, ''),
  IFNULL(external_acl.send_as_acl, ''),
  mailbox.kind,
  mailbox.multiple_bookings
FROM mailbox
  LEFT OUTER JOIN grouped_mail_aliases ga
    ON ga.username REGEXP CONCAT('(^|,)', mailbox.username, '(\$|,)')
  LEFT OUTER JOIN grouped_domain_alias_address gda
    ON gda.username = mailbox.username
  LEFT OUTER JOIN grouped_sender_acl_external external_acl
    ON external_acl.username = mailbox.username
WHERE mailbox.active = '1'
  AND mailbox.domain = '${TARGET_DOMAIN}'
GROUP BY mailbox.username
ON DUPLICATE KEY UPDATE
  domain            = VALUES(domain),
  c_name            = VALUES(c_name),
  c_password        = VALUES(c_password),
  c_cn              = VALUES(c_cn),
  mail              = VALUES(mail),
  aliases           = VALUES(aliases),
  ad_aliases        = VALUES(ad_aliases),
  ext_acl           = VALUES(ext_acl),
  kind              = VALUES(kind),
  multiple_bookings = VALUES(multiple_bookings);

DELETE FROM _sogo_static_view
  WHERE c_uid NOT IN (SELECT username FROM mailbox WHERE active = '1');
SOGOEOF

if [[ $? -eq 0 ]]; then
  echo "SOGo static view updated"
else
  echo "⚠ Warning: Failed to update SOGo static view - SOGo logins may not work"
  echo "Fix manually: restart php-fpm-mailcow or run update_sogo_static_view() via mailcow UI"
fi

echo "Database restore completed"
echo

# Step 9: Restore vmail files (with dovecot stopped only during extraction)

if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo "Step 9: Restoring vmail files..."

  ARCHIVE_INFO=$(get_archive_info "backup_vmail" "${BACKUP_LOCATION}")
  ARCHIVE_FILE=$(echo "${ARCHIVE_INFO}" | cut -d'|' -f1)
  DECOMPRESS_PROG=$(echo "${ARCHIVE_INFO}" | cut -d'|' -f2)

  echo "Stopping dovecot temporarily for vmail restoration..."
  DOVECOT_WAS_RUNNING=0
  if docker ps -qf name=dovecot-mailcow | grep -q .; then
    docker stop $(docker ps -qf name=dovecot-mailcow) 2>/dev/null || true
    DOVECOT_WAS_RUNNING=1
  fi

  # Extract only this domain's vmail from the backup archive
  # The -P flag in the original backup preserves absolute paths (/vmail/...)
  docker run -i --name mailcow-restore-domain --rm \
    -v "${BACKUP_LOCATION}:/backup:z" \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_vmail-vol-1$):/vmail:z \
    ${SQLIMAGE} \
    /bin/bash -c "${DECOMPRESS_PROG} < /backup/${ARCHIVE_FILE} | tar -Pxf - --wildcards '*/vmail/${TARGET_DOMAIN}/*' 2>/tmp/tar_err.log || ${DECOMPRESS_PROG} < /backup/${ARCHIVE_FILE} | tar -Pxf - --wildcards '/vmail/${TARGET_DOMAIN}/*' 2>/tmp/tar_err.log; cat /tmp/tar_err.log >&2" 2>"${TEMP_DIR}/vmail_extract.log" | grep -v "Removing leading" || true

  # Verify that mail files were actually extracted
  VMAIL_DIR_EXISTS=$(docker run --rm \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_vmail-vol-1$):/vmail:ro \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c "[[ -d /vmail/${TARGET_DOMAIN} ]] && echo yes || echo no" 2>/dev/null)

  if [[ "${VMAIL_DIR_EXISTS}" == "yes" ]]; then
    echo "Vmail files extracted"
  else
    echo "⚠ WARNING: Domain directory not found in vmail volume after extraction!"
    echo "The backup archive may not contain mail for ${TARGET_DOMAIN},"
    echo "or the archive path structure differs from expected."
    if [[ -s "${TEMP_DIR}/vmail_extract.log" ]]; then
      echo "Extraction log:"
      head -20 "${TEMP_DIR}/vmail_extract.log" | sed 's/^/    /'
    fi
  fi

  # Restart dovecot and fix permissions
  if [[ ${DOVECOT_WAS_RUNNING} -eq 1 ]]; then
    echo "Restarting dovecot..."
    docker start $(docker ps -aqf name=dovecot-mailcow) 2>/dev/null || true
    sleep 2
  fi

  # Fix permissions via dovecot container
  echo "Fixing vmail permissions..."
  docker exec $(docker ps -qf name=dovecot-mailcow) bash -c "
    if [[ -d /var/vmail/${TARGET_DOMAIN} ]]; then
      chown -R vmail:vmail /var/vmail/${TARGET_DOMAIN}
      chmod -R 700 /var/vmail/${TARGET_DOMAIN}
    fi
  " 2>/dev/null || true

  # Force dovecot to rebuild indexes and recalculate quotas so mail
  # shows up immediately in the UI instead of appearing empty.
  echo "Forcing dovecot index resync for restored mailboxes..."
  docker exec $(docker ps -qf name=dovecot-mailcow) doveadm force-resync -u "*@${TARGET_DOMAIN}" '*' 2>/dev/null || true
  echo "Dovecot indexes resynced"

  echo "Recalculating mailbox quotas..."
  docker exec $(docker ps -qf name=dovecot-mailcow) doveadm quota recalc -u "*@${TARGET_DOMAIN}" 2>/dev/null || true
  echo "Quotas recalculated"

  echo
fi

# Step 9b: Restore DKIM keys to live Redis

if [[ ${DKIM_FOUND} -eq 1 ]]; then
  echo "Step 9b: Restoring DKIM keys..."

  # Write private key to temp file to handle multi-line PEM safely
  echo "${DKIM_PRIVKEY}" > "${TEMP_DIR}/dkim_privkey.pem"

  # Back up existing DKIM keys if they exist
  EXISTING_SELECTOR=$(docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
    HGET DKIM_SELECTORS "${TARGET_DOMAIN}" 2>/dev/null || true)

  if [[ -n "${EXISTING_SELECTOR}" && "${EXISTING_SELECTOR}" != "(nil)" && "${EXISTING_SELECTOR}" != "" ]]; then
    echo "Backing up existing DKIM key (selector: ${EXISTING_SELECTOR})..."
    EXISTING_PUBKEY=$(docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
      HGET DKIM_PUB_KEYS "${TARGET_DOMAIN}" 2>/dev/null || true)
    EXISTING_PRIVKEY=$(docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
      HGET DKIM_PRIV_KEYS "${EXISTING_SELECTOR}.${TARGET_DOMAIN}" 2>/dev/null || true)

    if [[ -n "${EXISTING_PRIVKEY}" && "${EXISTING_PRIVKEY}" != "(nil)" ]]; then
      mkdir -p "${PREBACKUP_DIR}"
      DKIM_BACKUP_FILE="${PREBACKUP_DIR}/${TARGET_DOMAIN}_dkim_$(date +%Y%m%d_%H%M%S).txt"
      echo "SELECTOR=${EXISTING_SELECTOR}" > "${DKIM_BACKUP_FILE}"
      echo "PUBKEY=${EXISTING_PUBKEY}" >> "${DKIM_BACKUP_FILE}"
      echo "PRIVKEY_START" >> "${DKIM_BACKUP_FILE}"
      echo "${EXISTING_PRIVKEY}" >> "${DKIM_BACKUP_FILE}"
      echo "PRIVKEY_END" >> "${DKIM_BACKUP_FILE}"
      echo "Existing DKIM backed up to: ${DKIM_BACKUP_FILE}"
    fi

    # If the old selector differs from the backup selector, remove old key
    if [[ "${EXISTING_SELECTOR}" != "${DKIM_SELECTOR}" ]]; then
      docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
        HDEL DKIM_PRIV_KEYS "${EXISTING_SELECTOR}.${TARGET_DOMAIN}" >/dev/null 2>&1 || true
    fi
  fi

  # Import DKIM selector
  docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
    HSET DKIM_SELECTORS "${TARGET_DOMAIN}" "${DKIM_SELECTOR}" >/dev/null 2>&1

  # Import DKIM public key
  if [[ -n "${DKIM_PUBKEY}" && "${DKIM_PUBKEY}" != "(nil)" ]]; then
    docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
      HSET DKIM_PUB_KEYS "${TARGET_DOMAIN}" "${DKIM_PUBKEY}" >/dev/null 2>&1
  fi

  # Import DKIM private key (multi-line PEM - pipe from file)
  docker cp "${TEMP_DIR}/dkim_privkey.pem" $(docker ps -qf name=redis-mailcow):/tmp/dkim_privkey.pem
  docker exec $(docker ps -qf name=redis-mailcow) sh -c \
    'redis-cli -a "'"${REDISPASS}"'" --no-auth-warning HSET DKIM_PRIV_KEYS "'"${DKIM_SELECTOR}.${TARGET_DOMAIN}"'" "$(cat /tmp/dkim_privkey.pem)"' >/dev/null 2>&1
  docker exec $(docker ps -qf name=redis-mailcow) rm -f /tmp/dkim_privkey.pem 2>/dev/null || true

  # Verify the import
  VERIFY_SELECTOR=$(docker exec $(docker ps -qf name=redis-mailcow) redis-cli -a "${REDISPASS}" --no-auth-warning \
    HGET DKIM_SELECTORS "${TARGET_DOMAIN}" 2>/dev/null)
  if [[ "${VERIFY_SELECTOR}" == "${DKIM_SELECTOR}" ]]; then
    echo "DKIM keys restored (selector: ${DKIM_SELECTOR})"
  else
    echo "WARNING: DKIM key verification failed - check manually via mailcow UI"
  fi
  echo
fi

# Step 9c: Restore mail_crypt keys if needed

if [[ ${SKIP_CRYPT} -eq 0 ]]; then
  echo "Step 9c: Restoring mail_crypt encryption keys..."

  CRYPT_ARCHIVE_FILE=$(echo "${CRYPT_ARCHIVE_INFO}" | cut -d'|' -f1)
  CRYPT_DECOMPRESS=$(echo "${CRYPT_ARCHIVE_INFO}" | cut -d'|' -f2)

  # Back up current crypt keys before overwriting
  mkdir -p "${PREBACKUP_DIR}"
  CRYPT_BACKUP_DIR="${PREBACKUP_DIR}/${TARGET_DOMAIN}_crypt_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${CRYPT_BACKUP_DIR}"
  docker run --rm \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_crypt-vol-1$):/crypt:ro \
    -v "${CRYPT_BACKUP_DIR}:/backup" \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c 'cp /crypt/ecprivkey.pem /crypt/ecpubkey.pem /backup/ 2>/dev/null || true' 2>/dev/null || true
  if [[ -f "${CRYPT_BACKUP_DIR}/ecpubkey.pem" ]]; then
    echo "Current crypt keys backed up to: ${CRYPT_BACKUP_DIR}"
  fi

  # Stop dovecot before replacing crypt keys
  echo "Stopping dovecot for crypt key restore..."
  DOVECOT_WAS_RUNNING_CRYPT=0
  if docker ps -qf name=dovecot-mailcow | grep -q .; then
    docker stop $(docker ps -qf name=dovecot-mailcow) 2>/dev/null || true
    DOVECOT_WAS_RUNNING_CRYPT=1
  fi

  # Restore crypt keys from backup archive into the crypt volume
  docker run --rm \
    -v "${BACKUP_LOCATION}:/backup:ro" \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_crypt-vol-1$):/crypt \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c '
      set -e
      mkdir -p /extract && cd /extract
      '"${CRYPT_DECOMPRESS}"' < /backup/'"${CRYPT_ARCHIVE_FILE}"' | tar -xf -
      PRIVKEY=$(find /extract -name "ecprivkey.pem" -type f 2>/dev/null | head -1)
      PUBKEY=$(find /extract -name "ecpubkey.pem" -type f 2>/dev/null | head -1)
      if [[ -n "$PRIVKEY" && -n "$PUBKEY" ]]; then
        cp "$PRIVKEY" /crypt/ecprivkey.pem
        cp "$PUBKEY" /crypt/ecpubkey.pem
        chown 401 /crypt/ecprivkey.pem /crypt/ecpubkey.pem
        echo "Keys restored" >&2
      else
        echo "ERROR: Could not find key files in backup" >&2
        exit 1
      fi
    ' 2>"${TEMP_DIR}/crypt_restore.log"

  if grep -q "Keys restored" "${TEMP_DIR}/crypt_restore.log" 2>/dev/null; then
    echo "mail_crypt keys restored from backup"
  else
    echo "WARNING: Failed to restore mail_crypt keys"
    if [[ -s "${TEMP_DIR}/crypt_restore.log" ]]; then
      cat "${TEMP_DIR}/crypt_restore.log" | sed 's/^/    /'
    fi
  fi

  # Restart dovecot
  if [[ ${DOVECOT_WAS_RUNNING_CRYPT} -eq 1 ]]; then
    echo "Restarting dovecot..."
    docker start $(docker ps -aqf name=dovecot-mailcow) 2>/dev/null || true
    sleep 2
  fi
  echo
fi

# Step 9d: Restart services to clear caches

echo "Restarting mailcow services to apply changes..."

# Restart SOGo to pick up new mailboxes/aliases/calendars/contacts
if docker ps -qf name=sogo-mailcow | grep -q .; then
  docker restart $(docker ps -qf name=sogo-mailcow) 2>/dev/null || true
  echo "SOGo restarted (calendars/contacts available)"
fi

# Restart memcached to clear UI caches (fixes "Please wait..." spinner)
if docker ps -qf name=memcached-mailcow | grep -q .; then
  docker restart $(docker ps -qf name=memcached-mailcow) 2>/dev/null || true
  echo "Memcached restarted (UI cache cleared)"
fi

# Restart php-fpm to clear opcache
if docker ps -qf name=php-fpm-mailcow | grep -q .; then
  docker restart $(docker ps -qf name=php-fpm-mailcow) 2>/dev/null || true
  echo "PHP-FPM restarted"
fi

echo

# Step 10: Post-restore validation and health checks

echo "Step 10: Validating restore..."

# Wait for services to stabilize after restarts
sleep 5

DOMAIN_EXISTS=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs \
  -e "SELECT COUNT(*) FROM domain WHERE domain='${TARGET_DOMAIN}'" 2>/dev/null)

MAILBOXES=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs \
  -e "SELECT COUNT(*) FROM mailbox WHERE domain='${TARGET_DOMAIN}'" 2>/dev/null)

ALIASES=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs \
  -e "SELECT COUNT(*) FROM alias WHERE domain='${TARGET_DOMAIN}'" 2>/dev/null)

ALIAS_DOMAINS=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs \
  -e "SELECT COUNT(*) FROM alias_domain WHERE target_domain='${TARGET_DOMAIN}'" 2>/dev/null)

# Validation checks
VALIDATION_FAILED=0

if [[ ${DOMAIN_EXISTS} -lt 1 ]]; then
  echo "ERROR: Domain not found in database after restore"
  VALIDATION_FAILED=1
fi

if [[ ${MAILBOX_COUNT} -gt 0 ]] && [[ ${MAILBOXES} -lt 1 ]]; then
  echo "WARNING: Expected ${MAILBOX_COUNT} mailboxes but found ${MAILBOXES}"
fi

# Check if mailcow services are healthy
if ! docker exec $(docker ps -qf name=mysql-mailcow) mysql -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -e "SELECT 1" 2>/dev/null | grep -q "1"; then
  echo "ERROR: Cannot connect to database"
  VALIDATION_FAILED=1
fi

if [[ ${VALIDATION_FAILED} -eq 1 ]]; then
  echo ""
  echo "Restore validation FAILED. Please check the errors above."
  if [[ -n "${PREBACKUP_FILE}" ]] && [[ -f "${PREBACKUP_FILE}" ]]; then
    echo ""
    echo "Rollback instructions:"
    echo "docker exec -i \$(docker ps -qf name=mysql-mailcow) mysql -u${DBUSER} -p${DBPASS} ${DBNAME} < ${PREBACKUP_FILE}"
  fi
  exit 1
fi

echo "Validation checks passed"
echo

# Step 11: Summary and recommendations

echo
echo "Domain restore completed successfully!"
echo
echo "Restore Summary for ${TARGET_DOMAIN}:"
echo "- Domain exists: Yes"
echo "- Mailboxes: ${MAILBOXES}"
echo "- Aliases: ${ALIASES}"
if [[ ${ALIAS_DOMAINS} -gt 0 ]]; then
  echo "- Alias domains pointing to this domain: ${ALIAS_DOMAINS}"
fi
if [[ ${SOGO_CAL_COUNT} -gt 0 || ${SOGO_CONTACT_COUNT} -gt 0 ]]; then
  echo "- SOGo: ${SOGO_CAL_COUNT} calendar events, ${SOGO_CONTACT_COUNT} contacts, ${SOGO_PROFILE_COUNT} profiles"
fi
if [[ ${DKIM_FOUND} -eq 1 ]]; then
  echo "- DKIM key: Restored (selector: ${DKIM_SELECTOR})"
elif [[ ${SKIP_DKIM} -eq 1 ]]; then
  echo "- DKIM key: Not restored (not found in backup or no Redis backup)"
  echo "  → Generate via mailcow UI: Configuration → ARC/DKIM keys"
fi
if [[ ${SKIP_CRYPT} -eq 0 ]]; then
  echo "- mail_crypt: Keys restored from backup"
elif [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo "- mail_crypt: !!!  Keys differ but were NOT restored - mail may be unreadable!"
fi

if [[ -n "${PREBACKUP_FILE}" ]] && [[ -f "${PREBACKUP_FILE}" ]]; then
  echo ""
  echo "Pre-restore backup saved to:"
  echo "${PREBACKUP_FILE}"
  echo "Can be used to rollback if needed."
fi

if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo
  echo "Dovecot indexes were resynced and quotas recalculated during restore."
  echo "If mail still appears missing, run manually:"
  echo "docker exec \$(docker ps -qf name=dovecot-mailcow) doveadm force-resync -u \"*@${TARGET_DOMAIN}\" '*'"
  echo "docker exec \$(docker ps -qf name=dovecot-mailcow) doveadm quota recalc -u \"*@${TARGET_DOMAIN}\""
fi

echo
echo "Restore completed at: $(date)"
echo "All done!"
