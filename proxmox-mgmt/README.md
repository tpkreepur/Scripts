# Ansible User Provisioning for Proxmox LXC Containers

These scripts prepare Linux containers in a Proxmox VE cluster for management by Ansible. They create an `ansible` service account with passwordless sudo and SSH key access, and install the packages Ansible needs on managed hosts.

Every script is idempotent: running it again only fixes what is missing and leaves correct configuration untouched.

## Contents

| File                    | Runs on               | Purpose                                                                             |
| ----------------------- | --------------------- | ----------------------------------------------------------------------------------- |
| `setup_ansible_user.sh` | Inside each container | Creates the `ansible` user, `unix_admin` group, sudoers rule, and `authorized_keys` |
| `install_packages.sh`   | Inside each container | Installs bash, sudo, shadow utilities, OpenSSH, and Python 3; enables SSH           |
| `run_on_containers.sh`  | A Proxmox node        | Finds every running LXC in the cluster and runs `setup_ansible_user.sh` in it       |

## What gets configured

After a successful run, each container has:

- A user `ansible` with a home directory and `/bin/bash` as its shell.
- A group `unix_admin`, with `ansible` as a member.
- `/etc/sudoers.d/unix_admin` (mode `0440`, owned by `root:root`) containing:

  ```ini
  %unix_admin ALL=(ALL) NOPASSWD: ALL
  ```

- `~ansible/.ssh/authorized_keys` (mode `0600`) containing the configured public key, inside `~ansible/.ssh` (mode `0700`).
- On Alpine, the `ansible` account's password field set to `*` so that sshd accepts key logins (see [Troubleshooting](#troubleshooting)).

## Requirements

**On the Proxmox node** where you run `run_on_containers.sh`:

- Root access.
- `jq` (install with `apt install jq` if missing).
- Root SSH between cluster nodes. A standard Proxmox cluster sets this up automatically.

**For each container:**

- It must be running. Stopped containers and templates are skipped.
- It must have an OS tag: `rocky`, `debian`, `ubuntu`, or `alpine`. Untagged containers are skipped.
- It needs network access to its package mirrors, if any packages have to be installed.

## Quick start

1. Copy all three scripts to one Proxmox node and make them executable:

   ```bash
   chmod +x setup_ansible_user.sh install_packages.sh run_on_containers.sh
   ```

2. Make sure your containers are tagged with their OS (see [Tagging containers](#tagging-containers)).
3. Preview what will happen:

   ```bash
   ./run_on_containers.sh --dry-run
   ```

4. Test on one OS first, then run on everything:

   ```bash
   ./run_on_containers.sh -t debian
   ./run_on_containers.sh
   ```

5. Confirm Ansible can connect (see [Verifying the result](#verifying-the-result)).

## Script reference

### `run_on_containers.sh`

Run this as root on any node in the cluster.

```bash
./run_on_containers.sh [-n] [-t TAG]... [-s PATH]

  -n, --dry-run       Show what would be done without changing anything
  -t, --tag TAG       Only target containers with this OS tag (repeatable)
  -s, --script PATH   Path to setup script (default: ./setup_ansible_user.sh)
  -h, --help          Show help
```

How it works:

1. It lists all LXC containers in the cluster with `pvesh get /cluster/resources`.
2. It skips templates, stopped containers, and containers without a matching OS tag.
3. For each remaining container, it runs `pct exec` directly on the local node, or through `ssh root@<node>` for containers on other nodes.
4. It installs the minimum prerequisites for that OS (`sudo`, plus `bash` and `shadow` on Alpine), then streams `setup_ansible_user.sh` into the container and runs it.
5. On Alpine, it unlocks the `ansible` account for SSH key login.
6. If one container fails, it continues with the next. At the end it prints a summary.

Output lines from each container are prefixed with the container's VMID, for example `[101]`.

Examples:

```bash
# Only Rocky and Alpine containers
./run_on_containers.sh -t rocky -t alpine

# Use a setup script stored somewhere else
./run_on_containers.sh -s /root/scripts/setup_ansible_user.sh
```

The `-s` script is passed to `bash -s` on stdin, so it must be a bash script. Do not use `-s` with `install_packages.sh`; see [Using `install_packages.sh` with the wrapper](#using-install_packagessh-with-the-wrapper).

Exit code: `0` if every targeted container succeeded, `1` if any failed or a preflight check failed.

### `setup_ansible_user.sh`

Run this as root inside a container. It requires `bash` and `sudo` to be installed already. Running `install_packages.sh` first takes care of that.

```bash
pct exec 101 -- bash -s < setup_ansible_user.sh
```

Steps, in order:

1. Create the `ansible` user if it doesn't exist.
2. Create the `unix_admin` group if it doesn't exist.
3. Add `ansible` to `unix_admin` if it isn't already a member.
4. Create `/etc/sudoers.d/unix_admin` if it doesn't exist. The rule is validated with `visudo -cf` before it is installed, and the full sudo configuration is checked afterwards with `visudo -c`. If the file already exists, it is left unchanged, and the script warns if it lacks the expected rule.
5. Verify the user, group membership, sudoers file permissions, and passwordless sudo. The script stops with an error if any check fails.
6. Create `~ansible/.ssh/authorized_keys` with the configured key. If the file already exists but lacks the key, the key is appended. Ownership and permissions are enforced, and SELinux contexts are restored where `restorecon` is available.

### `install_packages.sh`

Run this as root inside a container. **Run it with `sh`, from a file on disk.**

```bash
pct exec 101 -- sh -c 'cat > /tmp/install_packages.sh' < install_packages.sh
pct exec 101 -- sh /tmp/install_packages.sh
```

The script detects the OS from `/etc/os-release`, using `ID` first and then `ID_LIKE`. It does not use Proxmox tags. It installs only packages that are missing:

| OS family                              | Packages                                            |
| -------------------------------------- | --------------------------------------------------- |
| Debian, Ubuntu                         | `sudo`, `openssh-server`, `python3`                 |
| Rocky, AlmaLinux, CentOS, RHEL, Fedora | `sudo`, `openssh-server`, `python3`, `shadow-utils` |
| Alpine                                 | `bash`, `shadow`, `sudo`, `openssh`, `python3`      |

After installing, it enables and starts SSH through systemd or OpenRC. On newer Ubuntu releases that use `ssh.socket`, the socket is left in charge. Finally, it confirms that `bash`, `sudo`, `visudo`, `useradd`, `groupadd`, `usermod`, `python3`, and `sshd` are all available.

Why `sh` and a file: Alpine has no bash until this script installs it. The first block of the script is plain POSIX `sh`. It installs bash if needed, then re-runs the script file under bash. That re-run needs a path on disk, so piping the script on stdin is rejected with an error.

## Tagging containers

Tags can be set in the web UI (select the container, then click the pencil icon next to the tags in the header) or from the command line:

```bash
pct set 101 --tags debian
pct set 102 --tags "rocky;prod"      # multiple tags are separated by semicolons
```

`pct set` must run on the node that hosts the container. To check the tags across the whole cluster:

```bash
pvesh get /cluster/resources --type vm --output-format json \
  | jq -r '.[] | select(.type=="lxc") | "\(.vmid)\t\(.node)\t\(.status)\t\(.tags // "-")"'
```

## Using `install_packages.sh` with the wrapper

By default, `run_on_containers.sh` installs only the minimum needed to run the setup script. It does not install `openssh-server` or `python3`. To install the full package set on every container, replace the prerequisite step in the `process_ct` function of `run_on_containers.sh` (the `pct exec ... "$(prereq_cmd "${os}")"` command) with:

```bash
on_node "${node}" pct exec "${vmid}" -- sh -c 'cat > /tmp/install_packages.sh' < install_packages.sh \
    || { warn "[${vmid}] failed to copy install script"; return 1; }
on_node "${node}" pct exec "${vmid}" -- sh /tmp/install_packages.sh </dev/null 2>&1 \
    | sed "s/^/[${vmid}] /" \
    || { warn "[${vmid}] package installation failed"; return 1; }
```

Run the wrapper from the directory that contains `install_packages.sh`, or change the path in the snippet to point to it.

## Verifying the result

From the machine that holds the private key matching the configured public key:

```bash
# SSH login and passwordless sudo
ssh -i ~/.ssh/ansible_key ansible@<container-ip> 'sudo -n true && echo "sudo OK"'

# Ansible connectivity and privilege escalation
ansible all -i inventory.ini -u ansible --private-key ~/.ssh/ansible_key -m ping
ansible all -i inventory.ini -u ansible --private-key ~/.ssh/ansible_key -b -m command -a whoami
```

The last command should print `root` for every host.

## Customization

Settings are `readonly` variables at the top of each script:

| Script                  | Variable                                              | Default                               |
| ----------------------- | ----------------------------------------------------- | ------------------------------------- |
| `setup_ansible_user.sh` | `USER_NAME`                                           | `ansible`                             |
| `setup_ansible_user.sh` | `GROUP_NAME`                                          | `unix_admin`                          |
| `setup_ansible_user.sh` | `SUDOERS_RULE`                                        | `%unix_admin ALL=(ALL) NOPASSWD: ALL` |
| `setup_ansible_user.sh` | `SSH_PUBKEY`                                          | The provided RSA public key           |
| `install_packages.sh`   | `DEBIAN_PACKAGES`, `RHEL_PACKAGES`, `ALPINE_PACKAGES` | See the package table above           |

If you change `USER_NAME`, also change the Alpine unlock step in `run_on_containers.sh`, which refers to `ansible` by name.

`setup_ansible_user.sh` never modifies an existing sudoers file. If you change `SUDOERS_RULE`, delete `/etc/sudoers.d/unix_admin` on the affected containers before running it again, or edit the file there with `visudo -f`.

## Security considerations

- `NOPASSWD: ALL` gives full root access to anyone who can log in as `ansible`. Protect the matching private key accordingly, and consider restricting the rule to specific commands if your playbooks allow it.
- Sudoers changes are validated before installation, because a syntax error in a sudoers file can disable sudo for everyone.
- The `ansible` account has no usable password. Login is possible only with the SSH key.
- `run_on_containers.sh` relies on root SSH between cluster nodes and runs commands as root inside containers. Run it only from a trusted node.

## Troubleshooting

| Symptom                                                     | Likely cause and fix                                                                                                                                                        |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `jq not found`                                              | Install it on the Proxmox node: `apt install jq`.                                                                                                                           |
| A container is reported as `SKIPPED ... no matching OS tag` | Add the tag with `pct set <vmid> --tags <os>`, or check spelling. Tags must exactly match `rocky`, `debian`, `ubuntu`, or `alpine`.                                         |
| `SKIPPED ... stopped`                                       | Start the container with `pct start <vmid>` and run the wrapper again.                                                                                                      |
| SSH to another node fails                                   | Check cluster SSH with `ssh root@<node> true`. Running `pvecm updatecerts` can repair node keys.                                                                            |
| Package installation fails                                  | The container can't reach its mirrors. Check DNS and network inside the container, for example `pct exec <vmid> -- ping -c1 deb.debian.org`.                                |
| `Missing required command(s): visudo sudo`                  | `sudo` isn't installed in the container. Run `install_packages.sh` first, or use the wrapper, which installs it.                                                            |
| Verification fails on passwordless sudo                     | `/etc/sudoers` may not include the drop-in directory. Make sure it contains `@includedir /etc/sudoers.d` (or the older `#includedir /etc/sudoers.d`).                       |
| `Permission denied (publickey)` on Alpine                   | The account is still locked. Run `usermod -p '*' ansible` in the container. The wrapper does this automatically.                                                            |
| `Permission denied (publickey)` on other systems            | Check that `~ansible/.ssh` is `0700` and `authorized_keys` is `0600`, both owned by `ansible`. Also confirm sshd is running and that you're using the matching private key. |
| `install_packages.sh` says to run from a file               | It was piped on stdin. Copy it into the container and run `sh /tmp/install_packages.sh`.                                                                                    |
| Ansible reports that no Python interpreter was found        | `python3` isn't installed. Run `install_packages.sh` in that container.                                                                                                     |
