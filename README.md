# Hibernado

A Decky Loader plugin that enables hibernation on Steam Deck. 

![plugin ui](assets/thumbnail.jpeg)

###  Options
- Direct hibernation - system saves state to disk and powers off completely
- Suspend then Hibernate - Suspend to RAM first, then automatically hibernate after 60 minutes (quick resume if within delay, zero battery drain after)

- Power button override - optionally make the hardware power button trigger immediate hibernate or suspend-then-hibernate
- Adjustable suspend→hibernate delay - change the delay (default 60 minutes) from the plugin UI


- Works entirely within the `/home` partition
- All changes are isolated and easily reversible
- Removes all configuration when plugin is uninstalled

## How this fork differs from upstream

This is a fork of [xXJSONDeruloXx/hibernado](https://github.com/xXJSONDeruloXx/hibernado) with correctness and safety fixes for current SteamOS (which now ships its own native hibernation support):

- **The suspend→hibernate delay actually takes effect.** SteamOS ships its own sleep policy in `/usr/lib/systemd/sleep.conf.d/`, which *overrides* the main `/etc/systemd/sleep.conf` that upstream wrote — so the configured delay was silently ignored. This fork writes a drop-in at `/etc/systemd/sleep.conf.d/zz-hibernado.conf` that sorts after (and therefore outranks) the SteamOS defaults.
- **Safe out-of-memory behavior.** Upstream set `SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1`, which allowed a hibernate to be attempted even without enough free RAM to build the image — aborting mid-snapshot and crashing the GPU (a hard hang). This fork never installs that bypass and removes it from existing setups, so a memory-starved hibernate is *refused* (the Deck stays safely suspended) instead of crashing.
- **"Hibernate While Charging" toggle.** New UI option (`HibernateOnACPower`) to choose whether suspend→hibernate still hibernates while plugged in, or stays suspended for instant resume.
- **Immediate hibernate goes through systemd.** "Hibernate Now" is routed via `systemctl hibernate` so `hibernate.target` is reached and the post-resume hooks (Bluetooth fix, SteamOS boot-counter reset) run — matching the suspend→hibernate path.
- **Cleaner migration & uninstall.** Automatically migrates away from the old main-`sleep.conf` approach, and removes the drop-in and bypass on cleanup/uninstall.

For the full debugging story and technical background, see [`docs/hibernation-debugging.md`](docs/hibernation-debugging.md).

## Usage

1. Open Hibernado from the Decky menu
2. Check the status indicator - if not green, click "Setup Hibernation" to configure automatically
3. Choose your power option:
   - **Hibernate Now**: Immediate hibernation (best for long-term storage)
   - **Suspend then Hibernate**: Quick suspend with automatic hibernation after delay (best for flexibility)
   - **Power Button Override**: Toggle "Override Power Button" to make the hardware power button trigger your chosen hibernation behavior (Hibernate Now or Suspend→Hibernate)
   - **Delay Setting**: When using Suspend→Hibernate you can change the delay (minutes/hours) from the plugin UI under "Suspend-Then-Hibernate Settings"
   - **Hibernate While Charging**: Toggle whether suspend→hibernate also hibernates on AC power, or stays suspended for instant resume while plugged in
4. Resume by pressing the power button

## How It Works

1. **Swapfile Creation**: Creates a swapfile on `/home` (writable partition) sized to RAM + 1GB for optimal hibernation
2. **Resume Configuration**: Calculates swapfile offset and UUID, adds resume parameters to GRUB
3. **Systemd Setup**: Writes a `sleep.conf.d` drop-in for suspend-then-hibernate timing that outranks the SteamOS defaults (leaving systemd's memory safety check in place)
4. **Hardware Fixes**: Installs post-resume scripts to fix Bluetooth connectivity and SteamOS boot counting
5. **Persistence**: All changes survive SteamOS updates without filesystem unlocking

For technical details, see the implementation in `bin/hibernate-helper.sh`.

## Development

### Setup & Build

```bash
# Install dependencies
pnpm install

# Build the installable plugin zip (via the Decky CLI)
just build

# Build only the frontend bundle (no zip)
pnpm run build

# Clean build artifacts
just clean
```

### Testing on Steam Deck

Update the Deck's IP address in `justfile` (default: 192.168.0.232), then:

```bash
# Build, deploy, and watch logs
just test

# Watch logs only
just watch

# SSH to Deck
just ssh
```

The `just test` command builds the plugin, copies it to your Deck, and displays live journal logs for debugging.

## Troubleshooting

- **Setup Stuck**: Check available space on `/home` - you need at least RAM + 1GB free
- **Resume Issues**: Verify GRUB configuration at `/etc/default/grub.d/hibernado.cfg`
- **Bluetooth Problems**: The Bluetooth fix service should activate automatically; check with `systemctl status fix-bluetooth-resume.service`
- **Status Not Green**: Run setup again - the plugin verifies all components are correctly configured

## Credits

Based on the excellent guide: [Steam Deck Hibernation Guide](https://github.com/nazar256/publications/blob/main/guides/steam-deck-hibernation.md) by nazar256.

## License

BSD-3-Clause
