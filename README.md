## Overview

Here are a set of scripts and Ansible playbooks for setting up a backup service
using [Borg Backup](https://www.borgbackup.org/) in "reverse" or "pull" mode, i.e. backups
are controlled and initiated by the backup server instead of the client.
(A similar approach is described in the
[Borg documentation](https://borgbackup.readthedocs.io/en/stable/deployment/pull-backup.html#ssh-agent).)

The original philosophy of Borg is that the client initiates backups and stores
them (encrypted, if desired) on a potentially untrusted server (or other backup
location), which is a sensible approach for backing up home computers.
In an organisation however, there may well exist a trusted backup server,
whereas the clients are "untrusted" in the sense that they may not perform
regular backups by themselves, not take proper care of credentials, or even
be susceptible to ransomware. Therefore we like to set up a backup server
that will not just store the backups, but also keep the credentials for accessing
the stored backups (only allowing clients access as necessary) and schedule
regular backups of the client machines.

Here, the following approach is used:

* The backup server (referred to as `borgsrv`) hosts a dedicated user account
  (default name `borgadm`) which holds configuration and credentials for all
  backup clients and can initiate the backup process, as well as a number of
  other user accounts, one for each backup client, that store the actual
  backup data (so that data from different clients are isolated from each
  other).
* `borgsrv` and the clients communicate over SSH, using automatically created
  SSH keys for seamlessly establishing the secure communication channel.
* `borgsrv` initiates the backup process (or other related tasks) by ssh'ing
  into a backup client (as **root**), and there starting a local `borg` process which
  connects back to `borgsrv` (on an unprivileged, per-client account)
  with the standard Borg-over-ssh protocol for remote repositories.
* For each client, multiple backup "volumes" can be defined, which may cover
  different parts of the client's filesystems. This separation can be useful
  if different files need different backup schedules or retention policies.
  Technically, each volume will get stored in its own Borg repository.

Ansible is used here to deploy Borg, some scripts, and configuration to
the backup server and the clients. Ansible is not used (nor needed) to
perform the backups and related tasks.

## Demonstration

To demonstrate functionality, the `sample` directory provides an Ansible
playbook `provision.yml` which creates a few LXD containers (one backup server
and two backup clients) onto which the backup system can be deployed, along
with the corresponding Ansible inventory file `hosts.yml`.  
To run this demo, you'll need a working [LXD](https://linuxcontainers.org/lxd/)
setup, and need to adjust IP addresses in the two files under `sample` to
match your LXD subnet. (You can of course use other virtualization technologies
to run the demo, please adjust the provided inventory file as needed.)
You'll also need an SSH key pair, for logging in to the containers.

Tested to work with LXD 4.0.9 and Ansible 2.9.27.

First, run the provisioning playbook to create the containers:

    ansible-playbook sample/provision.yml -e cloud_private_key_file=/path/to/your/id_rsa

This creates an LXD profile `cloud-ops` with some cloud-init settings, so that Ansible
will be able to connect to the freshly created containers using the account `ops` and
the provided ssh key.

Next, deploy the backup system onto the server and client containers, using the
main playbook `playbook.yml`:

    ansible-playbook -i sample/hosts.yml playbook.yml -e cloud_private_key_file=/path/to/your/id_rsa

After this is finished (hopefully without errors), log in to backup server, e.g. with

    lxc exec borgsrv bash

then change to the `borgadm` account (which contains all the backup configuration
and scripts) and run an initial backup for all configured backup volumes (these
are defined in the inventory file):

    root@borgsrv:~# sudo -u borgadm -i
    borgadm@borgsrv:~$ cd backup-config/
    borgadm@borgsrv:~/backup-config$ bin/run-all ALL

This should proceed without any password or host key prompts, and finish quite
quickly (as there's not much data to back up). Next, you can check that indeed
some backups have been stored, e.g. for the `c02` client:

    borgadm@borgsrv:~/backup-config$ bin/run-borg c02 list

As a next step, back on the host machine, connect to the `c02` client (e.g.
via `lxc exec c02 bash`) and create some important data:

    root@c02:~# echo 'important' > /home/data.txt

Then, back on the `borgsrv` server, perform another backup for `c02`:

    borgadm@borgsrv:~/backup-config$ bin/run-backup c02

To simulate a disaster, back on the host, nuke the `c02` container:

    lxc stop c02
    lxc rm c02

Now we can run the provisioning playbook again (to similate having set up
the client machine anew), as well as the deployment playbook; the latter run
can be (but doesn't have to be) limited to the `c02` client tasks, for faster
operation:

    ansible-playbook sample/provision.yml -e cloud_private_key_file=/path/to/your/id_rsa
    ansible-playbook -i sample/hosts.yml playbook.yml -e cloud_private_key_file=/path/to/your/id_rsa -l c02

Now you have a fresh `c02` client, and so far it's been set up to accept
connections from the backup server. But all the "important" data on `c02`
is gone! Let's try to get it back.

Back on `borgsrv`, open an interactive shell to `c02` which is preconfigured with an environment
to seamlessly access its own backup repo on the server:

    borgadm@borgsrv:~/backup-config$ bin/shell c02

In this shell, check what backups are available:

    root@c02:~# borg list

You'll get a warning about a "previously unknown unencrypted repository", which is
correct, as the reinstalled client hasn't interacted with this repository yet.
Answer "y" to indicate that you trust this repository.

Select the archive with the latest timestamp (in `yyyy-mm-dd_HHMM` format),
and restore the data as usual with `borg extract` (see the
[Borg documentation](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)
for details):

    root@c02:~# cd /
    root@c02:/# borg extract ::yyyy-mm-dd_HHMM home/data.txt

Check that `/home/data.txt` has been restored with all the "important" information.

To clean up after the demo, use `lxc stop` and `lxc rm` on the containers
`borgsrv`, `c01`, `c02`, and finally remove the created profile via
`lxc profile rm cloud-ops`.


## Configuration

All configuration is done via the Ansible inventory file.
A commented example is provided in the file `sample/hosts.yml`.

There must be two inventory groups, `servers` and `clients`.

* Group `servers` must contain a single host with inventory name `borgsrv`.
  Set its `ansible_host` variable to its actual DNS name or IP address.
  (But see below note if using DNS names.)
  The following host variables should be set:
  - `backup_operator_account`:
    The user that owns the backup config for all clients, and will
    initiate backups in day-to-day operations. In theory could be 
    `root`, but maybe that's not such a good idea.
  - `config_directory`:
    The directory where the config files and scripts are stored.
  - `backup_directory`:
    The directory where all the backup repositories will be stored.
    Should be on a filesystem with sufficient space.

  The account and directories will be created during server deployment
  via Ansible.

* Group `clients`, where each client's inventory name should be
  short (and without spaces or special characters) but unique across
  the server.  This name will be used to name several client-related
  items on the server, e.g. the client `c01` will get a user account
  `borg-c01` on the server. Set `ansible_host` to the client's actual
  name/IP, and also `ansible_port` if not on the standard SSH port 22.
  The following host variables should be set:
  - `volumes`:
    A list of separate backup "volumes" which might have different
    backup schedules or retention policies etc. Each volume will be
    stored in its own borg repository. A volume has a `name` (an
    identifier that must be unique across the server; avoid spaces and
    special characters) and a `paths`
    setting (space-separated list of paths to be backed up into this
    repository).  The `name` is what needs to be passed to the
    provided scripts (see below).
  - `deploy_borg` (optional):
    Boolean to control whether to deploy the borg binary or not.
    Defaults to true.
  - `ssh_opts` (optional):
    To override the ssh options that the client uses to connect to
    the server. E.g. for older machines, may need to be set to
    "-o StrictHostKeyChecking=no". The default is to use "accept-new"
    for this option.
  - `ssh_key_restrictions` (optional):
    The restrict clauses to put on the server's public key on the
    client side. Default is "restrict,agent-forwarding,pty". May need
    to be changed for older machines. "agent-forwarding" is strictly
    needed. "pty" is needed only for shell access and could be dropped
    to increase security of the client against the server.
  - `ssh_service_name` (optional):
    The name of the sshd service. Default is "sshd". May need to be
    changed to `ssh` or `openssh-server` or similar, depending on the
    operating system of the client machine.

**Note**: If using DNS names instead of IP addresses for `ansible_host`, then
`sshd` must be configured with the `UseDNS` option, and the DNS names must be
the "official" ones (i.e. what you get when reverse-resolving the IP).
Otherwise the "from" restrictions on the `authorized_keys` lines will prevent
communication between client and server. Alternatively, you can edit the
playbooks to drop adding such "from" restrictions, which would slightly
increase attack surface.

During deployment, Ansible will install a Borg binary from the
[Github releases page](https://github.com/borgbackup/borg/releases)
onto the server and the clients. For a client this can be prevented by
setting the host variable `deploy_borg` to false, in which case you
must install `borg` on that client via other means. The binary
installation happens via the included Ansible role found under
`playbooks/roles/borgbackup-exec` where the Borg version to use and
other settings can be controlled via variables in `defaults/main.yml`.
For now, Borg version 1.1.17 is deployed.  Note that Borg branch 1.2.x
seems to have changes in how pruning data from repositories is handled,
which may require changes to the scripts here.


## Deployment

After setting up the inventory file as described above, the whole
backup system can be deployed onto the server and the clients by
running the Ansible playbook:

    ansible-playbook -i your-inventory.yml playbook.yml

The playbook makes extensive use of `delegate_to` to perform tasks
that need to be done on the server but for each client (or for each
volume on each client). Such tasks are deliberately serialized, to
guard against race conditions. Therefore executing the whole playbook
may take some time if there are a lot of backup clients/volumes.

The playbook is designed to be idempotent, i.e. running it again should
not cause any changes (unless the inventory has changed). Also the playbook
can be run in Ansible's `--check` mode, to see if anything would change.

Playbook execution can be sped up via restricting what you
want done, as follows:

* To only run the deployment of the server, use option `--tags server`.
* To only run client-specific deployments, use option `--tags client`. Note
  that this still runs some tasks on the server via `delegate_to`.
* To only run deployments for one specific client (e.g. after adding a new
  backup client to the inventory), use Ansible's `--limit` option.


## Config directory layout

The `config_directory` is laid out as follows:

* `bin`: Scripts, described further below.
* `etc`: Server-side configuration files.
  * `backup.conf`: Default settings, which can be overridden in the client config.
  * `sshid_borg`: Private SSH key for logging into the clients.
  * `sshid_borg.pub`: Associated public key.
* `volumes`: One configuration directory for each client volume, containing:
  * `config`: Configuration settings for this client and volume.
  * `id_rsa`: Private SSH key for logging into the server.
  * `id_rsa.pub`: Associated public key.
  * `patterns`: List of Borg exlude patterns, to avoid backing up certain files.
* `groups`: Configuration files for backup groups, for the `run-all` script.

Usually there should be no need to manage these files yourself, as they
are all deployed via Ansible. However, the Ansible playbook will not clobber these
files if you've modified them. For the `patterns` file, a file with sensible
default settings is deployed, but you may want to adjust these depending on the
nature of the files being backed up.


## Performing backups and related tasks

The `bin` directory holds a number of scripts for conveniently
performing backups and related tasks. During deployment this directory
is copied to the backup server, to the `config_directory`. The scripts
should be executed under the `backup_operator_account` account (default
`borgadm`).

The scripts that run `borg` on the client pass some configuration
information via environment variables of the form `BORG_*`. The Ansible
playbook adjusts the client's SSH server configuration so that passing
such environment variables via SSH is allowed.

A description of the scripts follows.

### bin/run-backup

`run-backup` creates a new backup archive for a given volume.
It takes one mandatory argument, the volume name (as configured
in the inventory), and optionally any further arguments will be passed to
`borg create` running on the client, e.g. `--progress --stats`.

The backup archive is named with a timestamp in the format `yyyy-mm-dd_HHMM`.

Prior to running `borg create`, the file with exclude patterns is copied
to the client via `scp` into a temporary location.

### bin/run-prune

`run-prune` is used to delete old archives according to a retention
policy, and deletes unused data from the repository.
It also takes the volume name as mandatory argument, and any
additional arguments are passed to `borg prune` running on the client.
The prune schedule is defined in the volume config file (found in the
`volumes` subdirectory) and defaults to keeping daily backups for 4
weeks and weekly backups for a further 12 weeks.

### bin/run-borg

`run-borg` is used to run any other Borg command on the client.
It also takes the volume name as mandatory argument, and any
further arguments are passed to `borg` running on the client.
Example, with a volume name "c01-etc", running

    bin/run-borg c01-etc list

will list all available backup archives for this volume, or

    bin/run-borg c01-etc list ::yyyy-mm-dd_HHMM

will list all the files stored in the given backup archive. (Note the
literal double colon before the archive name; the location of the remote
Borg repository is passed to the client via the environment variable
`BORG_REPO`.)

### bin/shell

`shell` can be used to open an interactive shell on the client. Like for
the scripts above, `BORG_*` environment variables are passed over SSH,
so that you could e.g. run `borg list` to list available archives.

### bin/run-all

`run-all` is used to perform backups and pruned for several volumes in sequence.
It takes one mandatory argument, a group name _grp_ with associated 
configuration in "groups/_grp_.conf". Any further arguments are passed
to `run-backup` and `run-prune` (e.g. `--progress`).

Ansible creates the group `ALL` which contains all the volumes defined on the server.
You could use

    bin/run-all ALL

to perform backups and prunes for all volumes. However, this way all these tasks
are done in sequence, so a single slow backup client could delay the backups for
many other clients. Therefore it is recommended to create several group config files
under the `groups` directory; please see the default `ALL.conf` file there for syntax.
You can then have several `run-all` jobs running in parallel, so that multiple volumes
are backed up in parallel. (This is safe, as each volume has its own repository.)

How many backups you can run in parallel depends on bandwidth and I/O performance
limits of the server, and on how frequently data changes on the clients -- unchanged
clients cause basically zero load on the server. If total RAM on the server is low,
you should also watch out for combined RAM usage of the running borg processes.


## Performing restores

Currently this is easiest done via the `bin/shell` script, to open an
interactive shell on the client. Then run `borg extract` there to retrieve
files from the desired archive. Usually it is recommended to restore files
into a temporary location and move them as needed after the restore is
finished.


## Security Considerations

By itself, a backup client is not able to connect to the server and to
access its own backup repositories. This is to guard against accidental
or deliberate destructions of the backups by the client.
When the server initiates a backup (or other Borg task), it starts an
ssh-agent, loads a volume-specific key into the agent, and forwards the
agent connection via ssh to the client. Then the `borg` process running
on the client uses this to connect to the server. To minimize potential
of abuse of this forwarded connection, the key is loaded into the agent
with a short lifetime, by default 60 seconds. This is set in the server
configuration file `etc/backup.conf` and can be overriden per volume
in the file `volumes/.../config` via the variable `BACKUP_CONNECT_WINDOW`.
It may be necessary to increase this window for clients that have slow
drives and tend to suffer from high I/O load, as under such conditions starting
all required processes on the client may take longer than 60 seconds.
**Note**: As the `bin/shell` script is intended for interactive use, it
sets `BACKUP_CONNECT_WINDOW` to one hour.

Borg repositories are created here with the "encryption" mode
`authenticated_blake2`, as we consider the server to be trusted.
This setting does **not** encrypt data in the repositories, but
authenticates the repository data, so that accidental modification or
corruption of the repository data can be detected. The encryption
mode could be changed by modifying the call to `run-borg ... init` at the
bottom of the `playbooks/client-setup.yml` file.

