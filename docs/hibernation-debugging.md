# Hibernation Debugging on SteamOS — Field Notes

A technical walkthrough of how we diagnosed the hibernation issues on this device
(a Lenovo Legion Go 2 running SteamOS 3.9). Written for an engineer who is **not**
a Linux/systemd specialist: every concept and tool is explained from first
principles, with the exact commands used and how to read their output.

If you're coming from macOS: Linux has no single "Console.app". Instead there's a
structured, binary log called the **journal**, read with `journalctl`. Where
useful, macOS equivalents are noted inline.

---

## 0. TL;DR — what was wrong and what we did

Two independent problems, plus one big misconception:

1. **The "stuck" the other night** was a *direct* hibernate started while a game
   was loaded. The kernel couldn't allocate enough free RAM to build the
   hibernation snapshot (`Error -12`, out of memory), **aborted** the hibernate,
   and on the aborted wake-up the **GPU driver failed to re-initialise**
   (`amdgpu ... ip_resume failed (-110)`). A dead GPU took down the graphical
   session → crash loop → unclean shutdown. Root enabler: Hibernado had disabled
   systemd's pre-flight memory check, so an unsafe hibernate was *attempted*
   instead of *refused*.

2. **"Sleep no longer hibernates" (only pulses white)** was a **config
   precedence** problem. SteamOS now ships its *own* suspend-then-hibernate
   settings in `/usr/lib/systemd/sleep.conf.d/`, and those **override** the
   settings Hibernado writes to `/etc/systemd/sleep.conf`. The effective delay was
   `20min` (not what Hibernado set), and `HibernateOnACPower=no` blocked
   hibernation while charging. So it would suspend but "never" hibernate within
   any reasonable observation window.

3. **Misconception**: that suspend-then-hibernate uses SteamOS's native
   hibernation plumbing. It does **not** — see §6. Native SteamOS swap prep only
   runs for a *direct* `systemctl hibernate`. The suspend-then-hibernate path runs
   on Hibernado's persistent swap file.

The fix that made auto-hibernate work in testing: a drop-in at
`/etc/systemd/sleep.conf.d/zz-hibernado-test.conf` that actually takes precedence.

---

## 1. Concepts you need (from first principles)

### 1.1 Kernel, processes, systemd
- The **kernel** is the core of the OS: it owns memory, CPU scheduling, and
  hardware drivers (including the GPU driver, `amdgpu`).
- **systemd** is the "init system" and service manager — the first userspace
  process (PID 1) and the thing that starts/stops services, targets, and
  orchestrates sleep/shutdown. (macOS equivalent: `launchd`.)
- A **unit** is systemd's object for a thing it manages: `*.service` (a daemon or
  one-shot task), `*.target` (a milestone/grouping, like "Sleep"), `*.timer`,
  `*.swap`, etc.

### 1.2 The sleep states (this is the crux)
Hardware/ACPI defines several low-power states. The three that matter here:

| Name | ACPI | What it does | Power draw | Wake speed |
|------|------|--------------|-----------|-----------|
| **Suspend-to-idle** | "s2idle" (a.k.a. S0ix) | CPU halted, **RAM kept powered**, everything stays in memory | Low, but non-zero (battery still drains slowly) | Instant |
| **Suspend-to-RAM** | S3 ("deep") | Deeper; RAM self-refresh only | Lower than s2idle | Instant |
| **Hibernate** | S4 | **RAM written to disk, machine powered OFF** | ~Zero | Slow (must reload from disk) |

This device only supports **s2idle** (modern AMD handhelds usually drop S3). You
can see supported states:
```bash
cat /sys/power/mem_sleep    # e.g. "[s2idle]"  -> only s2idle available
cat /sys/power/state        # "freeze mem disk" -> freeze=s2idle, disk=hibernate
```

"Sleep" on a handheld = s2idle (fast, small drain). "Hibernate" = S4 (zero drain,
slow). **Suspend-then-hibernate** = do s2idle first, then automatically flip to
hibernate after a delay. Best of both: instant resume if you come back soon, zero
drain if you don't.

### 1.3 Swap, and why hibernation needs it
- **Swap** is disk space the kernel can use to hold memory pages. Normally it's a
  pressure valve: when RAM is full, cold pages get pushed to swap.
- **Hibernation** writes the *entire* contents of RAM into swap, then powers off.
  On next boot the kernel reads it back and you're exactly where you left off.
- So hibernation requires a swap device (a partition or a **swap file**) at least
  big enough to hold the saved image.

On this device:
```bash
swapon --show
# NAME           TYPE      SIZE  USED PRIO
# /dev/zram0     partition 9.5G   ..   100     <- compressed RAM swap (see 1.7)
# /home/swapfile file       20G   0B   -2      <- Hibernado's persistent swap file
```

### 1.4 `resume=` and `resume_offset` (how the machine finds the image at boot)
When the kernel boots, it needs to know *where* a hibernation image might be, to
restore it. That's passed on the kernel command line:
```bash
cat /proc/cmdline
# ... resume=/dev/disk/by-uuid/<UUID> resume_offset=81139712 ...
```
- `resume=` identifies the **block device** (here, the partition holding `/home`).
- `resume_offset=` is needed for a **swap file** (not a partition): it's the
  physical block offset of the file's first extent within the filesystem, so the
  kernel can reach it before the filesystem is mounted.

You verify the offset actually matches the file with:
```bash
sudo filefrag -v /home/swapfile | head
#   0:  0..0:  81139712..81139712:  1:   <- physical_offset must equal resume_offset
```
The live values the kernel is using are in sysfs:
```bash
cat /sys/power/resume          # "259:8"       (major:minor of the device)
cat /sys/power/resume_offset   # "81139712"
cat /sys/power/disk            # "[platform] shutdown ..." (hibernate method)
```

### 1.5 The RTC wake alarm (how suspend-then-hibernate wakes itself)
While in s2idle the CPU is halted — so *something* must wake it to perform the
hibernate after the delay. That "something" is the **RTC** (Real-Time Clock), a
tiny always-on hardware clock that can fire an alarm/IRQ. systemd programs the RTC
to fire after `HibernateDelaySec`; the alarm wakes the SoC from s2idle, and
systemd then proceeds to hibernate.
```bash
cat /proc/driver/rtc                 # shows alrm_time / alarm_IRQ / alrm_pending
cat /sys/class/rtc/rtc0/wakealarm    # unix timestamp of a pending alarm (empty = none)
cat /sys/class/rtc/rtc0/device/power/wakeup   # "enabled" = RTC may wake the system
```
Key insight from this investigation: **if that wake doesn't happen, it stays
suspended forever** and looks like "it never hibernates."

### 1.6 suspend-then-hibernate, precisely
systemd runs `systemd-suspend-then-hibernate.service`, which:
1. Reads `HibernateDelaySec` and `HibernateOnACPower` from the merged `sleep.conf`.
2. Enters s2idle and arms the RTC alarm.
3. On wake, decides:
   - woke by **RTC alarm** (delay elapsed) → **hibernate**;
   - woke by **user** (power button) → just **resume** (you want the device).
4. `HibernateOnACPower=no` means: while on AC/charging, don't count the timer
   down — stay suspended indefinitely (saves nothing by hibernating when plugged
   in). This is why being plugged in blocked hibernation in our first test.

### 1.7 zram — compressed swap that lives in RAM
`/dev/zram0` is a swap device backed by **compressed RAM**, not disk. It lets the
system fit more logical pages in the same physical RAM, at some CPU cost. It does
**not** free physical memory (the compressed bytes still occupy RAM). It's why
low-memory situations degrade gracefully before the out-of-memory killer fires.
Relevant here because it competes for the RAM that hibernation needs (see §1.8).

### 1.8 Why hibernation can fail under a game (unified memory)
Hibernation can't stream RAM straight to disk. At the instant it must take a
**consistent snapshot**, devices (including the disk controller) are being powered
down — so there's nowhere to write yet. The kernel therefore **copies the pages it
must save into spare free RAM first**, then brings the disk back and flushes that
copy. Consequence: it needs **free RAM roughly equal to the size of the image**.

You can see this exact arithmetic in the logs:
```
PM: hibernation: Need to copy 2935957 pages          <- must save ~11.2 GB
PM: hibernation: ... available pages: 2250787         <- only ~8.6 GB free
PM: hibernation: Not enough free memory
PM: hibernation: Error -12 creating image             <- -12 = ENOMEM
```
On this APU the RAM is **unified** (shared with the GPU). A running game's GPU
buffers are **pinned** system RAM — the kernel is not allowed to page them out —
so they must go into the image *and* can't be pre-swapped to disk to make room.
That's why more swap file size does **not** help: the bottleneck is un-swappable
pinned RAM plus the free-RAM copy buffer, not disk capacity. (Proof: the night it
crashed there were ~60 GB of swap active and it *still* said "Not enough free
memory".)

---

## 2. The tools — a macOS engineer's field guide

### 2.1 `journalctl` — reading the system journal
The journal is systemd's structured, indexed log (binary on disk, queried with
`journalctl`). It captures kernel messages (`dmesg`), service stdout/stderr, and
systemd's own events, all timestamped and tagged by unit. (macOS analog:
`log show` / Console.app, but unified across kernel + services.)

Core flags used constantly here:

| Command | Meaning |
|---|---|
| `journalctl -b 0` | messages from the **current boot** (`-b -1` = previous boot, `-b -2` = two ago) |
| `journalctl --list-boots` | table of every recorded boot with its ID and time range |
| `journalctl --no-pager` | don't open a pager (needed when scripting/piping) |
| `journalctl -S "2026-07-07 14:29:00" -U "2026-07-07 14:30:00"` | `--since`/`--until` time window |
| `journalctl -k` | kernel messages only (like `dmesg`) |
| `journalctl -u <unit>` | only logs from a given unit, e.g. `-u systemd-hibernate.service` |
| `journalctl -f` | follow live (like `tail -f`) |
| `journalctl -p err` | only priority "error" and worse |

Reading kernel PM (power management) lines is most of the game here. Useful
grep filters:
```bash
journalctl -b 0 --no-pager | grep -iE "hibernat|suspend|resume|PM:|amdgpu.*resume|s2idle"
```

Why the timestamps look weird during hibernate: the clock is frozen while the
machine is off, so kernel lines written *during* the transition get flushed and
timestamped when the system **resumes**. That's why you'll see "Creating image"
and the resume appear at the same later second — it's an artifact, not a 2-minute
image write.

**On macOS you don't have `journalctl`.** To inspect this box you either SSH into
it (what we did) or, closest local analog, use `log show --predicate ... --last 1h`
on the Mac itself for Mac logs. They are not interchangeable systems.

### 2.2 `systemctl` — controlling systemd
```bash
systemctl suspend                     # go to sleep (routes per SleepOperation)
systemctl hibernate                   # hibernate directly (S4)
systemctl suspend-then-hibernate      # the combined mode
systemctl cat <unit>                  # show a unit file + its drop-ins
systemctl show <unit> -p Wants -p Requires -p After   # inspect dependencies
systemctl list-unit-files | grep -i hibernat          # what exists & is enabled
systemctl status <unit>               # current state + recent logs
```

`systemd-run` was used to schedule a command slightly in the future so our SSH
call returned *before* the machine suspended (otherwise the connection dies
mid-command):
```bash
sudo systemd-run --on-active=5 --unit=test /usr/bin/systemctl suspend-then-hibernate
# creates a transient timer that fires in 5s
```

### 2.3 `systemd-analyze cat-config` — the "effective config" (the key tool)
systemd merges configuration from a main file **plus** drop-in directories. To see
the **final merged result in application order** (which is what actually takes
effect), use:
```bash
systemd-analyze cat-config systemd/sleep.conf
```
This is what revealed that `/usr/lib/.../steamos-suspend-then-hibernate.conf` was
overriding Hibernado's `/etc/systemd/sleep.conf`. See §3.

### 2.4 The `/sys` and `/proc` pseudo-filesystems
These aren't real files — they're kernel state exposed as files (read/write to
query/poke the kernel). We used:
```bash
cat /proc/cmdline               # kernel boot arguments (resume=, etc.)
cat /proc/meminfo               # memory totals
cat /proc/swaps                 # active swap devices (raw form of swapon --show)
cat /sys/power/{state,disk,mem_sleep,resume,resume_offset,image_size}
cat /sys/class/rtc/rtc0/{wakealarm,time,date}
cat /sys/class/power_supply/*/                # online, status, capacity, type
```
`/sys/power/image_size` deserves a note: it's the kernel's **soft target** for the
snapshot size. Lowering it makes the kernel reclaim/swap-out more aggressively to
disk *before* the snapshot (smaller RAM buffer needed); the trade-off is slower
hibernate. It's the most direct lever for "make hibernate fit under load", though
it can't overcome pinned GPU memory.

### 2.5 Memory / swap / disk inspection
```bash
free -h                         # RAM + swap usage, human-readable
swapon --show                   # active swap devices, sizes, priorities
df -h /home                     # free disk on the /home partition
sudo filefrag -v /home/swapfile # physical extents (to verify resume_offset)
ps -eo pid,rss,comm --sort=-rss # processes by resident memory (find the game)
```

### 2.6 Power supply state
```bash
for ps in /sys/class/power_supply/*; do
  echo "$ps online=$(cat $ps/online 2>/dev/null) status=$(cat $ps/status 2>/dev/null)"
done
```
Watch out: a USB-C source can read `online=1` even when the battery shows
`Discharging`. systemd's "on AC power" decision (used by `HibernateOnACPower`) can
be triggered by that USB-C line.

---

## 3. The gotcha: systemd config precedence (drop-ins)

systemd config is assembled from:
1. the **main file**: `/etc/systemd/sleep.conf` — **lowest** precedence;
2. **drop-ins** `*.conf` under (in ascending priority of directory)
   `/usr/lib/systemd/sleep.conf.d/` → `/run/systemd/sleep.conf.d/` →
   `/etc/systemd/sleep.conf.d/`.

Rules:
- Drop-ins **override** the main file.
- Drop-ins are merged **by filename, sorted lexicographically**; later names win
  for conflicting keys.
- If two drop-ins share the **same filename**, the one in the higher-priority
  directory (`/etc` beats `/usr`) wins.

So Hibernado writing `HibernateDelaySec` into the *main* `/etc/systemd/sleep.conf`
is the **weakest** possible place — any `/usr/lib` drop-in beats it. SteamOS ships:
```
/usr/lib/systemd/sleep.conf.d/steamos-suspend-then-hibernate.conf
    HibernateDelaySec=20min
    HibernateOnACPower=no
```
which quietly won. The fix is a drop-in in `/etc` whose name sorts **after**
`steamos-` (so it's applied last) — e.g. `zz-hibernado-*.conf`:
```ini
# /etc/systemd/sleep.conf.d/zz-hibernado-test.conf
[Sleep]
HibernateDelaySec=30s
HibernateOnACPower=yes
```
Verify it actually won:
```bash
systemd-analyze cat-config systemd/sleep.conf | grep -iE "HibernateDelaySec|HibernateOnACPower"
# ... the LAST occurrence is the effective one
```

---

## 4. The investigation, step by step

1. **Establish the machine & symptoms.** SSH in; `uname -a`, `/etc/os-release`
   (SteamOS 3.9 on Legion Go 2), reproduce the mental model of "purple vs white
   LED".
2. **Snapshot the hibernation config state.** `/proc/cmdline`, `swapon --show`,
   `/sys/power/*`, the GRUB drop-in, and the resume script. Confirmed the swap
   file offset matched `resume_offset` (so resume config was internally
   consistent).
3. **Pull the sleep/hibernate history across boots.** `journalctl --list-boots`
   then grep each boot for `hibernat|suspend|resume|PM:`. This located a
   *successful* suspend-then-hibernate (00:07) and the *failed* direct hibernate.
4. **Zoom into the failure window** with `-S/-U`. Found `Error -12 creating
   image` (ENOMEM) followed by `amdgpu ... ip_resume failed (-110)` and gamescope
   `fatal flip` — the root cause chain of the "stuck".
5. **Distinguish the two code paths.** `systemctl cat` / `systemctl show` on the
   hibernate and suspend-then-hibernate services, plus checking which boots ran
   `hibernate-prepare.service`. Learned native prep runs only for *direct*
   hibernate (§6).
6. **First live test** (set delay in main `sleep.conf`, trigger, observe): it
   suspended but never hibernated.
7. **Root-caused the test failure** by checking `systemd-analyze cat-config` and
   `/sys/class/power_supply/*`: the SteamOS `/usr/lib` drop-in was overriding the
   delay (20min) and blocking on AC.
8. **Correct the config** with an `/etc` drop-in, re-verify the merged result, and
   **re-test**: clean suspend → 30s auto-wake → hibernate → resume, no crash
   markers.

The discipline throughout: **find the root cause before changing anything, change
one variable at a time, and verify with evidence** (here, the merged config and
the journal) rather than guessing.

---

## 5. Root causes (summary)

| Symptom | Root cause | Evidence |
|---|---|---|
| Crash / "stuck" | Direct hibernate under memory pressure → `Error -12` (ENOMEM) → aborted → `amdgpu ip_resume failed (-110)` → gamescope crash loop | journal 01:34 window |
| Enabled the unsafe attempt | Hibernado set `SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1` in a logind drop-in | `systemd-logind.service.d/hibernado-override.conf` |
| "Only sleeps, never hibernates" | SteamOS `/usr/lib` sleep drop-in (`20min`, `HibernateOnACPower=no`) overrides Hibernado's main `sleep.conf` | `systemd-analyze cat-config` |
| Bigger swap doesn't fix mid-game hibernate | Bottleneck is pinned (GPU) RAM + free-RAM snapshot buffer, not disk | ENOMEM with ~60 GB swap active |

---

## 6. Architecture note: Hibernado vs native SteamOS hibernation

- **Direct hibernate** (`systemctl hibernate` / hibernate.target): SteamOS's
  `hibernate-prepare.service` runs `/usr/lib/holo/hibernate-swap-helper.sh`, which
  creates a **temporary** `/home/hibernation.swapfile` (sized ~RAM+VRAM), sets the
  resume parameters, and deletes it on resume. This is native SteamOS.
- **Suspend-then-hibernate** (your normal sleep): `hibernate-prepare.service`
  **does not run** (it's `WantedBy=hibernate.target`, which this path doesn't
  activate). The hibernate phase uses whatever swap + resume config already
  exists — i.e. **Hibernado's persistent `/home/swapfile`** and the GRUB
  `resume=`/`resume_offset`. Verified: the successful s-t-h cycles have no
  "Prepare Temporary Hibernation Swap" log line.

**Implication:** for the suspend-then-hibernate flow, Hibernado is doing the real
work (persistent swap + resume config); native SteamOS never steps in. So keeping
Hibernado is correct for that flow, and there is **no** native-vs-Hibernado
conflict there. The only place both try to configure resume is the *direct*
hibernate path.

---

## 7. Reproduce / verify — a quick runbook

```bash
# 1. See supported states and current hibernate plumbing
cat /sys/power/mem_sleep /sys/power/state /sys/power/disk
cat /proc/cmdline | tr ' ' '\n' | grep resume
swapon --show

# 2. See the EFFECTIVE sleep policy (main file + all drop-ins merged)
systemd-analyze cat-config systemd/sleep.conf | grep -iE "HibernateDelaySec|HibernateOnACPower|Allow"

# 3. Watch a full cycle. Drop a marker, schedule the sleep so SSH returns first:
logger -t hibtest "=== CYCLE START ==="
sudo systemd-run --on-active=5 /usr/bin/systemctl suspend-then-hibernate
#   ... leave it untouched past HibernateDelaySec so it self-hibernates ...
#   ... power on to resume, then: ...

# 4. Read back the cycle and check for failure markers
journalctl -b 0 --no-pager -S "$(journalctl -b0|grep 'CYCLE START'|tail -1|awk '{print $1,$2,$3}')" \
  | grep -iE "suspend entry|Performing sleep|hibernation (entry|exit)|Need to copy|available pages|System returned"
journalctl -b 0 --no-pager | grep -iE "failed -110|Error -12|Cannot allocate|fatal flip|Not enough free"
#   ^ that second command should print NOTHING on a healthy cycle
```

A healthy suspend-then-hibernate cycle shows, in order: `suspend entry (s2idle)` →
(after the delay) `System returned from sleep operation 'suspend-then-hibernate'`
→ `Performing sleep operation 'hibernate'` → `hibernation entry` →
`Need to copy N pages / available pages: M` with **M > N** → power off →
(on power-on) `SMU is resumed successfully` → `hibernation exit` → thawed →
`Finished System Suspend then Hibernate`.

---

## 8. Making the fixes reproducible (plugin code, not just the device)

Everything in §1–§7 was done by editing files under `/etc` on the Deck directly.
Those live on the writable overlay, so they survive reboots — **but** a plugin
reinstall, a re-run of "Setup Hibernation", or a SteamOS update can wipe or
re-override them. To make the fixes durable they were folded back into the
plugin's helper (`bin/hibernate-helper.sh`):

1. **Sleep policy is written as a drop-in, not the main file.** The helper now
   writes `/etc/systemd/sleep.conf.d/zz-hibernado.conf` (see `write_sleep_dropin`)
   instead of overwriting `/etc/systemd/sleep.conf`. The `zz-` prefix sorts after
   SteamOS's `steamos-*.conf`, and `/etc` beats `/usr/lib`, so Hibernado's
   `HibernateDelaySec` actually takes effect (the root cause in §3). `set-delay`
   and `get-delay` read/write this drop-in; `status` checks for it.
2. **The memory-check bypass is never installed, and is removed on setup.**
   `prepare` calls `remove_memory_check_bypass`, which deletes the old
   `systemd-logind.service.d/hibernado-override.conf` if present. A memory-starved
   hibernate is now *refused* (stays safely suspended) instead of crashing the GPU.
3. **`HibernateOnACPower=no`** is written into the drop-in: the hibernate timer
   only counts down on battery, matching SteamOS's own default.
4. **Legacy migration.** `migrate_legacy_sleep_conf` removes an old
   plugin-written main `/etc/systemd/sleep.conf` (only if it carries our marker
   comment) so the drop-in wins cleanly on upgraded installs.

Re-running "Setup Hibernation" (or reinstalling the plugin) now reproduces the
exact working state, and `cleanup`/uninstall removes the drop-in too.

### Still to validate on-device

- **Deploy the rebuilt plugin and run one full cycle** with the bypass gone, to
  confirm a normal (light-memory) suspend-then-hibernate still succeeds with
  systemd's memory check active.
- **Pick the real-world delay** (code default is `60min`; the `30s` used during
  debugging was only a test value). Adjust via the plugin's delay control.
