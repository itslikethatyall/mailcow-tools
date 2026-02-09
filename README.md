# mailcow_tools
What will become a collection of tools for mailcow-dockerized. 

🐮 Obligatory make sure you take a backup of your Mailcow instance before restoring just in case. I'll try and keep up testing with Mailcow updates, but there's always a chance something changes or I've missed something, and especially since we're restoring into Mailcow's databases it's always better to be safe than sorry.

## Backup Restore Scripts

Currently only works with Mailcow's own backup (working on borg and have switched my own server to using it to give me the motivation, and Mailcow's borg implementation supports per-mailbox restore anyway I suppose). 

These scripts work by extracting the domain in question from the Mailcow backup, copying it to a staging directory, and then validating all changes will work prior to restoring things to Mailcow's MariaDB and Redis databases.

- you can use the `--force` flag if you wish to restore a domain/mailbox that already exists on the server
- you can use the `--confirm` flag if you wish to restore multiple domains/mailboxes sequentially without being prompted to check each time

### ⚠️ Important note about Dovecot mail_crypt

Please note these scripts are intended for restoring from backup to the same server they were on originally. Unfortunately because Mailcow uses Dovecot's mail_crypt with a global key instead of utilising per-user keys, you effectively cannot use these scripts to restore to a different server unless:

- you're happy overwriting mail_crypt (which on an existing server will result in you losing losing access to existing mailboxes encrypted using the old key)
- you don't use mail_crypt
- you used the same key on both servers

This script does support overwriting the mail_crypt using the keys in the backup though since I wanted to test restoring select domains from a backup made on my main server to my dev server before trying it live out of laziness. 

**Currently last tested both scripts against:** Mailcow 2026-01 (running on RHEL 9.7)

I put mine in the `helper-scripts` folder with Mailcow's scripts for ease of access (I use _ in the file name instead of - to differentiate mine from theirs), but should work anywhere.

### restore_domain.sh

Mailcow's backup and restore script isn't very flexible if you only want to domains as a whole, it's really all or nothing so this script allows per-domain restores and it will restore:

- Domain + domain aliases
- Mailboxes (incl passwords and mail)
- Mailbox Aliases
- App passwords
- Resources
- DKIM keys
- BCC policies
- Domain wide footers
- ⚠️ mail_crypt (see warning above)


#### Usage

```bash
./restore_domain.sh <backup_location> <domain_name> [--force] [--confirm]
```

**Examples:**

Restore a domain that doesn't exist:

```bash
./restore_domain.sh /backups/2026-02-06/mailcow-2026-02-06-21-17-15 example.com
```

Restore a domain that already exists:

```bash
./restore_domain.sh /backups/2026-02-06/mailcow-2026-02-06-21-17-15 example.com --force
```

Run without confirmation prompts:

```bash
./restore_domain.sh /backups/2026-02-06/mailcow-2026-02-06-21-17-15 example.com --silent
```



Optionally after restore:

```bash
docker exec $(docker ps -qf name=dovecot-mailcow) doveadm force-resync -u "*@example.com" '*'
```

### restore_mailbox.sh

Companion to restore_domain.sh which restores individual mailboxes from a backup without touching the rest of the domain. The target domain must already exist on the server.

Restores:

- Mailbox (incl password and mail)
- Mailbox aliases
- Sender ACL
- User ACL
- App passwords
- Sieve filters
- Mailbox tags

Does **not** restore domain-level items (DKIM, domain config, alias domains, BCC maps, domain footers, mail_crypt keys) — use restore_domain.sh for those.

#### Usage

```bash
./restore_mailbox.sh <backup_location> <mailbox_address> [--force] [--confirm]
```

**Examples:**

Restore a mailbox:

```bash
./restore_mailbox.sh /backups/2026-02-06/mailcow-2026-02-06-21-17-15 mailbox@example.com
```

Restore a mailbox that already exists:

```bash
./restore_mailbox.sh /backups/2026-02-06/mailcow-2026-02-06-21-17-15 mailbox@example.com --force
```

Skip confirmations:

```bash
./restore_mailbox.sh /backups/2026-02-06/mailcow-2026-02-06-21-17-15 mailbox@example.com --confirm
```

Optionally after restore:

```bash
docker exec $(docker ps -qf name=dovecot-mailcow) doveadm force-resync -u "mailbox@example.com" '*'
docker exec $(docker ps -qf name=dovecot-mailcow) doveadm quota recalc -u "mailbox@example.com"
```

### AppArmor
This works on RHEL with SELinux enforcing, but I've not tested on Ubuntu/Debian so if you have issues restoring with AppArmor enabled maybe try:

```bash
sudo aa-complain /etc/apparmor.d/docker
./restore_domain.sh /backup/path domain.com
sudo aa-enforce /etc/apparmor.d/docker
```