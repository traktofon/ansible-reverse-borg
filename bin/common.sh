# vim: set ft=sh :

load_config () {
   # global parameters:
   # - MY_DIR: top-level directory of installation
   # positional parameters:
   # 1. filename of config file to load (relative to MY_DIR)
   # sets variables:
   # - MY_CONFIG: absolete path to config file
   # - all variables from MY_CONFIG
   local path="$1"
   MY_CONFIG="${MY_DIR}/${path}"
   if [ ! -r "${MY_CONFIG}" ]; then
      echo "ERROR: configuration file '${MY_CONFIG}' missing" >&2
      exit 1
   fi
   . "${MY_CONFIG}"
}


parse_args () {
   # sets variables:
   # - BACKUP_VOLUME: the backup volume to process
   # - EXTRA_ARGS: all remaining cmdline arguments, passed to client
   BACKUP_VOLUME="$1"
   [ -z "${BACKUP_VOLUME}" ] && usage
   shift
   EXTRA_ARGS="$@"
}


cleanup () { eval $(ssh-agent -k) >/dev/null ; }

start_ssh_agent () {
   # global parameters:
   # - MY_DIR: top-level directory of installation
   # - BACKUP_VOLUME: the backup volume to process
   # - BACKUP_CONNECT_WINDOW: lifetime of added keys
   eval $(ssh-agent -s -t "$BACKUP_CONNECT_WINDOW") >/dev/null
   trap cleanup EXIT
   ssh-add "${MY_DIR}/${BACKUP_VOLUME}/id_rsa" 2>/dev/null
}


set_borg_environment () {
   # global parameters:
   # - BACKUP_USER: from volume config
   # - BACKUP_SERVER: from server config or volume config
   # - BACKUP_REPO: from volume config
   # - BACKUP_CLIENT_SSH_OPTS: from server config or volume config
   # - BORG_PASSPHRASE: from volume config
   # exported variables:
   # - BORG_REPO: location of repo from client's view
   # - BORG_PASSPHRASE: as above
   # - BORG_RSH: ssh command to connect to server
   export BORG_REPO="${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REPO}"
   export BORG_PASSPHRASE
   export BORG_RSH="ssh ${BACKUP_CLIENT_SSH_OPTS}"
}


run_on_client () {
   # global parameters:
   # - BORG_RSH: ssh command to connect to server
   # - BACKUP_CLIENT: from volume config
   # - BACKUP_PORT: from volume config
   # - BACKUP_SSHKEY: from server config
   # positional parameters:
   # * all get passed to the client
   ssh -o StrictHostKeyChecking='accept-new' -o SendEnv='BORG_*' \
      -i "${BACKUP_SSHKEY}" -A \
      -p "${BACKUP_PORT}" "root@${BACKUP_CLIENT}" \
      "$@"
}
