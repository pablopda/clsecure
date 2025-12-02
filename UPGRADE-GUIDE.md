# Upgrade Guide: Adding Namespace Isolation to clsecure

This guide shows how to enhance the existing `clsecure` script with namespace isolation (User + Namespace approach).

## Why Upgrade?

Your current `clsecure` script provides **user-level isolation** (6/10 security).
Adding namespace isolation gets you to **8/10 security** with minimal changes.

**What you gain:**
- Network isolation (prevents data exfiltration)
- Process isolation (Claude can't see/interfere with other processes)
- Capability restrictions (even if compromised, limited damage)
- Device isolation (no access to audio/video/hardware)
- Seccomp filters (dangerous syscalls blocked)

**What it costs:**
- Install firejail: `sudo apt install firejail` (2 minutes)
- Modify one line in script (30 seconds)
- Test on sample project (5 minutes)

**Total time**: ~10 minutes

---

## Option 1: Minimal Change (Recommended for Testing)

Just add firejail to the Claude invocation. This is the smallest possible change.

### Step 1: Install firejail

```bash
sudo apt install firejail
```

### Step 2: Find the Claude invocation line

Open `clsecure` and find line 541:

```bash
sudo -u "$WORKER_USER" bash -c "source ~/.bashrc && cd '$WORKER_PROJECT' && claude --dangerously-skip-permissions"
```

### Step 3: Add firejail wrapper

Replace that line with:

```bash
sudo -u "$WORKER_USER" bash -c "source ~/.bashrc && cd '$WORKER_PROJECT' && firejail --quiet --net=none --private-dev --private-tmp --noroot --caps.drop=all --seccomp --shell=none -- claude --dangerously-skip-permissions"
```

### Step 4: Test

```bash
cd ~/test-project
./clsecure
```

Inside Claude, verify isolation:

```bash
# Should fail (no network)
curl google.com

# Should fail (can't see other users' files)
ls /home/other-user/

# Should only see sandboxed processes
ps aux
```

### Done!

You now have User + Namespace isolation.

---

## Option 2: Configurable Network Access

If you need network sometimes (git push, npm install), make it configurable.

### Step 1: Add network flag variable

At the top of `clsecure` (around line 10), add:

```bash
ALLOW_NETWORK=false
```

### Step 2: Parse network flag

In the argument parsing section (around line 279), add:

```bash
case "${1:-}" in
    --help|-h)
        show_help
        ;;
    --list|-l)
        list_workers
        ;;
    --cleanup)
        cleanup_workers
        ;;
    --cleanup-all)
        cleanup_all_workers
        ;;
    --allow-network)  # <-- ADD THIS
        ALLOW_NETWORK=true
        ;;
esac
```

### Step 3: Conditional network isolation

Replace the Claude invocation (line 541) with:

```bash
# Build firejail network flag
NETWORK_FLAG=""
if [ "$ALLOW_NETWORK" = false ]; then
    NETWORK_FLAG="--net=none"
fi

# Run with conditional network access
sudo -u "$WORKER_USER" bash -c "source ~/.bashrc && cd '$WORKER_PROJECT' && firejail --quiet $NETWORK_FLAG --private-dev --private-tmp --noroot --caps.drop=all --seccomp --shell=none -- claude --dangerously-skip-permissions"
```

### Step 4: Update help text

In the `show_help` function, add:

```bash
OPTIONS:
    --help, -h      Show this help message
    --list, -l      List all claude-worker users and their status
    --cleanup       Interactively remove worker users
    --cleanup-all   Remove ALL claude-worker users (requires confirmation)
    --allow-network Allow network access (disables network isolation)  # <-- ADD THIS
```

### Usage

```bash
# Default: No network
./clsecure

# With network (for git push, npm install, etc.)
./clsecure --allow-network
```

---

## Option 3: Full Enhanced Version

Use the pre-built enhanced script with additional features.

### Step 1: Replace clsecure

```bash
cp clsecure clsecure-original-backup
cp clsecure-enhanced clsecure
```

### Step 2: Install firejail

```bash
sudo apt install firejail
```

### Usage

```bash
# Default: User + Namespace isolation
./clsecure

# With network
./clsecure --allow-network

# Basic user isolation only
./clsecure --mode user

# Show isolation details
./clsecure --info
```

---

## Testing Your Upgrade

After making changes, test isolation is working:

### Test 1: Network Isolation

```bash
./clsecure

# Inside Claude session:
curl google.com  # Should fail with "Network is down" or similar
```

**Expected**: Network blocked (unless you used `--allow-network`)

### Test 2: Process Isolation

```bash
# Open two terminals
# Terminal 1:
./clsecure

# Terminal 2:
ps aux | grep claude
# Note the PID of the claude process

# Back in Terminal 1 (Claude session):
ps aux
# Should NOT see the PID from terminal 2
# Should only see processes inside the sandbox
```

**Expected**: Can't see host processes

### Test 3: File Isolation

```bash
./clsecure

# Inside Claude session, try to access your real home:
ls /home/$(whoami)/

# Should see the worker user's home, not your actual home
```

**Expected**: Isolated filesystem view

### Test 4: Capability Restrictions

```bash
./clsecure

# Inside Claude session:
capsh --print

# Look for "Current:" line - should show no capabilities
```

**Expected**: `Current: =` (empty set of capabilities)

### Test 5: Device Isolation

```bash
./clsecure

# Inside Claude session:
ls -la /dev/

# Should see minimal devices (null, zero, urandom, etc.)
# Should NOT see: /dev/video*, /dev/audio*, /dev/snd*, etc.
```

**Expected**: Minimal /dev with no hardware devices

---

## Troubleshooting

### Problem: "firejail: command not found"

**Solution**: Install firejail

```bash
sudo apt install firejail
```

### Problem: "Cannot access /home/linuxbrew"

**Solution**: Firejail may be blocking needed paths. Add explicit bind mount:

```bash
firejail --bind=/home/linuxbrew --quiet ...
```

### Problem: "Permission denied" errors

**Solution**: Check that worker user owns the project directory:

```bash
sudo chown -R claude-worker-PROJECT:claude-worker-PROJECT /home/claude-worker-PROJECT/
```

### Problem: Claude can't find npm packages

**Solution**: Make sure npm global path is mounted. Check `$WORKER_BASHRC` has:

```bash
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
```

### Problem: Need network for git push/npm install

**Solution**: Use `--allow-network` flag:

```bash
./clsecure --allow-network
```

Or remove `--net=none` from firejail command temporarily.

### Problem: Performance is slow

**Solution**: Firejail has minimal overhead. If slow:
1. Check disk I/O (is /tmp full?)
2. Check if running on NFS/network filesystem (use local disk)
3. Try without `--private-tmp` if that's the bottleneck

### Problem: Environment variables not working

**Solution**: Firejail filters environment. Pass explicitly:

```bash
firejail --env=VAR=value ...
```

Or source the environment file inside the sandbox.

---

## Rollback Plan

If something breaks, rollback is easy:

### If you used Option 1 or 2:

```bash
# Edit clsecure, remove firejail from line 541
# Change back to:
sudo -u "$WORKER_USER" bash -c "source ~/.bashrc && cd '$WORKER_PROJECT' && claude --dangerously-skip-permissions"
```

### If you used Option 3:

```bash
cp clsecure-original-backup clsecure
```

Or just use `--mode user` flag:

```bash
./clsecure --mode user
```

---

## Verification Checklist

After upgrading, verify:

- [ ] Firejail installed: `firejail --version`
- [ ] Script modified: `grep firejail clsecure`
- [ ] Test run successful: `./clsecure` on test project
- [ ] Network blocked (default): Claude can't `curl google.com`
- [ ] Network works with flag: `./clsecure --allow-network` allows network
- [ ] Processes isolated: Can't see host processes in `ps aux`
- [ ] No capabilities: `capsh --print` shows empty set
- [ ] Normal workflow works: Can edit files, run git commands (with --allow-network)
- [ ] Changes sync back: After session, changes appear in main project
- [ ] Performance acceptable: No noticeable slowdown

---

## Next Steps

Once User + Namespace is working:

### For Maximum Security

Consider upgrading to Container + User Namespace (9/10 security):
- See `hybrid-isolation-evaluation.md` section on "Container + User Namespace"
- Build podman image with Claude CLI
- Use rootless containers

### For Better Workflow

Consider additional enhancements:
- Git pre-commit hooks to review changes
- Automatic backup before each session
- Logging of all Claude commands for audit trail
- Integration with IDE (VS Code remote)

### For Multiple Sessions

Consider Git Worktree approach:
- See `quick-reference.md` section on "Git Worktree + Namespace"
- Run multiple Claude instances safely
- Share git history, separate workspaces

---

## Comparison: Before and After

### Before (User isolation only)

```bash
# Security: 6/10
# Running as: claude-worker-project

Protections:
✓ Can't access other users' files
✓ Separate home directory
✗ Can access network freely
✗ Can see all processes
✗ Has capabilities (limited)
✗ Can access devices
```

### After (User + Namespace)

```bash
# Security: 8/10
# Running as: claude-worker-project inside firejail sandbox

Protections:
✓ Can't access other users' files
✓ Separate home directory
✓ Network blocked (--net=none)
✓ Process isolation (PID namespace)
✓ No capabilities
✓ No device access
✓ Seccomp filtering
✓ Private /dev and /tmp
```

---

## Advanced Configuration

### Customize Firejail Profile

Create `/etc/firejail/claude.profile`:

```bash
# Claude Code security profile
include /etc/firejail/default.profile

# Network (disable by default)
net none

# Filesystem
private-dev
private-tmp
noroot

# Capabilities
caps.drop all

# System calls
seccomp

# Misc
nodbus
nogroups
nosound
novideo
no3d
shell none
```

Use it:

```bash
firejail --profile=claude -- claude --dangerously-skip-permissions
```

### Fine-Grained Network Control

Allow only specific domains:

```bash
# This requires more advanced setup with firejail network namespaces
# See firejail documentation for details
```

### Resource Limits

Limit CPU and memory:

```bash
firejail --rlimit-cpu=3600 --rlimit-as=4G ...
```

### Logging and Audit

Enable firejail logging:

```bash
firejail --trace --tracelog=/tmp/firejail.log ...
```

Review what Claude accessed:

```bash
cat /tmp/firejail.log | grep open
```

---

## Summary

**Recommended upgrade path**:

1. **Start with Option 1** (minimal change) - 10 minutes
2. **Test thoroughly** on non-critical project - 30 minutes
3. **If successful, add Option 2** (configurable network) - 15 minutes
4. **Use daily, gain confidence** - 1 week
5. **Consider Container mode** if you need more security - Later

**Total investment**: ~1 hour
**Security improvement**: 6/10 → 8/10
**Workflow impact**: Minimal (transparent after setup)

**Result**: Defense-in-depth protection with minimal complexity.

---

## Questions?

- See full analysis: `hybrid-isolation-evaluation.md`
- See quick reference: `quick-reference.md`
- Test firejail wrapper: `./firejail-wrapper.sh --help`
- Use enhanced script: `./clsecure-enhanced --info`

**Bottom line**: Adding namespace isolation is worth it. The security gain is substantial, the complexity is minimal, and the workflow impact is near-zero.
