# Event stream API

Axial provides a local Unix domain socket that carries device events as fixed
size binary records. It is useful for diagnostics, integrations, and tools that
need direct access to SpaceMouse input without loading one of Axial's
compatibility frameworks.

## Connection

The default socket path is:

```text
/tmp/axial-$UID/events
```

`$UID` is the numeric Unix user ID, not the account name. In a shell, print it
with:

```sh
id -u
```

For example, if `id -u` prints `501`, the default path is
`/tmp/axial-501/events`. In shells that define the `$UID` variable, such as zsh
and bash, `echo "$UID"` prints the same value.

Set `AXIAL_SOCKET` to use another path. The service creates the parent directory
with mode `0700` and the socket with mode `0600`; connections from another Unix
user are rejected. The socket is an `AF_UNIX` `SOCK_STREAM`. It has no message
boundaries, so clients must read and write complete records themselves.

The service may be unavailable while Axial is starting or after it has stopped.
Clients should reconnect when a connection fails. A client that uses the
`Stream` helper in `include/axial/stream.hpp` is automatically retried every
100 ms.

## Record format

Every record is exactly 64 bytes. Values use the host's little-endian layout on
the supported macOS architectures (Apple silicon and Intel). The layout is:

| Offset | Size | Field | Description |
| ---: | ---: | --- | --- |
| 0 | 4 | `magicValue` | `0x534e4156` (`SNAV`) |
| 4 | 2 | `version` | `1` |
| 6 | 2 | `kind` | Event kind, described below |
| 8 | 8 | `received` | Monotonic timestamp in nanoseconds |
| 16 | 8 | `sequence` | Per-device input sequence number |
| 24 | 4 | `device` | Axial device identifier |
| 28 | 4 | `buttons` | Current 32-bit button mask |
| 32 | 12 | `axes` | Six signed 16-bit axis values |
| 44 | 2 | `vendor` | USB vendor ID |
| 46 | 2 | `product` | USB product ID |
| 48 | 4 | `flags` | Event and connection flags |
| 52 | 4 | `pid` | Sender process ID in a hello record |
| 56 | 8 | `decoded` | Service decode timestamp in nanoseconds |

`received` and `decoded` use `mach_continuous_time` converted to nanoseconds.
They are suitable for ordering and latency measurements within the running
system; they are not wall-clock timestamps.

## Opening a stream

The first record sent by a client must be a `hello` record. The service sends
the current `added` record for each connected device after accepting a normal
subscriber. A hello record normally has `pid` set to the client's process ID.

Set these flags in the hello record to select a stream:

| Flag | Value | Meaning |
| --- | ---: | --- |
| `monitor` | `1` | Receive raw events before the active application's profile filtering |
| `replay` | `2` | Send events into the service instead of subscribing; accepted only by the mock service used for tests |

With no flags, a subscriber receives events after the active profile has applied
gain, dead zones, axis inversion, dominant-axis mode, translation/rotation
switches, orbit mode, and suppressed buttons. Motion and button events are
delivered to the foreground application. Device lifecycle events are delivered
regardless of foreground focus. A monitor receives the raw event data and does
not receive profile-filtered data. Monitor events are also independent of
foreground focus: a monitoring app can remain in the background and continue to
observe SpaceMouse motion and button activity while another app is active.

The service identifies the peer process and requires it to have the same Unix
user as the service. A malformed record, an invalid first record, or a full
client queue closes the connection.

## Event kinds

| `kind` | Value | Meaning |
| --- | ---: | --- |
| `hello` | 1 | Client registration record; sent by the client only |
| `motion` | 2 | One or more of the six axes changed; `axes` contains the current values |
| `buttons` | 3 | The button mask changed; `buttons` contains the current mask |
| `added` | 4 | A device became available; identity fields are populated |
| `removed` | 5 | A device was disconnected; `axes` and `buttons` are cleared |
| `reset` | 6 | Input state was reset, such as after focus or service changes |
| `command` | 7 | An application command was triggered; `flags` identifies the command |

`device` is zero for service-wide reset events. `vendor` and `product` contain
the USB identity for device events. A button bit is set while that button is
held. Axis values are signed HID-scale values; their interpretation as
translation or rotation depends on the consumer and the active profile.

## Use it from Python

In practice, a client opens the Unix socket, sends a `hello` record, then reads
64-byte records until the service closes the connection. Python's standard
library is sufficient; no Axial package is required. This complete example
runs as a background monitor and prints useful information for every event:

```python
import os
import socket
import struct

MAGIC = 0x534E4156
VERSION = 1
HELLO, MOTION, BUTTONS, ADDED, REMOVED, RESET, COMMAND = range(1, 8)
MONITOR = 1

# < means little-endian. The format is exactly 64 bytes.
EVENT = struct.Struct("<IHHQQII6hHHIIQ")


def read_exact(connection, size):
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def socket_path():
    return os.environ.get("AXIAL_SOCKET", f"/tmp/axial-{os.getuid()}/events")


def connect_monitor():
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(socket_path())
    hello = EVENT.pack(
        MAGIC, VERSION, HELLO,
        0, 0, 0, 0,                 # received, sequence, device, buttons
        0, 0, 0, 0, 0, 0,            # six axes
        0, 0,                       # vendor, product
        MONITOR, os.getpid(), 0,     # flags, pid, decoded
    )
    connection.sendall(hello)
    return connection


def unpack_event(record):
    values = EVENT.unpack(record)
    if values[0] != MAGIC or values[1] != VERSION:
        raise RuntimeError("unsupported Axial event record")
    return {
        "kind": values[2], "received": values[3], "sequence": values[4],
        "device": values[5], "buttons": values[6], "axes": values[7:13],
        "vendor": values[13], "product": values[14], "flags": values[15],
        "pid": values[16], "decoded": values[17],
    }


devices = {}
with connect_monitor() as connection:
    while record := read_exact(connection, EVENT.size):
        event = unpack_event(record)
        kind = event["kind"]
        device = event["device"]

        if kind == MOTION:
            devices.setdefault(device, {})["axes"] = event["axes"]
            print("motion", device, event["axes"])
        elif kind == BUTTONS:
            devices.setdefault(device, {})["buttons"] = event["buttons"]
            print("buttons", device, hex(event["buttons"]))
        elif kind == ADDED:
            devices[device] = {
                "vendor": event["vendor"], "product": event["product"],
                "axes": event["axes"], "buttons": event["buttons"],
            }
            print("added", device, hex(event["vendor"]), hex(event["product"]))
        elif kind == REMOVED:
            devices.pop(device, None)
            print("removed", device)
        elif kind == RESET:
            if device == 0:
                devices.clear()
            elif device in devices:
                devices[device]["axes"] = (0, 0, 0, 0, 0, 0)
                devices[device]["buttons"] = 0
            print("reset", device)
        elif kind == COMMAND:
            print("command", device, hex(event["flags"]))
        elif kind == HELLO:
            raise RuntimeError("hello is sent by the client, not received")
        else:
            raise RuntimeError(f"unknown event kind: {kind}")
```

Save it as `monitor.py` and run `python3 monitor.py` while Axial is running.
The first records are normally `added` events for devices that are already
connected. The monitor continues receiving motion and button events while the
monitoring process stays in the background and another app is active.

The handler keeps the latest state in `devices`: `motion` replaces the six axis
values, `buttons` replaces the button mask, `added` creates a device entry, and
`removed` deletes one. `reset` clears transient state; a reset with `device ==
0` applies to all devices. `command` is an application command and should be
interpreted from `flags`; `hello` is sent during setup and is not expected in
the receive loop.

`recv()` can return a partial record because this is a stream socket, so the
`read_exact` helper is required. When it returns `None`, the service has closed
the connection. A long-running integration should close the socket, wait
briefly, and call `connect_monitor()` again.

To receive profile-filtered events for the foreground application, send a
hello with `flags` set to `0` instead of `MONITOR`. Set `AXIAL_SOCKET` when the
service uses a non-default path; otherwise the example derives the default
path from `os.getuid()`.

## Related control socket

The service's request API is a separate newline-delimited JSON protocol at
`/tmp/axial-$UID/events.control` (or the `AXIAL_SOCKET` path with
`.control` appended). The bundled `axialctl` command uses it for `status`,
`config`, `commands`, `calibrate`, and configuration updates. `{"op":"calibrate"}`
rezeroes each device that has 3DxWare's calibration feature report (ID 7,
usage `0xff00:0x22`, set to 0 while the LED blinks for about four seconds); add
`"device":id` for one device. The response counts those devices in
`calibrated`; status reports `rezero`, `calibrating` and `deviceCalibrated` per
device. It is not part of the binary event record stream described here.
