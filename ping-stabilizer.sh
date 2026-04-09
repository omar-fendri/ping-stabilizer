#!/bin/bash
#
# ping-stabilizer.sh — Adaptive ping stabilizer for cloud gaming
# Uses macOS dummynet (dnctl) + pfctl to dynamically adjust packet delay,
# keeping RTT close to a consistent target value.
#

# Do NOT use set -e globally — we need controlled error handling during setup/teardown
set -uo pipefail

STATE_DIR="/tmp/ping-stabilizer"
BACKUP_DIR="/Users/fendrix/Documents/workspace/ping-stabilizer/.backups"
PF_ANCHOR="com.ping-stabilizer"
PIPE_NR=1
DEFAULT_HOST="8.8.8.8"
DEFAULT_COUNT=10
MONITOR_INTERVAL=0.5
CHANGE_THRESHOLD=2  # ms — only update pipe if delay changes by more than this

# ─── Helpers ──────────────────────────────────────────────────────────────────

die()   { echo "ERROR: $*" >&2; exit 1; }
info()  { echo "▸ $*"; }
warn()  { echo "WARNING: $*" >&2; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root (use sudo)"
}

require_tools() {
    command -v dnctl  >/dev/null 2>&1 || die "dnctl not found"
    command -v pfctl  >/dev/null 2>&1 || die "pfctl not found"
}

is_running() {
    [[ -f "$STATE_DIR/monitor.pid" ]] && kill -0 "$(cat "$STATE_DIR/monitor.pid")" 2>/dev/null
}

# ─── Safety: Snapshot & Restore ───────────────────────────────────────────────

# Save a full snapshot of pf and dummynet state BEFORE any changes.
# Stored in project dir (survives /tmp cleanup and reboots).
save_system_snapshot() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local snap_dir="$BACKUP_DIR/snapshot_$ts"
    mkdir -p "$snap_dir"

    info "Saving system snapshot to $snap_dir ..."

    # Save pf state
    pfctl -sr 2>/dev/null > "$snap_dir/pf_rules.txt" || echo "(empty)" > "$snap_dir/pf_rules.txt"
    pfctl -sn 2>/dev/null > "$snap_dir/pf_nat.txt" || echo "(empty)" > "$snap_dir/pf_nat.txt"
    pfctl -si 2>/dev/null > "$snap_dir/pf_info.txt" || echo "(empty)" > "$snap_dir/pf_info.txt"
    pfctl -sA 2>/dev/null > "$snap_dir/pf_anchors.txt" || echo "(empty)" > "$snap_dir/pf_anchors.txt"

    # Save dummynet state
    dnctl pipe show 2>/dev/null > "$snap_dir/dnctl_pipes.txt" || echo "(empty)" > "$snap_dir/dnctl_pipes.txt"

    # Save /etc/pf.conf (the on-disk config, as the ultimate fallback)
    cp /etc/pf.conf "$snap_dir/etc_pf.conf" 2>/dev/null || true

    # Record pf enabled/disabled state
    if pfctl -si 2>/dev/null | grep -q "^Status: Enabled"; then
        echo "enabled" > "$snap_dir/pf_was_enabled.txt"
    else
        echo "disabled" > "$snap_dir/pf_was_enabled.txt"
    fi

    # Also save a copy of the live rules to state dir for quick restore
    mkdir -p "$STATE_DIR"
    cp "$snap_dir/pf_rules.txt" "$STATE_DIR/pf_rules_backup.txt" 2>/dev/null || true

    # Symlink latest snapshot for easy access
    ln -sfn "$snap_dir" "$BACKUP_DIR/latest"

    info "Snapshot saved. Restore with: sudo $0 emergency-reset"
}

# ─── Safety: Emergency full reset ────────────────────────────────────────────

# Force-remove ALL traces of ping-stabilizer regardless of state files.
# This is the nuclear option — works even if state files are missing.
cmd_emergency_reset() {
    require_root
    echo ""
    echo "=== EMERGENCY RESET ==="
    echo "This will force-remove all ping-stabilizer traces from the system."
    echo ""

    local errors=0

    # 1. Kill any monitor process
    if [[ -f "$STATE_DIR/monitor.pid" ]]; then
        local pid
        pid=$(cat "$STATE_DIR/monitor.pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            info "Killing monitor process (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # Also hunt for any orphaned monitor processes
    local orphans
    orphans=$(pgrep -f "ping-stabilizer.*run_monitor" 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        info "Killing orphaned monitor processes: $orphans"
        echo "$orphans" | xargs kill -9 2>/dev/null || true
    fi

    # 2. Flush our pfctl anchor
    info "Flushing pfctl anchor '$PF_ANCHOR'..."
    pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true

    # 3. Restore main ruleset from snapshot (preferred) or /etc/pf.conf (fallback)
    info "Restoring main pf ruleset..."
    local restored=false

    # Try latest snapshot first
    if [[ -f "$BACKUP_DIR/latest/pf_rules.txt" ]]; then
        local backup_content
        backup_content=$(cat "$BACKUP_DIR/latest/pf_rules.txt")
        if [[ -n "$backup_content" ]] && [[ "$backup_content" != "(empty)" ]]; then
            if echo "$backup_content" | pfctl -f - 2>/dev/null; then
                info "Restored from snapshot: $BACKUP_DIR/latest/pf_rules.txt"
                restored=true
            fi
        fi
    fi

    # Try state dir backup
    if [[ "$restored" == false ]] && [[ -f "$STATE_DIR/pf_rules_backup.txt" ]]; then
        local backup_content
        backup_content=$(cat "$STATE_DIR/pf_rules_backup.txt")
        if [[ -n "$backup_content" ]]; then
            if echo "$backup_content" | pfctl -f - 2>/dev/null; then
                info "Restored from state backup: $STATE_DIR/pf_rules_backup.txt"
                restored=true
            fi
        fi
    fi

    # Last resort: reload /etc/pf.conf
    if [[ "$restored" == false ]]; then
        info "Reloading /etc/pf.conf (system default)..."
        pfctl -f /etc/pf.conf 2>/dev/null || {
            warn "Failed to reload /etc/pf.conf"
            ((errors++))
        }
    fi

    # 4. Release any pf tokens we hold
    if [[ -f "$STATE_DIR/pf_token" ]]; then
        local token
        token=$(cat "$STATE_DIR/pf_token" 2>/dev/null || true)
        if [[ -n "$token" ]] && [[ "$token" != "none" ]]; then
            info "Releasing pf token $token..."
            pfctl -X "$token" 2>/dev/null || true
        fi
    fi

    # 5. Delete dummynet pipe
    info "Deleting dummynet pipe $PIPE_NR..."
    dnctl pipe $PIPE_NR delete 2>/dev/null || true

    # 6. Clean up state directory
    if [[ -d "$STATE_DIR" ]]; then
        info "Removing state directory $STATE_DIR..."
        rm -rf "$STATE_DIR"
    fi

    # 7. Verify
    echo ""
    info "Verifying system state after reset..."
    echo "  PF rules:"
    pfctl -sr 2>/dev/null | sed 's/^/    /'
    echo "  Dummynet pipes:"
    local pipes
    pipes=$(dnctl pipe show 2>/dev/null)
    if [[ -z "$pipes" ]]; then
        echo "    (none)"
    else
        echo "$pipes" | sed 's/^/    /'
    fi
    echo "  Our anchor rules:"
    local anchor_rules
    anchor_rules=$(pfctl -a "$PF_ANCHOR" -sr 2>/dev/null)
    if [[ -z "$anchor_rules" ]]; then
        echo "    (none — clean)"
    else
        echo "$anchor_rules" | sed 's/^/    /'
        warn "Anchor still has rules! Manual cleanup may be needed."
        ((errors++))
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        info "Emergency reset COMPLETE. System is clean."
    else
        warn "Reset completed with $errors warning(s). Check output above."
    fi

    # Quick ping verification
    run_ping_test "8.8.8.8" 5 "post-reset verification"
}

# ─── PF anchor management ────────────────────────────────────────────────────

# Inject our dummynet-anchor + anchor into the live pf main ruleset.
# Without this, dummynet rules inside our anchor are silently ignored.
inject_anchor_into_main_ruleset() {
    # Check if already present
    if pfctl -sr 2>/dev/null | grep -q "anchor \"$PF_ANCHOR\""; then
        return 0
    fi

    # Back up current live rules to BOTH state dir and persistent backup dir
    pfctl -sr 2>/dev/null > "$STATE_DIR/pf_rules_backup.txt"
    mkdir -p "$BACKUP_DIR"
    cp "$STATE_DIR/pf_rules_backup.txt" "$BACKUP_DIR/pf_rules_pre_inject.txt"

    # Append our anchor references and reload
    {
        cat "$STATE_DIR/pf_rules_backup.txt"
        echo "dummynet-anchor \"$PF_ANCHOR\""
        echo "anchor \"$PF_ANCHOR\""
    } | pfctl -f - 2>/dev/null

    # Verify injection worked
    if ! pfctl -sr 2>/dev/null | grep -q "anchor \"$PF_ANCHOR\""; then
        warn "Failed to inject anchor into main ruleset"
        return 1
    fi
}

# Remove our anchor references from the main ruleset
remove_anchor_from_main_ruleset() {
    # Try persistent backup first (survives /tmp cleanup)
    local backup_file=""
    if [[ -f "$BACKUP_DIR/pf_rules_pre_inject.txt" ]]; then
        backup_file="$BACKUP_DIR/pf_rules_pre_inject.txt"
    elif [[ -f "$STATE_DIR/pf_rules_backup.txt" ]]; then
        backup_file="$STATE_DIR/pf_rules_backup.txt"
    fi

    if [[ -n "$backup_file" ]]; then
        local content
        content=$(cat "$backup_file")
        if [[ -n "$content" ]]; then
            echo "$content" | pfctl -f - 2>/dev/null || {
                warn "Failed to restore from backup, falling back to /etc/pf.conf"
                pfctl -f /etc/pf.conf 2>/dev/null || true
            }
            return 0
        fi
    fi

    # Fallback: strip our lines from current rules — but ONLY if result is non-empty
    local current_rules stripped_rules
    current_rules=$(pfctl -sr 2>/dev/null)
    stripped_rules=$(echo "$current_rules" | grep -v "$PF_ANCHOR" || true)

    if [[ -n "$stripped_rules" ]]; then
        echo "$stripped_rules" | pfctl -f - 2>/dev/null || true
    else
        # If stripping leaves nothing, reload system default instead of flushing all
        warn "Stripped rules would be empty — reloading /etc/pf.conf instead"
        pfctl -f /etc/pf.conf 2>/dev/null || true
    fi
}

# ─── Ping measurement ────────────────────────────────────────────────────────

# Extract individual RTT values from ping output (one per line, in ms)
parse_ping_rtts() {
    grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/'
}

# Compute stats from a list of RTT values (one per line on stdin)
# Outputs: min avg median max jitter (space-separated)
compute_stats() {
    awk '
    {
        vals[NR] = $1
        sum += $1
        n++
    }
    END {
        if (n == 0) { print "0 0 0 0 0"; exit }
        # sort
        for (i = 1; i <= n; i++)
            for (j = i+1; j <= n; j++)
                if (vals[i] > vals[j]) { t=vals[i]; vals[i]=vals[j]; vals[j]=t }
        min = vals[1]
        max = vals[n]
        avg = sum / n
        if (n % 2 == 1)
            median = vals[int(n/2)+1]
        else
            median = (vals[n/2] + vals[n/2+1]) / 2
        # jitter = max - min
        jitter = max - min
        printf "%.1f %.1f %.1f %.1f %.1f\n", min, avg, median, max, jitter
    }'
}

# Run pings and display results. Sets $REPLY_RTTS and $REPLY_STATS
run_ping_test() {
    local host="$1" count="$2" label="$3"
    echo ""
    info "Pinging $host ($label) — $count packets..."
    local output
    output=$(ping -c "$count" -W 5000 "$host" 2>&1) || true
    REPLY_RTTS=$(echo "$output" | parse_ping_rtts)

    if [[ -z "$REPLY_RTTS" ]]; then
        warn "No replies received from $host"
        REPLY_STATS="0 0 0 0 0"
        return 1
    fi

    REPLY_STATS=$(echo "$REPLY_RTTS" | compute_stats)
    local min avg median max jitter
    read -r min avg median max jitter <<< "$REPLY_STATS"

    echo "  Results: min=${min}ms  avg=${avg}ms  median=${median}ms  max=${max}ms  jitter=${jitter}ms"
    echo "  Values: $(echo "$REPLY_RTTS" | tr '\n' ' ')"
}

print_comparison_row() {
    local label="$1" stats="$2"
    local min avg median max jitter
    read -r min avg median max jitter <<< "$stats"
    printf "  %-12s │ %7s │ %7s │ %7s │ %7s │ %7s\n" "$label" "$min" "$avg" "$median" "$max" "$jitter"
}

# ─── Background adaptive monitor ─────────────────────────────────────────────

run_monitor() {
    local host="$1" target="$2"
    local current_delay=0

    # Set initial delay (passed as $3 if available)
    if [[ -n "${3:-}" ]]; then
        current_delay="$3"
    fi

    while true; do
        local rtt
        rtt=$(ping -c 1 -W 5000 "$host" 2>/dev/null | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/' || true)

        if [[ -n "$rtt" ]]; then
            # CRITICAL: The measured RTT includes our own added delay.
            # Subtract it to get the true network RTT.
            # true_rtt = measured_rtt - current_delay
            local rtt_int=${rtt%.*}
            local true_rtt=$(( rtt_int - current_delay ))
            [[ $true_rtt -lt 0 ]] && true_rtt=0

            local new_delay=$(( target - true_rtt ))
            [[ $new_delay -lt 0 ]] && new_delay=0

            # Only update if change exceeds threshold
            local diff=$(( new_delay - current_delay ))
            [[ $diff -lt 0 ]] && diff=$(( -diff ))

            if [[ $diff -gt $CHANGE_THRESHOLD ]]; then
                dnctl pipe $PIPE_NR config delay "${new_delay}ms" 2>/dev/null || true
                current_delay=$new_delay
            fi

            # Write stats for status command
            echo "$rtt $true_rtt $current_delay $(date +%s)" > "$STATE_DIR/stats" 2>/dev/null || true
        fi

        sleep "$MONITOR_INTERVAL"
    done
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_start() {
    local target="" host="$DEFAULT_HOST" count="$DEFAULT_COUNT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target) target="$2"; shift 2 ;;
            -h|--host)   host="$2";   shift 2 ;;
            -c|--count)  count="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$target" ]] && die "Target is required: -t <ms>"
    [[ "$target" =~ ^[0-9]+$ ]] || die "Target must be a positive integer (ms)"
    [[ "$count" =~ ^[0-9]+$ ]] || die "Count must be a positive integer"

    require_root
    require_tools

    if is_running; then
        die "Already running (PID $(cat "$STATE_DIR/monitor.pid")). Run 'stop' first."
    fi

    mkdir -p "$STATE_DIR"

    # ── Save system snapshot BEFORE any changes ──
    save_system_snapshot

    # ── Measure baseline ──
    info "Measuring baseline ping to $host..."
    run_ping_test "$host" "$count" "baseline"
    local baseline_stats="$REPLY_STATS"
    local baseline_median
    baseline_median=$(echo "$baseline_stats" | awk '{print $3}')
    local baseline_median_int=${baseline_median%.*}

    if [[ $target -le $baseline_median_int ]]; then
        warn "Target (${target}ms) <= median baseline (${baseline_median}ms)."
        warn "Many packets will exceed target. Consider a higher target."
    fi

    local initial_delay=$(( target - baseline_median_int ))
    [[ $initial_delay -lt 0 ]] && initial_delay=0

    info "Target: ${target}ms | Baseline median: ${baseline_median}ms | Initial delay: ${initial_delay}ms"

    # ── Configure dummynet pipe ──
    info "Configuring dummynet pipe $PIPE_NR with ${initial_delay}ms delay..."
    if ! dnctl pipe $PIPE_NR config delay "${initial_delay}ms"; then
        die "Failed to configure dummynet pipe. Run 'sudo $0 emergency-reset' to clean up."
    fi

    # ── Configure pfctl ──
    info "Setting up pfctl anchor '$PF_ANCHOR'..."

    # Enable pf with reference counting first, capture token
    local pf_output
    pf_output=$(pfctl -E 2>&1) || true
    local token
    token=$(echo "$pf_output" | grep -o 'Token : [0-9]*' | awk '{print $3}' || true)
    [[ -z "$token" ]] && token="none"
    echo "$token" > "$STATE_DIR/pf_token"

    # Inject anchor references into main ruleset (required for dummynet in anchors)
    if ! inject_anchor_into_main_ruleset; then
        warn "Anchor injection failed — cleaning up..."
        dnctl pipe $PIPE_NR delete 2>/dev/null || true
        [[ "$token" != "none" ]] && pfctl -X "$token" 2>/dev/null || true
        rm -rf "$STATE_DIR"
        die "Setup failed. System restored to original state."
    fi

    # Load dummynet rules into our anchor
    echo "dummynet out proto { tcp, udp, icmp } from any to any pipe $PIPE_NR" \
        > "$STATE_DIR/pf.rules"
    if ! pfctl -a "$PF_ANCHOR" -f "$STATE_DIR/pf.rules" 2>/dev/null; then
        warn "Failed to load anchor rules — cleaning up..."
        remove_anchor_from_main_ruleset
        dnctl pipe $PIPE_NR delete 2>/dev/null || true
        [[ "$token" != "none" ]] && pfctl -X "$token" 2>/dev/null || true
        rm -rf "$STATE_DIR"
        die "Setup failed. System restored to original state."
    fi

    # ── Launch adaptive monitor ──
    info "Launching adaptive monitor (adjusting every ${MONITOR_INTERVAL}s)..."
    echo "$target" > "$STATE_DIR/target"
    echo "$host"   > "$STATE_DIR/host"

    run_monitor "$host" "$target" "$initial_delay" &
    local monitor_pid=$!
    echo "$monitor_pid" > "$STATE_DIR/monitor.pid"
    disown "$monitor_pid" 2>/dev/null || true

    info "Monitor running (PID $monitor_pid)"

    # ── Verify ──
    sleep 2  # let monitor settle
    run_ping_test "$host" "$count" "stabilized"
    local stabilized_stats="$REPLY_STATS"

    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                    COMPARISON (ms)                          │"
    echo "├──────────────┬─────────┬─────────┬─────────┬─────────┬─────────┤"
    echo "│ Phase        │   Min   │   Avg   │ Median  │   Max   │ Jitter  │"
    echo "├──────────────┼─────────┼─────────┼─────────┼─────────┼─────────┤"
    print_comparison_row "Baseline" "$baseline_stats"
    print_comparison_row "Stabilized" "$stabilized_stats"
    echo "└──────────────┴─────────┴─────────┴─────────┴─────────┴─────────┘"
    echo ""
    info "Ping stabilizer is ACTIVE. Run 'sudo $0 stop' to disable."
    info "If something goes wrong: sudo $0 emergency-reset"
}

cmd_stop() {
    require_root

    if ! [[ -d "$STATE_DIR" ]]; then
        die "Not running (no state directory found). If stuck, use: sudo $0 emergency-reset"
    fi

    # ── Read host before cleanup ──
    local host="${1:-$DEFAULT_HOST}"
    [[ -f "$STATE_DIR/host" ]] && host=$(cat "$STATE_DIR/host") || true

    # ── Kill monitor ──
    if [[ -f "$STATE_DIR/monitor.pid" ]]; then
        local pid
        pid=$(cat "$STATE_DIR/monitor.pid")
        if kill -0 "$pid" 2>/dev/null; then
            info "Stopping adaptive monitor (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # ── Remove pfctl anchor ──
    info "Removing pfctl anchor '$PF_ANCHOR'..."
    pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true

    # Remove anchor references from main ruleset
    remove_anchor_from_main_ruleset

    # ── Release pf enable token ──
    if [[ -f "$STATE_DIR/pf_token" ]]; then
        local token
        token=$(cat "$STATE_DIR/pf_token")
        if [[ "$token" != "none" ]]; then
            info "Releasing pf token $token..."
            pfctl -X "$token" 2>/dev/null || true
        fi
    fi

    # ── Delete dummynet pipe ──
    info "Deleting dummynet pipe $PIPE_NR..."
    dnctl pipe $PIPE_NR delete 2>/dev/null || true

    # ── Clean up state (keep backups) ──
    rm -rf "$STATE_DIR"

    # ── Verify ──
    info "Verifying cleanup..."
    echo "  Our anchor rules:"
    local anchor_rules
    anchor_rules=$(pfctl -a "$PF_ANCHOR" -sr 2>/dev/null)
    if [[ -z "$anchor_rules" ]]; then
        echo "    (none — clean)"
    else
        echo "$anchor_rules" | sed 's/^/    /'
        warn "Anchor still has rules! Use: sudo $0 emergency-reset"
    fi

    run_ping_test "$host" 5 "after stop"

    echo ""
    info "Ping stabilizer STOPPED. All interference removed."
}

cmd_status() {
    if ! is_running; then
        echo "Ping stabilizer is NOT running."
        if [[ -d "$BACKUP_DIR/latest" ]]; then
            echo "  Last snapshot: $BACKUP_DIR/latest"
        fi
        return 0
    fi

    local target host pid
    target=$(cat "$STATE_DIR/target" 2>/dev/null || echo "?")
    host=$(cat "$STATE_DIR/host" 2>/dev/null || echo "?")
    pid=$(cat "$STATE_DIR/monitor.pid" 2>/dev/null || echo "?")

    echo "Ping stabilizer is ACTIVE"
    echo "  Target:  ${target}ms"
    echo "  Host:    $host"
    echo "  Monitor: PID $pid"

    if [[ -f "$STATE_DIR/stats" ]]; then
        local measured_rtt true_rtt current_delay timestamp
        read -r measured_rtt true_rtt current_delay timestamp < "$STATE_DIR/stats"
        echo "  Measured RTT:  ${measured_rtt}ms (includes added delay)"
        echo "  True net RTT:  ${true_rtt}ms"
        echo "  Current delay: ${current_delay}ms"
    fi

    # Show active pfctl rules
    echo "  PF rules:"
    pfctl -a "$PF_ANCHOR" -sr 2>/dev/null | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo "  Snapshot: $BACKUP_DIR/latest"
    echo "  Stop:     sudo $0 stop"
    echo "  Panic:    sudo $0 emergency-reset"
}

cmd_demo() {
    local target="" host="$DEFAULT_HOST" count="$DEFAULT_COUNT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target) target="$2"; shift 2 ;;
            -h|--host)   host="$2";   shift 2 ;;
            -c|--count)  count="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$target" ]] && die "Target is required: -t <ms>"
    require_root
    require_tools

    local google_host="8.8.8.8"
    local aws_host="dynamodb.us-east-1.amazonaws.com"

    # Save snapshot before demo
    mkdir -p "$STATE_DIR"
    save_system_snapshot

    # Trap to ensure cleanup on Ctrl+C or unexpected exit during demo
    trap 'echo ""; warn "Interrupted — cleaning up..."; pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true; remove_anchor_from_main_ruleset; dnctl pipe $PIPE_NR delete 2>/dev/null || true; [[ -n "${token:-}" ]] && [[ "${token:-}" != "none" ]] && pfctl -X "$token" 2>/dev/null || true; [[ -n "${monitor_pid:-}" ]] && kill "$monitor_pid" 2>/dev/null; kill -9 "$monitor_pid" 2>/dev/null; rm -rf "$STATE_DIR"; echo "Cleaned up. Run emergency-reset if needed."; exit 1' INT TERM

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           PING STABILIZER — DEMONSTRATION                  ║"
    echo "║           Target: ${target}ms                                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    # ── Phase 1: Baseline ──
    echo ""
    echo "━━━ PHASE 1: BASELINE (no stabilization) ━━━"
    run_ping_test "$google_host" "$count" "Google DNS"
    local google_baseline="$REPLY_STATS"
    run_ping_test "$aws_host" "$count" "AWS us-east-1"
    local aws_baseline="$REPLY_STATS"

    # ── Phase 2: Stabilized ──
    echo ""
    echo "━━━ PHASE 2: STABILIZED (target ${target}ms) ━━━"

    # Use the -h host for monitor and initial delay calculation
    # Default to Google DNS if no -h was provided
    local monitor_host="$host"
    local monitor_baseline
    if [[ "$monitor_host" == "$google_host" ]]; then
        monitor_baseline="$google_baseline"
    elif [[ "$monitor_host" == "$aws_host" ]]; then
        monitor_baseline="$aws_baseline"
    else
        # Custom host — run a separate baseline
        run_ping_test "$monitor_host" "$count" "monitor target"
        monitor_baseline="$REPLY_STATS"
    fi

    local baseline_median
    baseline_median=$(echo "$monitor_baseline" | awk '{printf "%d", $3}')
    local initial_delay=$(( target - baseline_median ))
    [[ $initial_delay -lt 0 ]] && initial_delay=0

    info "Monitor host: $monitor_host (baseline median: ${baseline_median}ms)"
    info "Setting up: initial delay ${initial_delay}ms..."
    dnctl pipe $PIPE_NR config delay "${initial_delay}ms"

    # Enable pf and inject anchor into main ruleset
    local pf_output
    pf_output=$(pfctl -E 2>&1) || true
    local token
    token=$(echo "$pf_output" | grep -o 'Token : [0-9]*' | awk '{print $3}' || true)
    [[ -z "$token" ]] && token="none"
    echo "$token" > "$STATE_DIR/pf_token"
    echo "$target" > "$STATE_DIR/target"
    echo "$monitor_host" > "$STATE_DIR/host"

    inject_anchor_into_main_ruleset

    echo "dummynet out proto { tcp, udp, icmp } from any to any pipe $PIPE_NR" \
        > "$STATE_DIR/pf.rules"
    pfctl -a "$PF_ANCHOR" -f "$STATE_DIR/pf.rules" 2>/dev/null

    # Start adaptive monitor — pings the -h host to adapt delay
    local monitor_pid
    run_monitor "$monitor_host" "$target" "$initial_delay" &
    monitor_pid=$!
    echo "$monitor_pid" > "$STATE_DIR/monitor.pid"
    disown "$monitor_pid" 2>/dev/null || true

    sleep 2  # let monitor settle

    run_ping_test "$google_host" "$count" "Google DNS"
    local google_stable="$REPLY_STATS"
    run_ping_test "$aws_host" "$count" "AWS us-east-1"
    local aws_stable="$REPLY_STATS"

    # ── Phase 3: Restored ──
    echo ""
    echo "━━━ PHASE 3: RESTORED (stabilization removed) ━━━"
    # Stop stabilization
    kill "$monitor_pid" 2>/dev/null || true
    sleep 0.5
    kill -9 "$monitor_pid" 2>/dev/null || true
    pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true
    remove_anchor_from_main_ruleset
    [[ "$token" != "none" ]] && pfctl -X "$token" 2>/dev/null || true
    dnctl pipe $PIPE_NR delete 2>/dev/null || true
    rm -rf "$STATE_DIR"

    # Remove trap
    trap - INT TERM

    sleep 1
    run_ping_test "$google_host" "$count" "Google DNS"
    local google_restored="$REPLY_STATS"
    run_ping_test "$aws_host" "$count" "AWS us-east-1"
    local aws_restored="$REPLY_STATS"

    # ── Summary ──
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                        RESULTS COMPARISON                          ║"
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    echo "║ Google DNS (8.8.8.8)                                               ║"
    echo "╠──────────────┬─────────┬─────────┬─────────┬─────────┬─────────────╣"
    echo "║ Phase        │   Min   │   Avg   │ Median  │   Max   │   Jitter    ║"
    echo "╠──────────────┼─────────┼─────────┼─────────┼─────────┼─────────────╣"
    print_comparison_row "Baseline" "$google_baseline"
    print_comparison_row "Stabilized" "$google_stable"
    print_comparison_row "Restored" "$google_restored"
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    echo "║ AWS us-east-1                                                      ║"
    echo "╠──────────────┬─────────┬─────────┬─────────┬─────────┬─────────────╣"
    echo "║ Phase        │   Min   │   Avg   │ Median  │   Max   │   Jitter    ║"
    echo "╠──────────────┼─────────┼─────────┼─────────┼─────────┼─────────────╣"
    print_comparison_row "Baseline" "$aws_baseline"
    print_comparison_row "Stabilized" "$aws_stable"
    print_comparison_row "Restored" "$aws_restored"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Jitter comparison
    local base_jitter stable_jitter
    base_jitter=$(echo "$google_baseline" | awk '{print $5}')
    stable_jitter=$(echo "$google_stable" | awk '{print $5}')
    echo "Google DNS jitter: ${base_jitter}ms (baseline) -> ${stable_jitter}ms (stabilized)"

    base_jitter=$(echo "$aws_baseline" | awk '{print $5}')
    stable_jitter=$(echo "$aws_stable" | awk '{print $5}')
    echo "AWS jitter:        ${base_jitter}ms (baseline) -> ${stable_jitter}ms (stabilized)"
}

cmd_usage() {
    cat <<'USAGE'
Ping Stabilizer — Adaptive latency stabilization for cloud gaming

Usage: sudo ./ping-stabilizer.sh <command> [options]

Commands:
  start            Enable ping stabilization
  stop             Disable and remove all interference
  demo             Run before/during/after demonstration
  status           Show current state
  emergency-reset  Force-remove ALL traces (use if stop fails)

Options:
  -t, --target <ms>    Target ping in ms (required for start/demo)
  -h, --host <addr>    Ping target host (default: 8.8.8.8)
  -c, --count <n>      Number of pings for measurement (default: 10)

Examples:
  sudo ./ping-stabilizer.sh start -t 50
  sudo ./ping-stabilizer.sh start -t 100 -h 1.1.1.1
  sudo ./ping-stabilizer.sh demo -t 50
  sudo ./ping-stabilizer.sh stop
  sudo ./ping-stabilizer.sh status
  sudo ./ping-stabilizer.sh emergency-reset

Safety:
  - A full system snapshot is saved before any changes
  - Snapshots are stored in .backups/ (survives reboots)
  - 'stop' cleanly reverses all changes
  - 'emergency-reset' force-cleans even if state files are lost
  - As last resort: sudo pfctl -f /etc/pf.conf && sudo dnctl pipe 1 delete

How it works:
  Unlike a fixed delay (which just shifts all ping values up), this tool
  uses ADAPTIVE delay: it continuously measures your actual network RTT
  and adjusts the added delay so that total RTT stays near the target.

  Fast packet (3ms)  + 47ms added delay = ~50ms total
  Slow packet (33ms) + 17ms added delay = ~50ms total
  Spike (88ms)       +  0ms added delay =  88ms total (can't reduce)
USAGE
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    start)            shift; cmd_start "$@" ;;
    stop)             shift; cmd_stop "$@" ;;
    status)           cmd_status ;;
    demo)             shift; cmd_demo "$@" ;;
    emergency-reset)  cmd_emergency_reset ;;
    *)                cmd_usage ;;
esac
