# casio

`casio.pl` is a low-level Bluetooth Low Energy (BLE) probe for Casio watches
(for example, the ABL-100WE).

It connects over ATT/L2CAP directly (no external BLE Perl library required)
and can:

- read device identity fields (name and manufacturer)
- read battery percentage
- enumerate primary GATT services
- enumerate characteristics in each service
- dump readable characteristics from a known Casio custom service

## Features

- Direct BLE GATT probing from Perl
- Action-based CLI (`--identify`, `--battery`, `--services`, `--chars`, `--dump-custom`)
- Optional connect retry window (`--listen-seconds`) for watch-initiated timing
- Verbose debug mode (`-v`)

## Requirements

- Linux with Bluetooth LE support
- Perl 5 (uses core modules only: `Getopt::Long`, `Socket`, `Fcntl`, `Errno`)
- Permissions to open Bluetooth L2CAP sockets

Depending on your distro/security settings, you may need root or elevated
capabilities to access raw Bluetooth sockets.

## Quick Start

1. Find your watch BLE MAC address.
2. Run the script with device and action flags.

Example:

```bash
perl casio.pl -d AA:BB:CC:DD:EE:FF --addr-type public --identify --battery
```

If no actions are provided, defaults are:

- `--identify`
- `--battery`

## Usage

```text
Usage: casio.pl -d AA:BB:CC:DD:EE:FF [actions] [options]

Actions (defaults to --identify --battery):
  --identify          Read Device Name (2A00) and Manufacturer (2A29)
  --battery           Read Battery Level (2A19)
  --services          List primary GATT services
  --chars             List characteristics for each primary service
  --dump-custom       Dump readable chars for Casio custom service

Required:
  -d, --device ADDR   BLE MAC address

Options:
  --addr-type TYPE    public|random (default: public)
  --connect-timeout S Connect timeout seconds (default: 8)
  --listen-seconds S  Keep retrying connect for S seconds
  --action-timeout S  ATT read timeout seconds (default: 6)
  -v, --debug         Verbose output
  -h, --help          Show help
```

## Examples

Identify + battery (public address):

```bash
perl casio.pl -d EB:5E:BB:56:29:37 --addr-type public --identify --battery
```

List services:

```bash
perl casio.pl -d EB:5E:BB:56:29:37 --addr-type public --services
```

Listen/retry for 45 seconds (random address) and list characteristics:

```bash
perl casio.pl -d EB:5E:BB:56:29:37 --addr-type random --listen-seconds 45 --chars
```

Dump custom Casio service values with debug output:

```bash
perl casio.pl -d EB:5E:BB:56:29:37 --addr-type random --listen-seconds 45 --dump-custom -v
```

## Notes

- BLE address type matters. If connection fails, try switching `--addr-type`
  between `public` and `random`.
- `--listen-seconds` is useful when connection succeeds only during a short
  watch-initiated BLE window.
- This tool is intended for diagnostics and protocol exploration.

## License

This project is released under The Unlicense. See `LICENSE` for details.
