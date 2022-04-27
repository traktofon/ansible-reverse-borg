borgbackup-exec
===============

Installs the borgbackup binary from Github releases onto the host.

Requirements
------------

Tested with Ansible 2.9.27.


Role Variables
--------------

- `borg_version`: the version of borgbackup to install (default: 1.1.17)
- `borg_arch`: the architecture of the machine (default: linux64) [TODO: figure this out via ansible]
- `borg_checksum`: the expected checksum of the binary
- `target_directory`: where to install the binary (default: /usr/local/bin)


Dependencies
------------

None.


Example Playbook
----------------

```yaml
- hosts: localhost
  become: yes

  roles:
    - borgbackup-exec
```


License
-------

BSD


Author Information
------------------

Frank Otto <traktofon@fastmail.com>
