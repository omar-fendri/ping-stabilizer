# Ping Stabilizer

Adaptive latency stabilizer for cloud gaming on macOS. Reduces jitter by dynamically adjusting packet delay so your ping stays near a consistent target value.

## The Problem

Cloud gaming services like Amazon Luna are sensitive to **jitter** (variation in latency). A connection with ping values like `3, 4, 9, 33, 7, 88, 9 ms` causes stuttering and input lag spikes, even though the average is low.

## The Solution

This tool adds **adaptive delay** to outbound packets using macOS's built-in dummynet (`dnctl` + `pfctl`). Unlike Network Link Conditioner (which adds a **fixed** delay that just shifts all values up), this tool continuously measures your actual network RTT and adjusts the added delay per-measurement:

```
Target: 50ms

Network RTT:  3ms  + 47ms added = ~50ms total
Network RTT:  9ms  + 41ms added = ~50ms total
Network RTT: 33ms  + 17ms added = ~50ms total
Network RTT: 88ms  +  0ms added =  88ms (can't reduce, only add)
```

The result: most pings converge near your target, dramatically reducing jitter.

> **Note:** This tool can only **add** delay, never remove it. If a packet naturally takes longer than the target, it passes through unchanged. Set your target above your typical peak latency for best results.

## Requirements

- macOS (tested on 15.7.3 Sequoia)
- `sudo` access (dummynet and packet filter require root)
- Built-in tools only — no dependencies to install

## Quick Start

```bash
# Make executable (one time)
chmod +x ping-stabilizer.sh

# Run the full demo (baseline → stabilized → restored)
sudo ./ping-stabilizer.sh demo -t 50

# Or start/stop manually
sudo ./ping-stabilizer.sh start -t 50
sudo ./ping-stabilizer.sh stop
```

## Commands

### `start` — Enable stabilization

Measures baseline ping, configures adaptive delay, and launches a background monitor that continuously adjusts the delay.

```bash
sudo ./ping-stabilizer.sh start -t <target_ms> [-h <host>] [-c <count>]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-t, --target <ms>` | Target ping in milliseconds (required) | — |
| `-h, --host <addr>` | Host to measure baseline against | `8.8.8.8` |
| `-c, --count <n>` | Number of pings for baseline measurement | `10` |

**Examples:**
```bash
# Stabilize at 50ms, measure against Google DNS
sudo ./ping-stabilizer.sh start -t 50

# Stabilize at 100ms, measure against Cloudflare
sudo ./ping-stabilizer.sh start -t 100 -h 1.1.1.1

# Use 20 pings for more accurate baseline
sudo ./ping-stabilizer.sh start -t 50 -c 20
```

**What it does:**
1. Takes a snapshot of your current system state (pf rules, dummynet pipes)
2. Runs baseline ping measurements
3. Creates a dummynet pipe with calculated initial delay
4. Injects a pfctl anchor (isolated from your existing firewall rules)
5. Launches a background monitor that pings every 500ms and adjusts the delay
6. Shows a before/after comparison table

### `stop` — Disable stabilization

Cleanly reverses all changes and restores the system to its pre-start state.

```bash
sudo ./ping-stabilizer.sh stop
```

**What it does:**
1. Kills the background monitor process
2. Flushes the pfctl anchor rules
3. Restores the original main pf ruleset from backup
4. Releases the pf enable token
5. Deletes the dummynet pipe
6. Runs a verification ping to confirm cleanup

### `demo` — Before/during/after demonstration

Runs a full automated comparison testing against both Google DNS and AWS servers.

```bash
sudo ./ping-stabilizer.sh demo -t <target_ms> [-c <count>]
```

**What it does:**
1. **Phase 1 — Baseline:** Pings Google DNS and AWS with no stabilization
2. **Phase 2 — Stabilized:** Enables stabilization, pings both targets
3. **Phase 3 — Restored:** Disables stabilization, pings both to confirm cleanup
4. Prints a comparison table with min/avg/median/max/jitter for all phases

### `status` — Show current state

```bash
sudo ./ping-stabilizer.sh status
```

Shows whether the stabilizer is active, current target, monitor PID, last measured RTT, current applied delay, and active pfctl rules.

### `emergency-reset` — Force cleanup

Nuclear option for when `stop` fails (e.g., state files were deleted, system rebooted mid-session).

```bash
sudo ./ping-stabilizer.sh emergency-reset
```

**What it does:**
1. Kills the monitor process (and hunts for orphaned processes by name)
2. Flushes the pfctl anchor
3. Restores pf rules from snapshot, state backup, or `/etc/pf.conf` (in that order)
4. Releases any held pf tokens
5. Deletes the dummynet pipe
6. Removes state files
7. Runs verification to confirm the system is clean

## Safety

This tool modifies live network configuration. Multiple safety layers ensure you can always recover:

| Recovery level | Command | When to use |
|----------------|---------|-------------|
| Normal | `sudo ./ping-stabilizer.sh stop` | Standard shutdown |
| State files lost | `sudo ./ping-stabilizer.sh emergency-reset` | Stop won't work, reboot happened |
| Everything broken | `sudo pfctl -f /etc/pf.conf && sudo dnctl pipe 1 delete` | Absolute last resort |

### Safety features

- **Pre-change snapshots** saved to `.backups/` in the project directory (survives reboots)
- **pfctl anchor isolation** — your existing firewall rules are never modified directly
- **Reference-counted pf enable** (`pfctl -E` / `-X`) — won't accidentally disable your firewall
- **Rollback on setup failure** — if any step fails during `start`, previous steps are undone
- **Ctrl+C trap during demo** — interrupted demo auto-cleans all changes
- **Dual backup locations** — pf rules backed up to both `/tmp` (fast) and `.backups/` (persistent)

### What gets modified (and reversed)

| Component | Modified by `start` | Reversed by `stop` |
|-----------|--------------------|--------------------|
| Dummynet pipe 1 | Created with delay | Deleted |
| PF main ruleset | Anchor reference added | Original rules restored from backup |
| PF anchor `com.ping-stabilizer` | Dummynet out rule loaded | Flushed |
| PF enable state | Enabled via `-E` (ref counted) | Token released via `-X` |
| Background process | Monitor launched | Process killed |
| `/tmp/ping-stabilizer/` | State files created | Directory removed |

## How It Works

### Architecture

```
┌─────────────────────────────────────────────┐
│  ping-stabilizer.sh                         │
│                                             │
│  ┌──────────┐    ┌───────────────────────┐  │
│  │  start   │───>│  Background Monitor   │  │
│  │  stop    │    │                       │  │
│  │  demo    │    │  Every 500ms:         │  │
│  │  status  │    │  1. Ping target host  │  │
│  │  reset   │    │  2. Measure RTT       │  │
│  └──────────┘    │  3. Calc new delay    │  │
│                  │  4. Update dummynet   │  │
│                  └───────────────────────┘  │
│                           │                 │
│                           v                 │
│              ┌────────────────────────┐     │
│              │  dnctl pipe 1 config   │     │
│              │  delay ${new_delay}ms  │     │
│              └────────────────────────┘     │
│                           │                 │
│                           v                 │
│              ┌────────────────────────┐     │
│              │  pfctl anchor          │     │
│              │  dummynet out → pipe 1 │     │
│              └────────────────────────┘     │
└─────────────────────────────────────────────┘
```

### Adaptive delay algorithm

The background monitor runs this loop every 500ms:

1. Ping the target host once
2. Read the RTT from the reply
3. Calculate `new_delay = target - rtt` (minimum 0)
4. If the change exceeds 2ms (to avoid flapping), update the dummynet pipe
5. Write current stats to a file for the `status` command

### Why not a fixed delay?

A fixed delay (like Network Link Conditioner) adds the **same** delay to every packet:

```
Fixed +40ms delay:
  3ms  + 40ms = 43ms
  9ms  + 40ms = 49ms
  33ms + 40ms = 73ms
  88ms + 40ms = 128ms
  Jitter: 85ms (same as before!)
```

Adaptive delay adds a **different** delay based on current conditions:

```
Adaptive (target 50ms):
  3ms  + 47ms = ~50ms
  9ms  + 41ms = ~50ms
  33ms + 17ms = ~50ms
  88ms +  0ms =  88ms
  Jitter: reduced significantly for most packets
```

## Choosing a Target

| Target | Best for | Trade-off |
|--------|----------|-----------|
| 20-30ms | Low-latency connections (< 15ms baseline) | Small buffer, spikes still visible |
| 40-60ms | Typical home connections | Good balance for casual cloud gaming |
| 80-100ms | Connections with frequent spikes | Maximum stability, higher base latency |

**Rule of thumb:** Set the target ~10-20ms above your typical maximum ping (excluding rare outliers). Check your baseline with:

```bash
ping -c 20 8.8.8.8
```

## File Structure

```
ping-stabilizer/
├── ping-stabilizer.sh     # Main script (the only file you run)
├── README.md              # This file
└── .backups/              # Created at runtime — system state snapshots
    ├── latest -> snapshot_YYYYMMDD_HHMMSS
    └── snapshot_YYYYMMDD_HHMMSS/
        ├── pf_rules.txt
        ├── pf_nat.txt
        ├── pf_info.txt
        ├── pf_anchors.txt
        ├── dnctl_pipes.txt
        ├── etc_pf.conf
        └── pf_was_enabled.txt
```

## Limitations

- Can only **add** latency, never reduce it — packets above target pass through unchanged
- The adaptive monitor measures RTT every 500ms — very short bursts between measurements aren't compensated
- Applies to **all** outbound traffic (tcp/udp/icmp), not just gaming traffic
- macOS only (uses `dnctl` and `pfctl` which are macOS-specific)
- Requires `sudo` for every command (network stack modification needs root)
