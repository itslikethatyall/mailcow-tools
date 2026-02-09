#!/usr/bin/env bash
#
# 20260209 - Mailbox restore script for mailcow
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

# Restore individual mailbox from mailcow backup
# Usage: ./restore_mailbox.sh <backup_location> <mailbox_address> [--force] [--confirm]

# Validate arguments
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <backup_location> <mailbox@example.com> [--force] [--confirm]"
  echo ""
  echo "Example: $0 /backups/2026-02-06/mailcow-2026-02-06-21-17-15 mailbox@example.com"
  echo ""
  echo "Options:"
  echo "  --force         Overwrite existing mailbox"
  echo "  --confirm       Skip confirmations before restoring"
  echo ""
  echo "Note: The domain must already exist on the live server."
  echo "      Use restore_domain.sh to restore an entire domain first if needed."
  exit 1
fi

BACKUP_LOCATION="${1}"
TARGET_MAILBOX="${2}"
FORCE=0
CONFIRM_RESTORE=0

# Validate mailbox format (must contain @)
if [[ "${TARGET_MAILBOX}" != *"@"* ]]; then
  echo "ERROR: '${TARGET_MAILBOX}' is not a valid mailbox address."
  echo "Expected format: mailbox@example.com"
  echo ""
  echo "To restore an entire domain, use restore_domain.sh instead."
  exit 1
fi

# Split into local part and domain
TARGET_LOCAL="${TARGET_MAILBOX%%@*}"
TARGET_DOMAIN="${TARGET_MAILBOX##*@}"

if [[ -z "${TARGET_LOCAL}" || -z "${TARGET_DOMAIN}" ]]; then
  echo "ERROR: Invalid mailbox address '${TARGET_MAILBOX}'"
  exit 1
fi

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --confirm) CONFIRM_RESTORE=1 ;;
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
  echo "This script only supports native mailcow backups created by"
  echo "mailcow's built-in backup (backup_and_restore.sh)."
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

# Check for concurrent restores of the same mailbox

if [[ -f "${LOCK_FILE}" ]]; then
  LOCK_PID=$(cat "${LOCK_FILE}")
  if kill -0 "${LOCK_PID}" 2>/dev/null; then
    error_exit "Another restore for ${TARGET_MAILBOX} is already in progress (PID: ${LOCK_PID})"
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

echo "Restoring mailbox: ${TARGET_MAILBOX}"
echo "From backup: ${BACKUP_LOCATION}"
echo

# Step 1: Validate backup integrity and domain existence

echo "Step 1: Validating backup and live server..."

# Check if backup has required files
if [[ ! -d "${BACKUP_LOCATION}/mysql" && -z $(find "${BACKUP_LOCATION}" -maxdepth 1 -name "backup_mariadb*" 2>/dev/null) ]]; then
  error_exit "No MySQL/MariaDB backup found in backup location"
fi

if ! grep -q "^DBNAME=" "${BACKUP_LOCATION}/mailcow.conf"; then
  error_exit "Invalid mailcow.conf in backup - missing database configuration"
fi

# The domain MUST already exist on the live server
DOMAIN_EXISTS=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs -e "SELECT COUNT(*) FROM domain WHERE domain='${TARGET_DOMAIN}'" 2>/dev/null)

if [[ ${DOMAIN_EXISTS} -lt 1 ]]; then
  echo "ERROR: Domain '${TARGET_DOMAIN}' does not exist on the live server."
  echo ""
  echo "The domain must exist before restoring individual mailboxes."
  echo "Use restore_domain.sh to restore the entire domain first:"
  echo "  ./restore_domain.sh ${BACKUP_LOCATION} ${TARGET_DOMAIN}"
  error_exit "Domain '${TARGET_DOMAIN}' not found on live server"
fi

echo "Backup validation passed"
echo "Domain '${TARGET_DOMAIN}' exists on live server"
echo

# Step 2: Preparing backup database

echo "Step 2: Preparing backup database..."

if [[ -d "${BACKUP_LOCATION}/mysql" ]]; then
  echo "Found mysql directory backup, using it directly..."
  BACKUP_MYSQL_DIR="${BACKUP_LOCATION}/mysql"
else
  echo "Backup archive detected, will extract in container..."
  BACKUP_MYSQL_DIR=""
fi

echo

# Step 3: Extract mailbox-specific data from backup database

echo "Step 3: Extracting mailbox data from backup..."

# Write the SQL extraction query for a single mailbox
cat > "${TEMP_DIR}/mailbox_query.sql" << 'MBOXEOF'
SET sql_mode='';
SET FOREIGN_KEY_CHECKS=0;
USE mailcow;

-- Mailbox record
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
FROM mailbox WHERE username = '__TARGET_MAILBOX__';

-- Aliases where this mailbox is the address (direct aliases for this user)
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
FROM alias WHERE address = '__TARGET_MAILBOX__' OR goto LIKE '%__TARGET_MAILBOX__%';

-- Sender ACL entries for this mailbox
-- Schema: id, logged_in_as, send_as, external
SELECT CONCAT(
  'INSERT INTO sender_acl (logged_in_as, send_as, external) VALUES (',
  QUOTE(logged_in_as), ',',
  QUOTE(send_as), ',',
  QUOTE(external),
  ');'
) AS sql_stmt
FROM sender_acl WHERE logged_in_as = '__TARGET_MAILBOX__';

-- User ACL for this mailbox
-- Schema: username, spam_alias, tls_policy, spam_score, spam_policy, delimiter_action,
--         syncjobs, eas_reset, sogo_profile_reset, pushover, quarantine,
--         quarantine_attachments, quarantine_notification, quarantine_category, app_passwds, pw_reset
SELECT CONCAT(
  'INSERT INTO user_acl (username, spam_alias, tls_policy, spam_score, spam_policy, delimiter_action, syncjobs, eas_reset, sogo_profile_reset, pushover, quarantine, quarantine_attachments, quarantine_notification, quarantine_category, app_passwds, pw_reset) VALUES (',
  QUOTE(username), ',',
  QUOTE(spam_alias), ',',
  QUOTE(tls_policy), ',',
  QUOTE(spam_score), ',',
  QUOTE(spam_policy), ',',
  QUOTE(delimiter_action), ',',
  QUOTE(syncjobs), ',',
  QUOTE(eas_reset), ',',
  QUOTE(sogo_profile_reset), ',',
  QUOTE(pushover), ',',
  QUOTE(quarantine), ',',
  QUOTE(quarantine_attachments), ',',
  QUOTE(quarantine_notification), ',',
  QUOTE(quarantine_category), ',',
  QUOTE(app_passwds), ',',
  QUOTE(pw_reset),
  ') ON DUPLICATE KEY UPDATE spam_alias=VALUES(spam_alias), tls_policy=VALUES(tls_policy), spam_score=VALUES(spam_score), spam_policy=VALUES(spam_policy), delimiter_action=VALUES(delimiter_action), syncjobs=VALUES(syncjobs), eas_reset=VALUES(eas_reset), sogo_profile_reset=VALUES(sogo_profile_reset), pushover=VALUES(pushover), quarantine=VALUES(quarantine), quarantine_attachments=VALUES(quarantine_attachments), quarantine_notification=VALUES(quarantine_notification), quarantine_category=VALUES(quarantine_category), app_passwds=VALUES(app_passwds), pw_reset=VALUES(pw_reset);'
) AS sql_stmt
FROM user_acl WHERE username = '__TARGET_MAILBOX__';

-- App passwords for this mailbox
-- Schema: id(auto), mailbox, name, domain, password, created, modified, imap_access, smtp_access, dav_access, eas_access, pop3_access, sieve_access, active
SELECT CONCAT(
  'INSERT INTO app_passwd (mailbox, name, domain, password, created, modified, imap_access, smtp_access, dav_access, eas_access, pop3_access, sieve_access, active) VALUES (',
  QUOTE(mailbox), ',',
  QUOTE(name), ',',
  QUOTE(domain), ',',
  QUOTE(password), ',',
  QUOTE(created), ',',
  QUOTE(modified), ',',
  QUOTE(imap_access), ',',
  QUOTE(smtp_access), ',',
  QUOTE(dav_access), ',',
  QUOTE(eas_access), ',',
  QUOTE(pop3_access), ',',
  QUOTE(sieve_access), ',',
  QUOTE(active),
  ');'
) AS sql_stmt
FROM app_passwd WHERE mailbox = '__TARGET_MAILBOX__';

-- Sieve filters for this mailbox
-- Schema: id(auto), username, script_desc, script_name(ENUM active/inactive), script_data, filter_type(ENUM), created, modified
SELECT CONCAT(
  'INSERT INTO sieve_filters (username, script_desc, script_name, script_data, filter_type, created, modified) VALUES (',
  QUOTE(username), ',',
  QUOTE(script_desc), ',',
  QUOTE(script_name), ',',
  QUOTE(script_data), ',',
  QUOTE(filter_type), ',',
  QUOTE(created), ',',
  QUOTE(modified),
  ') ON DUPLICATE KEY UPDATE script_data=VALUES(script_data), filter_type=VALUES(filter_type), script_name=VALUES(script_name);'
) AS sql_stmt
FROM sieve_filters WHERE username = '__TARGET_MAILBOX__';

-- Mailbox tags for this user
SELECT CONCAT(
  'INSERT IGNORE INTO tags_mailbox (tag_name, username) VALUES (',
  QUOTE(tag_name), ',',
  QUOTE(username),
  ');'
) AS sql_stmt
FROM tags_mailbox WHERE username = '__TARGET_MAILBOX__';

-- =====================================================================
-- SOGo: Calendar, Contacts, and User Preferences
-- =====================================================================

-- Generate SOGo cleanup DELETEs (clear existing data before restore to avoid c_folder_id conflicts)
-- Order matters: dependent tables first, then folder_info last
SELECT 'DELETE FROM sogo_store WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 = ''__TARGET_MAILBOX__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_quick_appointment WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 = ''__TARGET_MAILBOX__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_quick_contact WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 = ''__TARGET_MAILBOX__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_acl WHERE c_folder_id IN (SELECT c_folder_id FROM sogo_folder_info WHERE c_path2 = ''__TARGET_MAILBOX__'');' AS sql_stmt;
SELECT 'DELETE FROM sogo_alarms_folder WHERE c_uid = ''__TARGET_MAILBOX__'';' AS sql_stmt;
SELECT 'DELETE FROM sogo_user_profile WHERE c_uid = ''__TARGET_MAILBOX__'';' AS sql_stmt;
SELECT 'DELETE FROM sogo_folder_info WHERE c_path2 = ''__TARGET_MAILBOX__'';' AS sql_stmt;

-- SOGo folder info (central folder registry)
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
FROM sogo_folder_info WHERE c_path2 = '__TARGET_MAILBOX__';

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
WHERE f.c_path2 = '__TARGET_MAILBOX__';

-- SOGo quick appointment cache (calendar events)
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
WHERE f.c_path2 = '__TARGET_MAILBOX__';

-- SOGo quick contact cache (contacts)
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
WHERE f.c_path2 = '__TARGET_MAILBOX__';

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
WHERE f.c_path2 = '__TARGET_MAILBOX__';

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
FROM sogo_alarms_folder WHERE c_uid = '__TARGET_MAILBOX__';

-- SOGo user profile (user preferences, timezone, display settings)
SELECT CONCAT(
  'INSERT INTO sogo_user_profile (c_uid, c_defaults, c_settings) VALUES (',
  QUOTE(c_uid), ',',
  QUOTE(c_defaults), ',',
  QUOTE(c_settings),
  ') ON DUPLICATE KEY UPDATE c_defaults=VALUES(c_defaults), c_settings=VALUES(c_settings);'
) AS sql_stmt
FROM sogo_user_profile WHERE c_uid = '__TARGET_MAILBOX__';
MBOXEOF

# Replace the placeholder with the actual mailbox address
sed -i "s/__TARGET_MAILBOX__/${TARGET_MAILBOX}/g" "${TEMP_DIR}/mailbox_query.sql"

# Build the correct mount options
if [[ -n "${BACKUP_MYSQL_DIR}" ]]; then
  MOUNT_OPTS="-v ${BACKUP_MYSQL_DIR}:/backup_source:ro"
else
  MOUNT_OPTS="-v ${BACKUP_LOCATION}:/backup_archive:ro"
fi

docker run --rm \
  ${MOUNT_OPTS} \
  -v "${TEMP_DIR}/mailbox_query.sql:/tmp/mailbox_query.sql:Z" \
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

    # Prepare the backup
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

    # Run the mailbox extraction query
    echo "Running mailbox extraction query..." >&2

    if ! OUTPUT=$(cat /tmp/mailbox_query.sql | mysql --socket=/tmp/mysql_backup.sock -u root -N 2>/tmp/query.err); then
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
      echo "WARNING: Query returned no results for mailbox" >&2
      echo "Checking available mailboxes in backup database..." >&2
      echo "AVAILABLE_MAILBOXES_START" >&2
      mysql --socket=/tmp/mysql_backup.sock -u root -N -e "SELECT username FROM mailcow.mailbox ORDER BY username;" >&2 2>&1 || true
      echo "AVAILABLE_MAILBOXES_END" >&2
    fi

    echo "$OUTPUT"

    # Cleanup
    echo "Cleaning up..." >&2
    kill $MYSQLD_PID 2>/dev/null || true
    wait $MYSQLD_PID 2>/dev/null || true
  ' 2>"${TEMP_DIR}/db_error.log" > "${TEMP_DIR}/mailbox_insert.sql"

# Check if extraction produced valid SQL
if [[ ! -s "${TEMP_DIR}/mailbox_insert.sql" ]] || ! grep -q "^INSERT INTO" "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null; then
  echo "Mailbox '${TARGET_MAILBOX}' was NOT found in the backup database."
  echo ""

  if grep -q "AVAILABLE_MAILBOXES_START" "${TEMP_DIR}/db_error.log" 2>/dev/null; then
    echo "Mailboxes available in this backup:"
    sed -n '/AVAILABLE_MAILBOXES_START/,/AVAILABLE_MAILBOXES_END/{/AVAILABLE_MAILBOXES/d;p}' "${TEMP_DIR}/db_error.log" | sed 's/^/  - /'
    echo ""
  else
    echo "Error output from database extraction:"
    echo "==========================================="
    cat "${TEMP_DIR}/db_error.log"
    echo "==========================================="
    echo ""
  fi
  error_exit "Mailbox '${TARGET_MAILBOX}' not found in backup. Check the address and try again."
else
  echo "Successfully extracted mailbox data"

  # Parse and show preview
  MAILBOX_COUNT=$(grep -c "INSERT INTO mailbox " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  ALIAS_COUNT=$(grep -c "INSERT INTO alias " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  SENDER_ACL_COUNT=$(grep -c "INSERT INTO sender_acl " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  USER_ACL_COUNT=$(grep -c "INSERT INTO user_acl " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  APP_PASSWD_COUNT=$(grep -c "INSERT INTO app_passwd " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  SIEVE_COUNT=$(grep -c "INSERT INTO sieve_filters " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  TAG_COUNT=$(grep -c "INSERT IGNORE INTO tags_mailbox " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  # Default to 0 if empty
  MAILBOX_COUNT=${MAILBOX_COUNT:-0}
  ALIAS_COUNT=${ALIAS_COUNT:-0}
  SENDER_ACL_COUNT=${SENDER_ACL_COUNT:-0}
  USER_ACL_COUNT=${USER_ACL_COUNT:-0}
  APP_PASSWD_COUNT=${APP_PASSWD_COUNT:-0}
  SIEVE_COUNT=${SIEVE_COUNT:-0}
  TAG_COUNT=${TAG_COUNT:-0}

  # SOGo calendar/contacts counts
  SOGO_CAL_COUNT=$(grep -c "INSERT INTO sogo_quick_appointment " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  SOGO_CONTACT_COUNT=$(grep -c "INSERT INTO sogo_quick_contact " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  SOGO_PROFILE_COUNT=$(grep -c "INSERT INTO sogo_user_profile " "${TEMP_DIR}/mailbox_insert.sql" 2>/dev/null || true)
  SOGO_CAL_COUNT=${SOGO_CAL_COUNT:-0}
  SOGO_CONTACT_COUNT=${SOGO_CONTACT_COUNT:-0}
  SOGO_PROFILE_COUNT=${SOGO_PROFILE_COUNT:-0}

  echo "Preview of data to be restored:"
  echo "  - Mailbox record: ${MAILBOX_COUNT}"
  [[ ${ALIAS_COUNT} -gt 0 ]] && echo "  - Aliases involving this mailbox: ${ALIAS_COUNT}"
  [[ ${SENDER_ACL_COUNT} -gt 0 ]] && echo "  - Sender ACL entries: ${SENDER_ACL_COUNT}"
  [[ ${USER_ACL_COUNT} -gt 0 ]] && echo "  - User ACL permissions: ${USER_ACL_COUNT}"
  [[ ${APP_PASSWD_COUNT} -gt 0 ]] && echo "  - App passwords: ${APP_PASSWD_COUNT}"
  [[ ${SIEVE_COUNT} -gt 0 ]] && echo "  - Sieve filters: ${SIEVE_COUNT}"
  [[ ${TAG_COUNT} -gt 0 ]] && echo "  - Mailbox tags: ${TAG_COUNT}"
  [[ ${SOGO_CAL_COUNT} -gt 0 ]] && echo "  - Calendar events/tasks: ${SOGO_CAL_COUNT}"
  [[ ${SOGO_CONTACT_COUNT} -gt 0 ]] && echo "  - Contacts: ${SOGO_CONTACT_COUNT}"
  [[ ${SOGO_PROFILE_COUNT} -gt 0 ]] && echo "  - SOGo user profile: ${SOGO_PROFILE_COUNT}"
fi

echo

# Step 4: Pre-restore validation - Check current state

echo "Step 4: Checking current mailbox state..."

MAILBOX_EXISTS=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs -e "SELECT COUNT(*) FROM mailbox WHERE username='${TARGET_MAILBOX}'" 2>/dev/null)

if [[ ${MAILBOX_EXISTS} -gt 0 ]]; then
  echo "Mailbox ${TARGET_MAILBOX} currently exists in mailcow"
  if [[ ${FORCE} -eq 0 ]]; then
    error_exit "Use --force flag to overwrite existing mailbox"
  fi

  # Create pre-restore backup of existing mailbox
  echo "Creating backup of current mailbox state before restore..."
  mkdir -p "${PREBACKUP_DIR}"

  PREBACKUP_FILE="${PREBACKUP_DIR}/${TARGET_MAILBOX}_$(date +%Y%m%d_%H%M%S).sql"
  docker exec $(docker ps -qf name=mysql-mailcow) mysql -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs -N -e "
    SELECT CONCAT('INSERT INTO mailbox (username, password, name, description, mailbox_path_prefix, quota, local_part, domain, attributes, custom_attributes, kind, multiple_bookings, authsource, created, modified, active) VALUES (', QUOTE(username), ',', QUOTE(password), ',', QUOTE(name), ',', QUOTE(description), ',', QUOTE(mailbox_path_prefix), ',', QUOTE(quota), ',', QUOTE(local_part), ',', QUOTE(domain), ',', QUOTE(attributes), ',', QUOTE(custom_attributes), ',', QUOTE(kind), ',', QUOTE(multiple_bookings), ',', QUOTE(authsource), ',', QUOTE(created), ',', QUOTE(modified), ',', QUOTE(active), ') ON DUPLICATE KEY UPDATE password=VALUES(password), name=VALUES(name), description=VALUES(description), quota=VALUES(quota), attributes=VALUES(attributes), custom_attributes=VALUES(custom_attributes), kind=VALUES(kind), active=VALUES(active);')
    FROM mailbox WHERE username='${TARGET_MAILBOX}';
    SELECT CONCAT('INSERT INTO alias (address, goto, domain, created, modified, private_comment, public_comment, sogo_visible, \`internal\`, sender_allowed, active) VALUES (', QUOTE(address), ',', QUOTE(goto), ',', QUOTE(domain), ',', QUOTE(created), ',', QUOTE(modified), ',', QUOTE(private_comment), ',', QUOTE(public_comment), ',', QUOTE(sogo_visible), ',', QUOTE(\`internal\`), ',', QUOTE(sender_allowed), ',', QUOTE(active), ') ON DUPLICATE KEY UPDATE goto=VALUES(goto), active=VALUES(active);')
    FROM alias WHERE address='${TARGET_MAILBOX}';
  " 2>/dev/null > "${PREBACKUP_FILE}"

  echo "Pre-restore backup created: ${PREBACKUP_FILE}"
else
  echo "Mailbox ${TARGET_MAILBOX} does not currently exist (new mailbox restore)"
fi

echo

# Step 5: Check vmail backup

echo "Step 5: Checking vmail backup..."

ARCHIVE_INFO=$(get_archive_info "backup_vmail" "${BACKUP_LOCATION}")
if [[ -z "${ARCHIVE_INFO}" ]]; then
  echo "Warning: No vmail backup found (will restore database only)"
  SKIP_VMAIL=1
else
  echo "Found vmail backup: $(echo ${ARCHIVE_INFO} | cut -d'|' -f1)"
  SKIP_VMAIL=0
fi

# Check mail_crypt keys (same as domain restore - it's global)
CRYPT_ARCHIVE_INFO=$(get_archive_info "backup_crypt" "${BACKUP_LOCATION}")
SKIP_CRYPT=1
CRYPT_MISMATCH=0
if [[ -z "${CRYPT_ARCHIVE_INFO}" ]]; then
  echo "No crypt backup found (mail_crypt keys not in backup)"
else
  echo "Found crypt backup: $(echo ${CRYPT_ARCHIVE_INFO} | cut -d'|' -f1)"

  CRYPT_ARCHIVE_FILE=$(echo "${CRYPT_ARCHIVE_INFO}" | cut -d'|' -f1)
  CRYPT_DECOMPRESS=$(echo "${CRYPT_ARCHIVE_INFO}" | cut -d'|' -f2)

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

  LIVE_PUBKEY=$(docker run --rm \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_crypt-vol-1$):/crypt:ro \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c 'cat /crypt/ecpubkey.pem 2>/dev/null || true' 2>/dev/null || true)

  if [[ -z "${BACKUP_PUBKEY}" ]]; then
    echo "  Warning: Could not read public key from crypt backup"
  elif [[ -z "${LIVE_PUBKEY}" ]]; then
    echo "  Warning: Could not read live mail_crypt public key"
    echo "  → Crypt keys may need restoring for mail to be readable"
    SKIP_CRYPT=0
  elif [[ "${BACKUP_PUBKEY}" == "${LIVE_PUBKEY}" ]]; then
    echo "mail_crypt keys match (backup == live) - restored mail will be readable"
  else
    echo "!!! WARNING: mail_crypt keys DIFFER between backup and live server!"
    echo "  Restored mail files were encrypted with a different key."
    echo "  Without restoring crypt keys, the restored mail will be UNREADABLE."
    echo "  Consider using restore_domain.sh which can restore crypt keys."
    CRYPT_MISMATCH=1
  fi
fi

echo

# Step 6: Initial confirmation

echo "About to restore mailbox: ${TARGET_MAILBOX}"
echo "This will:"
echo "  - Add/update mailbox record in database"
[[ ${ALIAS_COUNT} -gt 0 ]] && echo "  - Restore ${ALIAS_COUNT} alias(es) involving this mailbox"
[[ ${SENDER_ACL_COUNT} -gt 0 ]] && echo "  - Restore sender ACL entries"
[[ ${USER_ACL_COUNT} -gt 0 ]] && echo "  - Restore user ACL permissions"
[[ ${APP_PASSWD_COUNT} -gt 0 ]] && echo "  - Restore ${APP_PASSWD_COUNT} app password(s)"
[[ ${SIEVE_COUNT} -gt 0 ]] && echo "  - Restore ${SIEVE_COUNT} sieve filter(s)"
if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo "  - Restore mail files for this mailbox"
fi
if [[ ${SOGO_CAL_COUNT} -gt 0 || ${SOGO_CONTACT_COUNT} -gt 0 ]]; then
  echo "  - Restore SOGo calendars (${SOGO_CAL_COUNT} events) and contacts (${SOGO_CONTACT_COUNT})"
fi
if [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo "  - !!! mail_crypt keys differ - restored mail may be UNREADABLE"
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

# Step 7: FINAL CONFIRMATION

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "!!! FINAL CONFIRMATION - YOU ARE ABOUT TO MODIFY THE LIVE MAILCOW DATABASE ⚠️"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Mailbox: ${TARGET_MAILBOX}"
echo "Backup source: ${BACKUP_LOCATION}"
echo "Mailcow project: ${COMPOSE_PROJECT_NAME}"
echo ""
echo "This operation will:"
echo "Restore/modify mailbox record"
[[ ${ALIAS_COUNT} -gt 0 ]] && echo "Restore/modify ${ALIAS_COUNT} alias(es)"
[[ ${APP_PASSWD_COUNT} -gt 0 ]] && echo "Restore ${APP_PASSWD_COUNT} app password(s)"
if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo "Restore mail files - dovecot will be briefly stopped"
fi
if [[ ${SOGO_CAL_COUNT} -gt 0 || ${SOGO_CONTACT_COUNT} -gt 0 ]]; then
  echo "Restore SOGo calendars (${SOGO_CAL_COUNT} events) and contacts (${SOGO_CONTACT_COUNT})"
fi
if [[ ${MAILBOX_EXISTS} -gt 0 ]]; then
  echo "!!! This mailbox already exists - data will be OVERWRITTEN"
  if [[ -n "${PREBACKUP_FILE}" ]] && [[ -f "${PREBACKUP_FILE}" ]]; then
    echo "Pre-restore backup saved to: ${PREBACKUP_FILE}"
  fi
fi
if [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo "!!! mail_crypt keys differ - restored mail may be UNREADABLE"
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

echo "Step 8: Restoring mailbox to database..."

# Create a temporary SQL file with transaction wrapper
cat > "${TEMP_DIR}/final_restore.sql" << 'SQLEOF'
SET sql_mode='';
SET FOREIGN_KEY_CHECKS=0;
START TRANSACTION;
SQLEOF

cat "${TEMP_DIR}/mailbox_insert.sql" >> "${TEMP_DIR}/final_restore.sql"

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

# Ensure quota2 and quota2replica rows exist for this mailbox
echo "Ensuring quota tracking rows exist..."
docker exec -i $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -e "
  INSERT IGNORE INTO quota2 (username, bytes, messages)
    SELECT username, 0, 0 FROM mailbox WHERE username='${TARGET_MAILBOX}';
  INSERT IGNORE INTO quota2replica (username, bytes, messages)
    SELECT username, 0, 0 FROM mailbox WHERE username='${TARGET_MAILBOX}';
" 2>/dev/null || true

# Update _sogo_static_view for this mailbox
echo "Updating SOGo static view..."
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
  AND mailbox.username = '${TARGET_MAILBOX}'
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
SOGOEOF

if [[ $? -eq 0 ]]; then
  echo "SOGo static view updated"
else
  echo "⚠ Warning: Failed to update SOGo static view - SOGo login may not work"
fi

echo "Database restore completed"
echo

# Step 9: Restore vmail files for this mailbox only

if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo "Step 9: Restoring vmail files for ${TARGET_MAILBOX}..."

  ARCHIVE_INFO=$(get_archive_info "backup_vmail" "${BACKUP_LOCATION}")
  ARCHIVE_FILE=$(echo "${ARCHIVE_INFO}" | cut -d'|' -f1)
  DECOMPRESS_PROG=$(echo "${ARCHIVE_INFO}" | cut -d'|' -f2)

  echo "Stopping dovecot temporarily for vmail restoration..."
  DOVECOT_WAS_RUNNING=0
  if docker ps -qf name=dovecot-mailcow | grep -q .; then
    docker stop $(docker ps -qf name=dovecot-mailcow) 2>/dev/null || true
    DOVECOT_WAS_RUNNING=1
  fi

  # Extract only this mailbox's vmail from the backup archive
  # Mailbox path is typically /vmail/example.com/local_part/
  docker run -i --name mailcow-restore-mailbox --rm \
    -v "${BACKUP_LOCATION}:/backup:z" \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_vmail-vol-1$):/vmail:z \
    ${SQLIMAGE} \
    /bin/bash -c "${DECOMPRESS_PROG} < /backup/${ARCHIVE_FILE} | tar -Pxf - --wildcards '*/vmail/${TARGET_DOMAIN}/${TARGET_LOCAL}/*' 2>/tmp/tar_err.log || ${DECOMPRESS_PROG} < /backup/${ARCHIVE_FILE} | tar -Pxf - --wildcards '/vmail/${TARGET_DOMAIN}/${TARGET_LOCAL}/*' 2>/tmp/tar_err.log; cat /tmp/tar_err.log >&2" 2>"${TEMP_DIR}/vmail_extract.log" | grep -v "Removing leading" || true

  # Verify that mail files were actually extracted
  VMAIL_DIR_EXISTS=$(docker run --rm \
    -v $(docker volume ls -qf name=^${CMPS_PRJ}_vmail-vol-1$):/vmail:ro \
    --entrypoint="" \
    ${SQLIMAGE} \
    bash -c "[[ -d /vmail/${TARGET_DOMAIN}/${TARGET_LOCAL} ]] && echo yes || echo no" 2>/dev/null)

  if [[ "${VMAIL_DIR_EXISTS}" == "yes" ]]; then
    echo "Vmail files extracted"
  else
    echo "⚠ WARNING: Mailbox directory not found in vmail volume after extraction!"
    echo "  The backup archive may not contain mail for ${TARGET_MAILBOX},"
    echo "  or the archive path structure differs from expected."
    if [[ -s "${TEMP_DIR}/vmail_extract.log" ]]; then
      echo "  Extraction log:"
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
    if [[ -d /var/vmail/${TARGET_DOMAIN}/${TARGET_LOCAL} ]]; then
      chown -R vmail:vmail /var/vmail/${TARGET_DOMAIN}/${TARGET_LOCAL}
      chmod -R 700 /var/vmail/${TARGET_DOMAIN}/${TARGET_LOCAL}
    fi
  " 2>/dev/null || true

  # Force dovecot to rebuild indexes and recalculate quota for this user
  echo "Forcing dovecot index resync..."
  docker exec $(docker ps -qf name=dovecot-mailcow) doveadm force-resync -u "${TARGET_MAILBOX}" '*' 2>/dev/null || true
  echo "Dovecot indexes resynced"

  echo "Recalculating mailbox quota..."
  docker exec $(docker ps -qf name=dovecot-mailcow) doveadm quota recalc -u "${TARGET_MAILBOX}" 2>/dev/null || true
  echo "Quota recalculated"

  echo
fi

# Step 9b: Restart services to clear caches

echo "Restarting mailcow services to apply changes..."

if docker ps -qf name=sogo-mailcow | grep -q .; then
  docker restart $(docker ps -qf name=sogo-mailcow) 2>/dev/null || true
  echo "SOGo restarted (calendars/contacts available)"
fi

if docker ps -qf name=memcached-mailcow | grep -q .; then
  docker restart $(docker ps -qf name=memcached-mailcow) 2>/dev/null || true
  echo "Memcached restarted (UI cache cleared)"
fi

if docker ps -qf name=php-fpm-mailcow | grep -q .; then
  docker restart $(docker ps -qf name=php-fpm-mailcow) 2>/dev/null || true
  echo "PHP-FPM restarted"
fi

echo

# Step 10: Post-restore validation

echo "Step 10: Validating restore..."

sleep 5

MAILBOX_RESTORED=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs \
  -e "SELECT COUNT(*) FROM mailbox WHERE username='${TARGET_MAILBOX}'" 2>/dev/null)

ALIAS_RESTORED=$(docker exec $(docker ps -qf name=mysql-mailcow) mysql \
  -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -Bs \
  -e "SELECT COUNT(*) FROM alias WHERE address='${TARGET_MAILBOX}'" 2>/dev/null)

VALIDATION_FAILED=0

if [[ ${MAILBOX_RESTORED} -lt 1 ]]; then
  echo "ERROR: Mailbox not found in database after restore"
  VALIDATION_FAILED=1
fi

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
    echo "  docker exec -i \$(docker ps -qf name=mysql-mailcow) mysql -u${DBUSER} -p${DBPASS} ${DBNAME} < ${PREBACKUP_FILE}"
  fi
  exit 1
fi

echo "Validation checks passed"
echo

# Step 11: Summary

echo
echo "Mailbox restore completed successfully!"
echo
echo "Restore Summary for ${TARGET_MAILBOX}:"
echo "  - Mailbox exists: Yes"
echo "  - Aliases: ${ALIAS_RESTORED}"
if [[ ${SOGO_CAL_COUNT} -gt 0 || ${SOGO_CONTACT_COUNT} -gt 0 ]]; then
  echo "  - SOGo: ${SOGO_CAL_COUNT} calendar events, ${SOGO_CONTACT_COUNT} contacts"
fi
if [[ ${CRYPT_MISMATCH} -eq 1 ]]; then
  echo "  - mail_crypt: !!! Keys differ - restored mail may be unreadable!"
  echo "    → Use restore_domain.sh to restore crypt keys if needed"
fi

if [[ -n "${PREBACKUP_FILE}" ]] && [[ -f "${PREBACKUP_FILE}" ]]; then
  echo ""
  echo "Pre-restore backup saved to:"
  echo "  ${PREBACKUP_FILE}"
  echo "Can be used to rollback if needed."
fi

if [[ ${SKIP_VMAIL} -eq 0 ]]; then
  echo
  echo "Dovecot indexes were resynced and quota recalculated during restore."
  echo "If mail still appears missing, run manually:"
  echo "  docker exec \$(docker ps -qf name=dovecot-mailcow) doveadm force-resync -u \"${TARGET_MAILBOX}\" '*'"
  echo "  docker exec \$(docker ps -qf name=dovecot-mailcow) doveadm quota recalc -u \"${TARGET_MAILBOX}\""
fi

echo
echo "Restore completed at: $(date)"
echo "All done!"
