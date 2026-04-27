# Services reference

Services are enabled in `configuration.nix`. Each service that sets
`enable = true` gets a launcher script written into `/sbin/svc-<name>`
and an entry added to `/etc/inittab`.

---

## getty (serial console)

```nix
services.getty.enable = true;   # serial console on ttyS0 (default)
```

Options:

| Option | Default | Description |
|---|---|---|
| `tty` | `"ttyS0"` | TTY device for the login prompt |
| `baud` | `115200` | Baud rate |

The QEMU configurations override `tty` to `"ttyAMA0"` (PL011 UART).

---

## SSH (dropbear)

```nix
services.ssh.enable = true;
users.root.hashedPassword = "$6$…";   # openssl passwd -6 yourpassword
```

Dropbear is used instead of OpenSSH — it is a static build with no
dynamic linker dependency and a much smaller footprint. Host keys are
generated automatically on first boot and stored in `/etc/dropbear/`.

To use SSH key authentication only (no password):

```nix
users.root.hashedPassword = "!";   # locks password login
```

Place your public key at `/root/.ssh/authorized_keys` on the device
(or write it into the rootfs via a package).

---

## mesh-bbs

A minimal Meshtastic BBS + store-and-forward bot. Commands are sent
as direct messages to the bot node over the mesh.

```nix
services."mesh-bbs" = {
  enable  = true;
  interface = {
    type       = "serial";
    serialPort = "/dev/ttyACM0";   # or /dev/ttyUSB0 for UART adapters
    # type     = "tcp";
    # host     = "192.168.1.x";
  };
  channel       = 0;     # Meshtastic channel index to monitor (0-7)
  listLimit     = 10;    # max posts returned by `bbs list`
  maxMessageLen = 200;   # bytes per outgoing LoRa chunk (max ~230)
  dataDir       = "/var/lib/mesh-bbs";
};
```

**Commands (send as a direct message to the bot):**

| Command | Action |
|---|---|
| `bbs list` | List the last N posts |
| `bbs read N` | Read post #N in full |
| `bbs post TEXT` | Post TEXT to the BBS |
| `snf send !nodeId TEXT` | Queue TEXT for an offline node |
| `snf list` | Show messages queued for you |
| `snf pending` | Show all pending deliveries (admin) |

---

## meshing-around

Full-featured Meshtastic bot — weather, APRS, games, satellite passes,
and more. Use `mesh-bbs` above for a leaner alternative.

```nix
services."meshing-around" = {
  enable = true;
  interface = {
    type       = "serial";
    serialPort = "/dev/ttyACM0";
    # type     = "tcp";
    # host     = "192.168.1.x";
  };
};
```

---

## meshtasticd

Linux-native Meshtastic daemon. Turns the SBC itself into a full
Meshtastic mesh node (radio hardware attached via SPI/UART).

```nix
services.meshtasticd = {
  enable     = true;
  # configFile = ./meshtasticd-config.yaml;   # omit to use the built-in template
};
```

When `configFile` is omitted, a minimal working config is generated
automatically. Override it by supplying a YAML file in your repo.

---

## nrfnet

TUN/TAP network tunnel over nRF24L01+ SPI radio. Setting `enable = true`
installs `/bin/nrfnet` but does **not** auto-start the daemon — run it
manually or add it as a user service.

```nix
services.nrfnet = {
  enable    = true;
  role      = "primary";         # "primary" or "secondary"
  spiDevice = "/dev/spidev0.0";
  channel   = 42;                # RF channel 0-125
};
```

Run manually:

```sh
nrfnet --primary --spi_device=/dev/spidev0.0 --channel=42
```

---

## companion-satellite

Connects USB HID devices attached to this board (Stream Deck, etc.)
to a remote Bitfocus Companion server on the network.

```nix
services.companion-satellite = {
  enable = true;
  host   = "companion.local";   # hostname or IP of your Companion server
  port   = 16622;
};
```

> **Note:** The derivation builds Companion Satellite from source with
> a cross-compiled musl Node.js. Official pre-built releases are
> glibc-linked and won't run on this rootfs.
> See `pkgs/companion-satellite.nix` for the one-time hash setup step.

---

## User services

Custom shell-script services can be defined inline without creating a
module file:

```nix
services.user."my-daemon" = {
  enable = true;
  action = "respawn";   # "respawn" | "once" | "sysinit"
  script = ''
    exec /bin/my-daemon --foreground
  '';
};
```

The `action` field maps directly to the inittab action. Use `"respawn"`
for long-running daemons (busybox init restarts them on exit), `"once"`
for one-shot setup tasks, and `"sysinit"` for tasks that must complete
before any other process starts.
