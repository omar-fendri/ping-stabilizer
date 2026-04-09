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
MONITOR_INTERVAL=0.2  # 200ms — faster sampling for better smoothing
CHANGE_THRESHOLD=2    # ms — only update pipe if delay changes by more than this
EWMA_ALPHA=30         # 0-100, weight of new sample (30 = 0.30). Lower = smoother, slower to adapt

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
    local smoothed_rtt=-1  # EWMA of true network RTT (scaled x100 for precision)
    local sample_count=0

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
            local rtt_int=${rtt%.*}
            local true_rtt=$(( rtt_int - current_delay ))
            [[ $true_rtt -lt 0 ]] && true_rtt=0

            # Scale to x100 for integer EWMA math
            local true_rtt_100=$(( true_rtt * 100 ))

            if [[ $smoothed_rtt -lt 0 ]]; then
                # First sample: initialize directly
                smoothed_rtt=$true_rtt_100
            else
                # Outlier rejection: ignore if >2x the smoothed average
                local outlier_limit=$(( smoothed_rtt * 2 ))
                if [[ $true_rtt_100 -le $outlier_limit ]] || [[ $sample_count -lt 5 ]]; then
                    # EWMA: smoothed = alpha * new + (1 - alpha) * old
                    smoothed_rtt=$(( (EWMA_ALPHA * true_rtt_100 + (100 - EWMA_ALPHA) * smoothed_rtt) / 100 ))
                fi
                # else: outlier, skip this sample
            fi
            sample_count=$(( sample_count + 1 ))

            # Calculate delay from smoothed RTT (unscale from x100)
            local smoothed_rtt_ms=$(( smoothed_rtt / 100 ))
            local new_delay=$(( target - smoothed_rtt_ms ))
            [[ $new_delay -lt 0 ]] && new_delay=0

            # Only update if change exceeds threshold
            local diff=$(( new_delay - current_delay ))
            [[ $diff -lt 0 ]] && diff=$(( -diff ))

            if [[ $diff -gt $CHANGE_THRESHOLD ]]; then
                dnctl pipe $PIPE_NR config delay "${new_delay}ms" 2>/dev/null || true
                current_delay=$new_delay
            fi

            # Write stats for status command
            echo "$rtt $true_rtt $smoothed_rtt_ms $current_delay $(date +%s)" > "$STATE_DIR/stats" 2>/dev/null || true
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
    sleep 4  # let EWMA stabilize (~20 samples at 200ms)
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
        local measured_rtt true_rtt smoothed_rtt current_delay timestamp
        read -r measured_rtt true_rtt smoothed_rtt current_delay timestamp < "$STATE_DIR/stats"
        echo "  Measured RTT:  ${measured_rtt}ms (includes added delay)"
        echo "  True net RTT:  ${true_rtt}ms (last sample)"
        echo "  Smoothed RTT:  ${smoothed_rtt}ms (EWMA)"
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

    sleep 4  # let EWMA stabilize (~20 samples at 200ms)

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

# ─── Detect Luna server ───────────────────────────────────────────────────────

cmd_detect() {
    require_root

    local mode="${1:-watch}"

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           LUNA SERVER DETECTION                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Get local IP to exclude from results
    local local_ip
    local_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")

    if [[ "$mode" == "snap" ]]; then
        # Snapshot mode: capture 5 seconds of live UDP traffic
        detect_capture_traffic "$local_ip" 5
        return 0
    fi

    # Watch mode: capture traffic diff before/after game launch
    echo "This will detect Luna's game streaming server by capturing"
    echo "network traffic before and after you start a game."
    echo ""
    echo "Instructions:"
    echo "  1. Open Amazon Luna in your browser (don't start a game yet)"
    echo "  2. Press ENTER here when ready..."
    read -r

    info "Capturing baseline traffic for 5 seconds..."
    local before_ips
    before_ips=$(capture_remote_udp_ips "$local_ip" 5)

    echo ""
    echo "  3. Now START a game in Luna"
    echo "  4. Wait 5-10 seconds for the stream to begin"
    echo "  5. Press ENTER here when the game is running..."
    read -r

    info "Capturing game traffic for 8 seconds..."
    local after_ips
    after_ips=$(capture_remote_udp_ips "$local_ip" 8)

    # Find new IPs (in after but not in before), with packet counts
    local new_ips
    new_ips=$(comm -13 <(echo "$before_ips" | awk '{print $1}' | sort) \
                       <(echo "$after_ips" | awk '{print $1}' | sort) || true)

    if [[ -z "$new_ips" ]]; then
        # Fall back: show top talkers from the game capture
        info "No exclusively new IPs, showing top UDP destinations by packet count:"
        echo ""
        new_ips=$(echo "$after_ips" | awk '{print $1}')
    fi

    # Score and display candidates
    detect_score_candidates "$new_ips" "$after_ips" "$local_ip"
}

# Run tcpdump for N seconds, write to file. macOS has no `timeout`, so use background + sleep + kill.
run_tcpdump_for() {
    local duration="$1" outfile="$2"
    # Capture all UDP except DNS, on default interface
    tcpdump -i en0 -n -l udp and not port 53 > "$outfile" 2>/dev/null &
    local pid=$!
    sleep "$duration"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Filter tcpdump output to external IPs with packet counts
extract_external_ips() {
    local local_ip="$1"
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        grep -v "^${local_ip}$" | \
        grep -v '^127\.' | \
        grep -v '^10\.' | \
        grep -v '^192\.168\.' | \
        grep -v '^172\.1[6-9]\.' | \
        grep -v '^172\.2[0-9]\.' | \
        grep -v '^172\.3[0-1]\.' | \
        grep -v '^224\.' | \
        grep -v '^239\.' | \
        grep -v '^255\.' | \
        sort | uniq -c | sort -rn || true
}

# Capture UDP traffic for N seconds, return "ip packet_count" lines sorted by count
capture_remote_udp_ips() {
    local local_ip="$1" duration="$2"
    local tmpfile="/tmp/ping-stabilizer-capture-$$.txt"

    run_tcpdump_for "$duration" "$tmpfile"

    if [[ -s "$tmpfile" ]]; then
        cat "$tmpfile" | extract_external_ips "$local_ip" | awk '{print $2, $1}'
    fi
    rm -f "$tmpfile"
}

# Capture and display live UDP traffic for N seconds
detect_capture_traffic() {
    local local_ip="$1" duration="$2"

    info "Capturing live UDP traffic for ${duration} seconds (excluding DNS)..."
    echo ""

    local capture_file="/tmp/ping-stabilizer-capture.txt"

    run_tcpdump_for "$duration" "$capture_file"

    if [[ ! -s "$capture_file" ]]; then
        warn "No UDP traffic captured. Is Luna streaming?"
        rm -f "$capture_file"
        return 1
    fi

    # Extract remote IPs with packet counts (exclude private/local)
    local ip_counts
    ip_counts=$(cat "$capture_file" | extract_external_ips "$local_ip")

    if [[ -z "$ip_counts" ]]; then
        warn "No external UDP traffic found."
        rm -f "$capture_file"
        return 1
    fi

    info "External UDP destinations (by packet count):"
    echo ""
    printf "  %-18s %10s\n" "IP Address" "Packets"
    printf "  %-18s %10s\n" "──────────────────" "────────"
    echo "$ip_counts" | head -15 | awk '{printf "  %-18s %10s\n", $2, $1}'

    # The top talker is likely the streaming server
    local top_ip top_count
    top_ip=$(echo "$ip_counts" | head -1 | awk '{print $2}')
    top_count=$(echo "$ip_counts" | head -1 | awk '{print $1}')

    rm -f "$capture_file"

    if [[ -n "$top_ip" ]]; then
        echo ""
        info "Top talker: $top_ip ($top_count packets)"
        local rtt
        rtt=$(ping -c 5 -W 5000 "$top_ip" 2>/dev/null | tail -1 | sed 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/' || echo "timeout")
        if [[ "$rtt" != "timeout" ]]; then
            local rtt_int=${rtt%.*}
            info "Ping to $top_ip: avg ${rtt}ms"
            echo ""
            echo "  Suggested commands:"
            echo "    sudo $0 baseline -h $top_ip"
            echo "    sudo $0 start -t $(( rtt_int + 20 )) -h $top_ip"
        else
            warn "$top_ip doesn't respond to ping (may block ICMP)"
        fi
    fi
}

# Score candidate IPs and recommend the best one
detect_score_candidates() {
    local new_ips="$1" all_ip_counts="$2" local_ip="$3"

    echo ""
    info "Candidate Luna server IPs:"
    echo ""
    printf "  %-18s %8s %10s\n" "IP Address" "RTT" "Packets"
    printf "  %-18s %8s %10s\n" "──────────────────" "────────" "────────"

    local best_ip="" best_score=0

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue

        local pkt_count
        pkt_count=$(echo "$all_ip_counts" | grep "$ip" | awk '{print $2}' || echo "0")

        local rtt
        rtt=$(ping -c 3 -W 5000 "$ip" 2>/dev/null | tail -1 | sed 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/' || echo "timeout")

        printf "  %-18s %7sms %9s\n" "$ip" "$rtt" "$pkt_count"

        # Score: more packets = more likely to be the streaming server
        if [[ "$pkt_count" =~ ^[0-9]+$ ]] && [[ $pkt_count -gt $best_score ]]; then
            best_score=$pkt_count
            best_ip=$ip
        fi
    done <<< "$new_ips"

    echo ""
    if [[ -n "$best_ip" ]]; then
        local rtt
        rtt=$(ping -c 5 -W 5000 "$best_ip" 2>/dev/null | tail -1 | sed 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/' || echo "timeout")

        if [[ "$rtt" != "timeout" ]]; then
            local rtt_int=${rtt%.*}
            info "Recommended Luna server: $best_ip (avg ${rtt}ms, $best_score packets)"
            echo ""
            echo "  Use it with:"
            echo "    sudo $0 baseline -h $best_ip"
            echo "    sudo $0 start -t $(( rtt_int + 20 )) -h $best_ip"
            echo ""
            echo "  (target = ${rtt_int}ms + 20ms headroom = $(( rtt_int + 20 ))ms)"
        else
            info "Likely Luna server: $best_ip ($best_score packets, but doesn't respond to ping)"
            warn "Server blocks ICMP — you may need to use the AWS endpoint instead:"
            echo "    sudo $0 start -t 100 -h dynamodb.us-east-1.amazonaws.com"
        fi

        mkdir -p "$STATE_DIR" 2>/dev/null || true
        echo "$best_ip" > "$STATE_DIR/luna_server" 2>/dev/null || true
    fi
}

# ─── Measure RTT from live traffic (for servers that block ping) ──────────────

cmd_measure() {
    local server_ip="" duration=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--host)     server_ip="$2"; shift 2 ;;
            -d|--duration) duration="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$server_ip" ]] && die "Server IP required: -h <ip>  (use 'detect snap' to find it)"
    require_root

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       RTT MEASUREMENT FROM LIVE TRAFFIC                    ║"
    echo "║       Server: $server_ip"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    info "Capturing ${duration}s of traffic to/from $server_ip..."
    info "Make sure the game is actively running!"
    echo ""

    local capture_file="/tmp/ping-stabilizer-rtt-$$.txt"

    # Capture traffic to/from the server with microsecond timestamps
    tcpdump -i en0 -n -tt host "$server_ip" > "$capture_file" 2>/dev/null &
    local tcpdump_pid=$!
    sleep "$duration"
    kill "$tcpdump_pid" 2>/dev/null || true
    wait "$tcpdump_pid" 2>/dev/null || true

    if [[ ! -s "$capture_file" ]]; then
        warn "No traffic captured. Is the game still running?"
        rm -f "$capture_file"
        return 1
    fi

    local total_packets
    total_packets=$(wc -l < "$capture_file" | tr -d ' ')
    info "Captured $total_packets packets"

    # ── Packet loss & traffic analysis ──
    local local_ip
    local_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "")

    local traffic_stats
    traffic_stats=$(awk -v local_ip="$local_ip" -v server_ip="$server_ip" '
    BEGIN { out=0; in_=0; first_ts=0; last_ts=0 }
    {
        ts = $1
        if (first_ts == 0) first_ts = ts
        last_ts = ts
        line = $0

        if (index(line, local_ip) < index(line, server_ip) && index(line, ">") > 0) {
            out++
            # Extract packet length (last number before "bytes" or end)
            if (match(line, /length [0-9]+/)) {
                out_bytes += substr(line, RSTART+7, RLENGTH-7)
            }
        } else if (index(line, server_ip) < index(line, local_ip) && index(line, ">") > 0) {
            in_++
            if (match(line, /length [0-9]+/)) {
                in_bytes += substr(line, RSTART+7, RLENGTH-7)
            }
        }
    }
    END {
        elapsed = last_ts - first_ts
        if (elapsed <= 0) elapsed = 1

        printf "%d %d %d %.1f %.0f %.0f\n", out, in_, out+in_, elapsed, out_bytes/1024, in_bytes/1024
    }' "$capture_file")

    local pkts_out pkts_in pkts_total elapsed_sec kb_out kb_in
    read -r pkts_out pkts_in pkts_total elapsed_sec kb_out kb_in <<< "$traffic_stats"

    # Detect gaps in traffic (potential dropouts)
    local gap_analysis
    gap_analysis=$(awk -v server_ip="$server_ip" -v local_ip="$local_ip" '
    {
        ts = $1 + 0
        line = $0
        # Only look at incoming packets (server -> us)
        if (index(line, server_ip) < index(line, local_ip) && index(line, ">") > 0) {
            if (last_in_ts > 0) {
                gap = (ts - last_in_ts) * 1000  # ms
                if (gap > 50) gaps_50++
                if (gap > 100) gaps_100++
                if (gap > 200) gaps_200++
                if (gap > max_gap) max_gap = gap
                total_gap += gap
                n++
            }
            last_in_ts = ts
        }
    }
    END {
        avg_gap = (n > 0) ? total_gap / n : 0
        printf "%d %d %d %.1f %.1f\n", gaps_50+0, gaps_100+0, gaps_200+0, max_gap+0, avg_gap
    }' "$capture_file")

    local gaps_50 gaps_100 gaps_200 max_gap avg_inter_packet
    read -r gaps_50 gaps_100 gaps_200 max_gap avg_inter_packet <<< "$gap_analysis"

    echo ""
    echo "  ┌─────────────────────────────────────────────────┐"
    echo "  │ TRAFFIC ANALYSIS                                │"
    echo "  ├─────────────────────────────────────────────────┤"
    echo "  │ Duration:     ${elapsed_sec}s"
    echo "  │ Packets out:  $pkts_out  (~${kb_out} KB)"
    echo "  │ Packets in:   $pkts_in  (~${kb_in} KB)"
    echo "  │ Total:        $pkts_total packets"
    echo "  │                                                 │"
    echo "  │ DROPOUT DETECTION (gaps in incoming stream)     │"
    echo "  │   Gaps > 50ms:   $gaps_50"
    echo "  │   Gaps > 100ms:  $gaps_100"
    echo "  │   Gaps > 200ms:  $gaps_200"
    echo "  │   Longest gap:   ${max_gap}ms"
    echo "  │   Avg interval:  ${avg_inter_packet}ms between packets"
    echo "  └─────────────────────────────────────────────────┘"

    if [[ $gaps_100 -gt 0 ]]; then
        warn "Detected $gaps_100 gaps >100ms — these cause visible stuttering!"
    fi
    if [[ $gaps_200 -gt 0 ]]; then
        warn "Detected $gaps_200 gaps >200ms — these cause major freezes!"
    fi

    # Estimate RTT by measuring time between outgoing and next incoming packet.
    # tcpdump -tt format: "1234567890.123456 IP src > dst: ..."
    # Outgoing: our IP > server IP
    # Incoming: server IP > our IP
    # (local_ip already set above in traffic analysis)

    # Use awk to calculate RTT from packet pairs (outgoing followed by incoming)
    local rtt_data
    rtt_data=$(awk -v local_ip="$local_ip" -v server_ip="$server_ip" '
    {
        timestamp = $1
        # Determine direction by looking for "local > server" or "server > local"
        line = $0
        if (index(line, local_ip) < index(line, server_ip) && index(line, ">") > 0) {
            # Outgoing packet
            if (last_out_ts == 0 || timestamp - last_out_ts > 0.001) {
                last_out_ts = timestamp
                waiting_reply = 1
            }
        } else if (index(line, server_ip) < index(line, local_ip) && index(line, ">") > 0) {
            # Incoming packet
            if (waiting_reply && last_out_ts > 0) {
                rtt = (timestamp - last_out_ts) * 1000  # convert to ms
                if (rtt > 0 && rtt < 500) {  # sanity check: ignore >500ms
                    rtts[n++] = rtt
                    sum += rtt
                }
                waiting_reply = 0
            }
        }
    }
    END {
        if (n == 0) { print "NONE"; exit }

        # Sort RTTs
        for (i = 0; i < n; i++)
            for (j = i+1; j < n; j++)
                if (rtts[i] > rtts[j]) { t=rtts[i]; rtts[i]=rtts[j]; rtts[j]=t }

        min = rtts[0]
        max = rtts[n-1]
        avg = sum / n
        if (n % 2 == 1)
            median = rtts[int(n/2)]
        else
            median = (rtts[int(n/2)-1] + rtts[int(n/2)]) / 2
        jitter = max - min

        # Std dev
        for (i = 0; i < n; i++) {
            diff = rtts[i] - avg
            sq_sum += diff * diff
        }
        stddev = sqrt(sq_sum / n)

        printf "%.1f %.1f %.1f %.1f %.1f %.1f %d\n", min, avg, median, max, jitter, stddev, n

        # Also print individual RTTs for distribution view
        printf "RTTS:"
        for (i = 0; i < n && i < 50; i++)
            printf " %.1f", rtts[i]
        printf "\n"
    }' "$capture_file")

    rm -f "$capture_file"

    if [[ "$rtt_data" == "NONE" ]]; then
        warn "Could not estimate RTT from traffic (not enough packet pairs)"
        return 1
    fi

    local stats_line
    stats_line=$(echo "$rtt_data" | head -1)
    local rtts_line
    rtts_line=$(echo "$rtt_data" | tail -1 | sed 's/^RTTS: *//')

    local min avg median max jitter stddev sample_count
    read -r min avg median max jitter stddev sample_count <<< "$stats_line"

    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │ Server:    $server_ip"
    echo "  │ Samples:   $sample_count RTT pairs"
    echo "  │ Duration:  ${duration}s"
    echo "  │                                         │"
    echo "  │ Min:       ${min}ms                     "
    echo "  │ Avg:       ${avg}ms                     "
    echo "  │ Median:    ${median}ms                  "
    echo "  │ Max:       ${max}ms                     "
    echo "  │ Jitter:    ${jitter}ms (max - min)      "
    echo "  │ Std Dev:   ${stddev}ms                  "
    echo "  └─────────────────────────────────────────┘"

    if [[ -n "$rtts_line" ]]; then
        echo ""
        echo "  Sample RTTs: $rtts_line"
    fi

    # Recommendation
    echo ""
    local max_int=${max%.*}
    local median_int=${median%.*}
    local jitter_int=${jitter%.*}
    local recommended_target=$(( max_int + 10 ))

    if [[ $jitter_int -le 5 ]]; then
        info "Connection to Luna is very stable. Stabilizer probably not needed."
    elif [[ $jitter_int -le 15 ]]; then
        info "Mild jitter (${jitter}ms). Stabilizer may help."
    else
        info "Significant jitter (${jitter}ms). Stabilizer recommended."
    fi

    # Since this server blocks ping, suggest using AWS endpoint for monitoring
    info "This server blocks ping, so use a nearby pingable host for monitoring."
    echo ""
    echo "  Suggested workflow:"
    echo "    1. sudo $0 baseline -h dynamodb.us-east-1.amazonaws.com"
    echo "    2. sudo $0 start -t $recommended_target -h dynamodb.us-east-1.amazonaws.com"
    echo ""
    echo "  (target ${recommended_target}ms = max RTT ${max}ms + 10ms headroom)"
}

# ─── Baseline health check ────────────────────────────────────────────────────

cmd_baseline() {
    local host="$DEFAULT_HOST" count=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--host)  host="$2";  shift 2 ;;
            -c|--count) count="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           NETWORK BASELINE REPORT                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    run_ping_test "$host" "$count" "$host"
    local stats="$REPLY_STATS"
    local rtts="$REPLY_RTTS"

    local min avg median max jitter
    read -r min avg median max jitter <<< "$stats"

    # Calculate standard deviation
    local stddev
    stddev=$(echo "$rtts" | awk -v avg="$avg" '
    {
        diff = $1 - avg
        sum_sq += diff * diff
        n++
    }
    END {
        if (n > 1) printf "%.1f", sqrt(sum_sq / (n - 1))
        else print "0.0"
    }')

    # Count how many packets are within various thresholds
    local within_5 within_10 within_20 total
    within_5=$(echo "$rtts" | awk -v med="$median" 'function abs(x) { return x < 0 ? -x : x } abs($1 - med) <= 5 { n++ } END { print n+0 }')
    within_10=$(echo "$rtts" | awk -v med="$median" 'function abs(x) { return x < 0 ? -x : x } abs($1 - med) <= 10 { n++ } END { print n+0 }')
    within_20=$(echo "$rtts" | awk -v med="$median" 'function abs(x) { return x < 0 ? -x : x } abs($1 - med) <= 20 { n++ } END { print n+0 }')
    total=$(echo "$rtts" | wc -l | tr -d ' ')

    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │ Host:      $host"
    echo "  │ Samples:   $count"
    echo "  │                                         │"
    echo "  │ Min:       ${min}ms                     "
    echo "  │ Avg:       ${avg}ms                     "
    echo "  │ Median:    ${median}ms                  "
    echo "  │ Max:       ${max}ms                     "
    echo "  │ Jitter:    ${jitter}ms (max - min)      "
    echo "  │ Std Dev:   ${stddev}ms                  "
    echo "  │                                         │"
    echo "  │ Stability:                              │"
    echo "  │   Within ±5ms of median:  $within_5/$total packets"
    echo "  │   Within ±10ms of median: $within_10/$total packets"
    echo "  │   Within ±20ms of median: $within_20/$total packets"
    echo "  └─────────────────────────────────────────┘"

    # Recommendation
    echo ""
    local max_int=${max%.*}
    local median_int=${median%.*}
    local jitter_int=${jitter%.*}
    local recommended_target=$(( max_int + 10 ))

    if [[ $jitter_int -le 5 ]]; then
        info "Connection is very stable (jitter ${jitter}ms). Stabilizer probably not needed."
    elif [[ $jitter_int -le 15 ]]; then
        info "Connection has mild jitter (${jitter}ms). Stabilizer may help slightly."
        info "Suggested: sudo $0 start -t $recommended_target -h $host"
    elif [[ $jitter_int -le 50 ]]; then
        info "Connection has moderate jitter (${jitter}ms). Stabilizer recommended."
        info "Suggested: sudo $0 start -t $recommended_target -h $host"
    else
        info "Connection has high jitter (${jitter}ms). Stabilizer strongly recommended."
        info "Suggested: sudo $0 start -t $recommended_target -h $host"
        warn "Note: spikes above target (${max}ms) will still pass through."
    fi
}

cmd_usage() {
    cat <<'USAGE'
Ping Stabilizer — Network diagnostics & latency stabilization for cloud gaming

Usage: sudo ./ping-stabilizer.sh <command> [options]

Commands:
  help             Show detailed help for a command
  start            Enable ping stabilization
  stop             Disable and remove all interference
  baseline         Measure jitter to a pingable host
  measure          Measure RTT + dropouts from live traffic (servers that block ping)
  demo             Run before/during/after demonstration
  status           Show current state
  detect           Detect game server IP (run while playing)
  emergency-reset  Force-remove ALL traces (use if stop fails)

Run './ping-stabilizer.sh help <command>' for detailed usage of any command.
USAGE
}

cmd_help() {
    local topic="${1:-overview}"

    case "$topic" in
    start)
        cat <<'HELP'
start — Enable ping stabilization

Usage: sudo ./ping-stabilizer.sh start -t <ms> [-h <host>] [-c <count>]

Options:
  -t, --target <ms>    Target ping in ms (required)
  -h, --host <addr>    Host for baseline + adaptive monitoring (default: 8.8.8.8)
  -c, --count <n>      Pings for baseline measurement (default: 10)

Examples:
  sudo ./ping-stabilizer.sh start -t 50
  sudo ./ping-stabilizer.sh start -t 100 -h dynamodb.us-east-1.amazonaws.com

The -h host is what the background monitor pings to adapt the delay.
All traffic gets the same delay, but it's optimized for the -h host.
Choose the host that matters most for your gaming experience.

A full system snapshot is saved before any changes are made.
HELP
        ;;
    stop)
        cat <<'HELP'
stop — Disable ping stabilization and remove all interference

Usage: sudo ./ping-stabilizer.sh stop

Kills the background monitor, removes the pfctl anchor, restores original
pf rules from backup, releases the pf token, and deletes the dummynet pipe.

If stop fails (e.g. state files missing), use 'emergency-reset' instead.
HELP
        ;;
    baseline)
        cat <<'HELP'
baseline — Measure current jitter to a pingable host

Usage: ./ping-stabilizer.sh baseline [-h <host>] [-c <count>]

Options:
  -h, --host <addr>    Host to ping (default: 8.8.8.8)
  -c, --count <n>      Number of pings (default: 20)

Examples:
  ./ping-stabilizer.sh baseline
  ./ping-stabilizer.sh baseline -h dynamodb.us-east-1.amazonaws.com
  ./ping-stabilizer.sh baseline -h 1.1.1.1 -c 50

Reports min/avg/median/max, jitter, standard deviation, stability score
(packets within +/-5, 10, 20ms of median), and a recommendation with
a suggested start command.

Does not require sudo.
HELP
        ;;
    measure)
        cat <<'HELP'
measure — Measure RTT and dropouts from live game traffic

Usage: sudo ./ping-stabilizer.sh measure -h <ip> [-d <seconds>]

Options:
  -h, --host <ip>      Server IP (required — use 'detect' to find it)
  -d, --duration <sec>  Capture duration (default: 10)

Examples:
  sudo ./ping-stabilizer.sh measure -h 63.178.107.163
  sudo ./ping-stabilizer.sh measure -h 63.178.107.163 -d 30

Uses tcpdump to capture live traffic and analyze:
  - Traffic volume (packets in/out, data size)
  - Dropout detection (gaps >50ms, >100ms, >200ms in incoming stream)
  - RTT estimation from outgoing/incoming packet pair timing

Essential for game servers that block ping (like Amazon Luna).
Run this while actively playing a game.
HELP
        ;;
    demo)
        cat <<'HELP'
demo — Run a before/during/after demonstration

Usage: sudo ./ping-stabilizer.sh demo -t <ms> [-h <host>] [-c <count>]

Options:
  -t, --target <ms>    Target ping in ms (required)
  -h, --host <addr>    Host for monitoring — delay is optimized for this host (default: 8.8.8.8)
  -c, --count <n>      Pings per phase (default: 10)

Examples:
  sudo ./ping-stabilizer.sh demo -t 50
  sudo ./ping-stabilizer.sh demo -t 100 -h dynamodb.us-east-1.amazonaws.com

Runs three phases:
  1. Baseline — pings Google DNS + AWS with no stabilization
  2. Stabilized — enables stabilization, pings both targets
  3. Restored — disables stabilization, pings both to confirm cleanup

Shows a comparison table with jitter reduction for each phase.
HELP
        ;;
    status)
        cat <<'HELP'
status — Show current stabilizer state

Usage: sudo ./ping-stabilizer.sh status

Shows whether the stabilizer is active, current target, monitor PID,
measured RTT (raw), smoothed RTT (EWMA), current applied delay,
and active pfctl rules.
HELP
        ;;
    detect)
        cat <<'HELP'
detect — Detect game server IP from live traffic

Usage: sudo ./ping-stabilizer.sh detect [snap]

Modes:
  detect        Interactive — snapshots connections before/after game launch
  detect snap   Quick — captures 5 seconds of current UDP traffic

Examples:
  sudo ./ping-stabilizer.sh detect snap   # while game is running
  sudo ./ping-stabilizer.sh detect        # guided before/after

Uses tcpdump to capture UDP traffic and ranks external IPs by packet count.
The top talker (thousands of packets/sec) is your game streaming server.

Excludes local/private IPs and DNS traffic automatically.
HELP
        ;;
    emergency-reset)
        cat <<'HELP'
emergency-reset — Force-remove all traces of ping-stabilizer

Usage: sudo ./ping-stabilizer.sh emergency-reset

Use when 'stop' fails (state files missing, system rebooted mid-session).

Actions:
  1. Kills monitor process + hunts orphaned processes by name
  2. Flushes the pfctl anchor
  3. Restores pf rules from snapshot, backup, or /etc/pf.conf
  4. Releases any held pf tokens
  5. Deletes dummynet pipe
  6. Removes state files
  7. Verifies system is clean

As an absolute last resort, you can always run manually:
  sudo pfctl -f /etc/pf.conf && sudo dnctl pipe 1 delete
HELP
        ;;
    overview|*)
        cat <<'HELP'
Ping Stabilizer — Network diagnostics & latency stabilization for cloud gaming

Quick Fix for Luna Stuttering:
  sudo ifconfig awdl0 down     # disable AirDrop WiFi scanning (biggest impact)
  sudo ifconfig awdl0 up       # re-enable after gaming

Diagnostic Workflow:
  ./ping-stabilizer.sh baseline                          # measure jitter
  sudo ./ping-stabilizer.sh detect snap                  # find game server IP
  sudo ./ping-stabilizer.sh measure -h <ip> -d 30        # check RTT + dropouts

Stabilizer Workflow:
  sudo ./ping-stabilizer.sh start -t <target> -h <host>  # enable
  sudo ./ping-stabilizer.sh status                        # check state
  sudo ./ping-stabilizer.sh stop                          # disable

Options (for start/demo):
  -t, --target <ms>    Target ping in ms (required)
  -h, --host <addr>    Ping target host (default: 8.8.8.8)
  -c, --count <n>      Number of pings for measurement (default: 10)

Options (for measure):
  -h, --host <ip>      Server IP (required)
  -d, --duration <sec>  Capture duration (default: 10)

Safety:
  - Snapshots saved to .backups/ before any changes
  - 'stop' cleanly reverses everything
  - 'emergency-reset' works even with missing state files
  - Last resort: sudo pfctl -f /etc/pf.conf && sudo dnctl pipe 1 delete

How it works:
  Unlike fixed delay (Network Link Conditioner), this uses ADAPTIVE delay:
  adds MORE delay when network is fast, LESS when slow, so total RTT
  stays near the target. Background monitor adjusts every 200ms with
  EWMA smoothing to avoid overreacting to outliers.

  Can only ADD delay, never reduce it. Packets above target pass through.

Run './ping-stabilizer.sh help <command>' for detailed help on any command.
HELP
        ;;
    esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    help)             shift; cmd_help "${1:-overview}" ;;
    start)            shift; cmd_start "$@" ;;
    stop)             shift; cmd_stop "$@" ;;
    baseline)         shift; cmd_baseline "$@" ;;
    measure)          shift; cmd_measure "$@" ;;
    status)           cmd_status ;;
    demo)             shift; cmd_demo "$@" ;;
    detect)           shift; cmd_detect "${1:-watch}" ;;
    emergency-reset)  cmd_emergency_reset ;;
    *)                cmd_usage ;;
esac
