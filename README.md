# Ping Stabilizer

Network diagnostic and latency stabilization toolkit for cloud gaming on macOS. Built for Amazon Luna but works with any cloud gaming service.

## What We Discovered

While building this tool we learned that **the #1 cause of cloud gaming stuttering on Mac is not jitter — it's AWDL** (Apple Wireless Direct Link). AWDL is used by AirDrop/AirPlay and periodically hijacks your WiFi radio to scan on a different channel, causing ~100ms packet dropouts.

### Quick Fix (No Tool Needed)

```bash
# Disable AWDL before gaming — stops WiFi channel hopping
sudo ifconfig awdl0 down

# Re-enable after gaming — restores AirDrop/AirPlay
sudo ifconfig awdl0 up
```

AWDL re-enables automatically on reboot. This alone may fix your stuttering entirely.

### When the Stabilizer Helps

If you still experience variable latency after disabling AWDL (common on congested WiFi or long-distance servers), the stabilizer smooths out jitter by adding adaptive delay. It's most effective when:
- Your ping to the game server varies widely (e.g., 5ms to 80ms)
- The game server is distant (high base RTT with spikes)
- You can't use a wired connection

## Requirements

- macOS (tested on 15.7.3 Sequoia)
- `sudo` access (network stack modification requires root)
- Built-in tools only — no dependencies to install

## Quick Start

```bash
chmod +x ping-stabilizer.sh

# Diagnose your connection first
./ping-stabilizer.sh baseline
sudo ./ping-stabilizer.sh detect snap           # find game server IP (while playing)
sudo ./ping-stabilizer.sh measure -h <server>   # measure real RTT + dropouts

# If stabilizer is needed
sudo ./ping-stabilizer.sh start -t 50
sudo ./ping-stabilizer.sh stop
```

## Commands

### `baseline` — Measure jitter to a pingable host

No sudo required. Runs 20 pings and reports min/avg/median/max, jitter, standard deviation, stability score, and a recommendation.

```bash
./ping-stabilizer.sh baseline
./ping-stabilizer.sh baseline -h dynamodb.us-east-1.amazonaws.com
./ping-stabilizer.sh baseline -h 8.8.8.8 -c 50
```

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --host <addr>` | Host to ping | `8.8.8.8` |
| `-c, --count <n>` | Number of pings | `20` |

### `detect` — Find game server IP

Uses `tcpdump` to capture live network traffic and identify the game streaming server by packet volume.

```bash
# Quick snapshot while game is running
sudo ./ping-stabilizer.sh detect snap

# Interactive: captures before and after game launch
sudo ./ping-stabilizer.sh detect
```

**Snap mode** captures 5 seconds of UDP traffic and ranks external IPs by packet count. The top talker (thousands of packets) is your game streaming server.

**Watch mode** takes a baseline before you start the game, then captures again after — showing only new connections.

### `measure` — Measure RTT and dropouts from live traffic

For servers that block ping (like Luna's). Uses `tcpdump` timestamps to estimate RTT from actual game packets, and detects gaps in the incoming stream that cause stuttering.

```bash
sudo ./ping-stabilizer.sh measure -h 63.178.107.163
sudo ./ping-stabilizer.sh measure -h 63.178.107.163 -d 30    # 30 second capture
```

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --host <ip>` | Server IP (required, use `detect` to find) | — |
| `-d, --duration <sec>` | Capture duration | `10` |

Output includes:
- **Traffic analysis**: packets in/out, data volume, duration
- **Dropout detection**: gaps >50ms, >100ms, >200ms in the incoming stream, longest gap
- **RTT estimation**: min/avg/median/max/jitter/stddev from packet pair timing

### `start` — Enable ping stabilization

Measures baseline, configures adaptive delay via dummynet, and launches a background monitor.

```bash
sudo ./ping-stabilizer.sh start -t 50
sudo ./ping-stabilizer.sh start -t 100 -h dynamodb.us-east-1.amazonaws.com
```

| Option | Description | Default |
|--------|-------------|---------|
| `-t, --target <ms>` | Target ping in ms (required) | — |
| `-h, --host <addr>` | Host for baseline and adaptive monitoring | `8.8.8.8` |
| `-c, --count <n>` | Pings for baseline measurement | `10` |

**What it does:**
1. Saves a full system snapshot (pf rules, dummynet pipes)
2. Measures baseline ping to `-h` host
3. Calculates initial delay = target - median baseline
4. Creates a dummynet pipe and pfctl anchor
5. Launches a background monitor that adjusts delay every 200ms using EWMA smoothing

**Important:** The `-h` host is what the monitor pings to adapt the delay. All traffic gets the same delay, but it's optimized for the `-h` host's latency. Choose the host that matters most (game server proxy or nearby AWS endpoint).

### `stop` — Disable stabilization

```bash
sudo ./ping-stabilizer.sh stop
```

Kills the monitor, removes pfctl anchor, restores original pf rules from backup, releases the pf token, deletes the dummynet pipe, and verifies cleanup.

### `status` — Show current state

```bash
sudo ./ping-stabilizer.sh status
```

Shows whether the stabilizer is active, target, monitor PID, measured RTT, smoothed RTT (EWMA), current delay, and active pfctl rules.

### `demo` — Before/during/after demonstration

```bash
sudo ./ping-stabilizer.sh demo -t 50
sudo ./ping-stabilizer.sh demo -t 100 -h dynamodb.us-east-1.amazonaws.com
```

Runs a full automated comparison: baseline pings, enables stabilization, pings again, disables, pings again. Tests against both Google DNS and AWS. Shows a comparison table with jitter reduction.

### `emergency-reset` — Force cleanup

```bash
sudo ./ping-stabilizer.sh emergency-reset
```

Nuclear option for when `stop` fails. Works even if state files are missing:
1. Kills monitor processes (and hunts orphans by name)
2. Flushes the pfctl anchor
3. Restores pf rules from snapshot, backup, or `/etc/pf.conf`
4. Deletes dummynet pipe
5. Verifies system is clean

## How the Stabilizer Works

### The Problem with Fixed Delay

Network Link Conditioner and similar tools add a **fixed delay** to all packets. This just shifts everything up — jitter stays the same:

```
Fixed +40ms:   3ms→43ms   9ms→49ms   33ms→73ms   88ms→128ms
Jitter: 85ms before, 85ms after (unchanged!)
```

### Adaptive Delay

This tool adds a **variable delay** based on current network conditions:

```
Target 50ms:   3ms+47ms=50ms   9ms+41ms=50ms   33ms+17ms=50ms   88ms+0ms=88ms
Most packets converge near 50ms. Spikes above target pass through unchanged.
```

### The Adaptive Monitor

A background process runs every 200ms:
1. Pings the target host
2. Subtracts the current added delay to get the true network RTT
3. Applies EWMA smoothing (30% new sample, 70% history) to avoid overreacting to outliers
4. Rejects outlier measurements (>2x the smoothed average)
5. Updates the dummynet pipe only if the delay changes by >2ms

### Architecture

```
ping-stabilizer.sh
  |
  |-- start ──> Background Monitor (every 200ms)
  |                  |
  |                  ├── ping target host
  |                  ├── true_rtt = measured - current_delay
  |                  ├── smoothed = EWMA(true_rtt)
  |                  └── dnctl pipe 1 config delay Xms
  |                           |
  |                           v
  |              pfctl anchor: dummynet out → pipe 1
  |              (all outbound tcp/udp/icmp)
  |
  |-- stop ───> kill monitor, flush anchor, restore pf rules, delete pipe
  |
  |-- detect ─> tcpdump capture → rank IPs by packet count
  |
  |-- measure → tcpdump capture → RTT estimation + dropout detection
```

## Safety

### Recovery layers

| Level | Command | When to use |
|-------|---------|-------------|
| Normal | `sudo ./ping-stabilizer.sh stop` | Standard shutdown |
| State files lost | `sudo ./ping-stabilizer.sh emergency-reset` | After reboot, corrupted state |
| Everything broken | `sudo pfctl -f /etc/pf.conf && sudo dnctl pipe 1 delete` | Absolute last resort |

### What gets modified (and reversed)

| Component | Modified by `start` | Reversed by `stop` |
|-----------|--------------------|--------------------|
| Dummynet pipe 1 | Created with delay | Deleted |
| PF main ruleset | Anchor reference injected | Original rules restored from backup |
| PF anchor `com.ping-stabilizer` | Dummynet out rule loaded | Flushed |
| PF enable state | Enabled via `-E` (ref counted) | Token released via `-X` |
| Background process | Monitor launched | Process killed |
| `/tmp/ping-stabilizer/` | State files created | Directory removed |

### Safety features

- **Pre-change snapshots** saved to `.backups/` (survives reboots)
- **pfctl anchor isolation** — existing firewall rules never modified directly
- **Reference-counted pf** (`-E`/`-X`) — won't accidentally disable your firewall
- **Rollback on setup failure** — if any step fails during `start`, previous steps are undone
- **Ctrl+C trap during demo** — interrupted demo auto-cleans
- **Dual backup locations** — pf rules in both `/tmp` and `.backups/`
- **Empty-rules guard** — won't flush all pf rules if restore produces empty output

## Recommended Workflow for Luna

```bash
# 1. Disable AWDL (biggest impact)
sudo ifconfig awdl0 down

# 2. Start a game, then detect the server
sudo ./ping-stabilizer.sh detect snap

# 3. Measure real connection quality
sudo ./ping-stabilizer.sh measure -h <detected-ip> -d 30

# 4. If dropouts are gone but jitter remains, stabilize
sudo ./ping-stabilizer.sh baseline -h dynamodb.us-east-1.amazonaws.com
sudo ./ping-stabilizer.sh start -t <suggested-target> -h dynamodb.us-east-1.amazonaws.com

# 5. When done gaming
sudo ./ping-stabilizer.sh stop
sudo ifconfig awdl0 up
```

## Limitations

- Can only **add** latency, never reduce it — packets above target pass through unchanged
- Delay is global (one value for all traffic) — optimized for the `-h` host
- The monitor samples every 200ms — sub-200ms network fluctuations aren't individually compensated
- Game servers often block ICMP (ping), so use `detect` + `measure` instead of `baseline`
- macOS only (uses `dnctl` and `pfctl`)
- Requires `sudo` for most commands

## File Structure

```
ping-stabilizer/
├── ping-stabilizer.sh     # Main script (the only file you run)
├── README.md              # This file
└── .backups/              # Created at runtime — system state snapshots
    ├── latest -> snapshot_YYYYMMDD_HHMMSS/
    ├── pf_rules_pre_inject.txt
    └── snapshot_YYYYMMDD_HHMMSS/
        ├── pf_rules.txt
        ├── pf_nat.txt
        ├── pf_info.txt
        ├── pf_anchors.txt
        ├── dnctl_pipes.txt
        ├── etc_pf.conf
        └── pf_was_enabled.txt
```
