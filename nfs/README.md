# NFS — Network File System

## Scenario

A shared storage server needs to export `/srv/shared` so that application
nodes can mount it and write logs centrally. The mount must survive reboots
and support multiple simultaneous clients.

Secondary requirement: the setup must be compatible with Kubernetes PersistentVolumes
(kubelet mounts as root — standard export options will silently break writes).

---

## How to Read an NFS Error

NFS errors show up in two places: the client's mount command output, and
the server's logs.

```bash
# Client — mount failure
mount -t nfs 192.168.1.10:/srv/shared /mnt/point
# mount.nfs: Connection timed out       → firewall or service down
# mount.nfs: access denied by server    → /etc/exports doesn't include client IP
# mount.nfs: No route to host           → network issue

# Server — check what's happening
journalctl -u nfs-server -n 50
exportfs -v                            # what's actually exported right now
showmount -e localhost                 # what the server advertises
```

---

## The 90% — NFS Failure Modes

### 1. Mount times out — service down or firewall blocking

**Symptom:**

```
mount.nfs: Connection timed out
```

NFS uses port 2049 (TCP/UDP). If the service is down or the firewall blocks
it, the mount just hangs until timeout.

**Diagnose:**

```bash
# On the server — is the service running?
systemctl status nfs-server

# Is port 2049 open?
ss -tlnp | grep 2049

# From the client — can you reach the port?
nc -zv 192.168.1.10 2049
```

**Fix:**

```bash
# Start the service
systemctl enable --now nfs-server

# Open the firewall on the server
firewall-cmd --add-service=nfs --permanent
firewall-cmd --reload

# Verify
showmount -e 192.168.1.10   # should list exports
```

---

### 2. Mount succeeds but writes fail — root_squash

**Symptom:** the mount works, you can see files, but writing fails with
`Permission denied`. This is the most common K8s NFS trap.

```bash
mount -t nfs 192.168.1.10:/srv/shared /mnt/point   # succeeds
echo "test" > /mnt/point/test.txt
# bash: /mnt/point/test.txt: Permission denied
```

**Root cause:** by default NFS uses `root_squash` — any request arriving
as UID 0 (root) is remapped to `nobody`. kubelet mounts volumes as root,
so without disabling this, all pod writes fail silently after the mount
appears successful.

**Diagnose:**

```bash
# On the server — check what options are active
exportfs -v
# /srv/shared  192.168.1.0/24(rw,sync,root_squash,...)
#                                      ↑ this is the problem
```

**Fix:**

```bash
# Edit /etc/exports
/srv/shared  192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
#                                                     ↑ allows root writes

# Reload exports without restarting (no disruption to active clients)
exportfs -r

# Verify
exportfs -v
```

---

### 3. Mount doesn't survive reboot — fstab missing

**Symptom:** everything works, you reboot, the mount is gone.

```bash
df -h | grep nfs   # nothing
mount | grep nfs   # nothing
```

**Fix:**

```bash
# Add to /etc/fstab on the client
echo "192.168.1.10:/srv/shared  /mnt/point  nfs  defaults  0 0" >> /etc/fstab

# Test without rebooting
mount -a        # mounts everything in fstab that isn't mounted yet
df -h /mnt/point
```

---

### 4. Stale file handle

**Symptom:** the mount exists but any operation on it hangs or returns an error:

```
ls: cannot access '/mnt/point': Stale file handle
```

This happens when the server restarted, the export path changed, or the
export was removed and re-added. The client still has the old NFS handle.

**Fix:**

```bash
# Unmount (force if it hangs)
umount /mnt/point
umount -f /mnt/point     # force if regular umount hangs
umount -l /mnt/point     # lazy unmount — detaches immediately, cleanup when idle

# Remount
mount -t nfs 192.168.1.10:/srv/shared /mnt/point
```

---

## /etc/exports Configuration

```
/srv/shared  192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
```

Key options:

| Option | Effect |
|---|---|
| `rw` | Read/write access |
| `sync` | Write to disk before ACKing (safer than `async`) |
| `no_subtree_check` | Eliminates subtree check overhead, reduces errors on renames |
| `no_root_squash` | Required for K8s — allows kubelet to write as root |
| `root_squash` | Default — remaps root to nobody |

### `exportfs -r` vs `exportfs -a`

| Command | Behavior |
|---|---|
| `exportfs -a` | Adds new exports — doesn't remove stale ones |
| `exportfs -r` | Re-syncs — adds new and removes stale entries |

Always use `exportfs -r` after editing `/etc/exports`.

---

## Key Commands

```bash
# Server
systemctl enable --now nfs-server
exportfs -r                              # reload after editing /etc/exports
exportfs -v                              # show active exports with options
showmount -e localhost                   # what the server advertises

# Client
mount -t nfs <server>:/path /mnt/point  # temporary mount
mount -a                                 # mount all fstab entries
df -h /mnt/point                         # verify mount
umount /mnt/point                        # unmount

# Firewall (server)
firewall-cmd --add-service=nfs --permanent
firewall-cmd --reload
```

## K8s Connection

An NFS-type PersistentVolume is exactly this setup. `ReadWriteMany` access mode
means multiple pods can mount the same export simultaneously — one of the few
storage backends that supports RWX natively.

```yaml
spec:
  nfs:
    server: 192.168.1.10
    path: /srv/shared
  accessModes:
    - ReadWriteMany
```

Without `no_root_squash` and correct export options, K8s storage issues are
invisible until writes silently fail or the disk fills. The mount appears
successful — the failure only shows up when a pod tries to write.
