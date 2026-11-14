"""Load Ferreira graph configurations to a Nexys A7 over USB-UART.

Protocol v1 (CRC16-CCITT, little-endian) matches ferreira_uart_loader.v.
Example:
  py -m pip install pyserial
  py ferreira_upload.py --list-ports
  py ferreira_upload.py --port COM5 ferreira_config.json
  py ferreira_upload.py --dry-run ferreira_config.json
"""
from __future__ import annotations

import argparse
import binascii
import json
import time
from pathlib import Path


CAPACITIES = [1, 2, 4, 8]
DEPTH = 32
BANKS = 2


def verilog_hex(value: str) -> int:
    if "'h" not in value.lower():
        raise ValueError(f"Expected Verilog hex literal, got {value!r}")
    return int(value.lower().split("'h", 1)[1].replace("_", ""), 16)


def build_packet(cfg: dict) -> bytes:
    expected = {
        "genes": 4,
        "capacities": CAPACITIES,
        "route_n": 16,
        "kmax": 8,
        "stages": 6,
        "switch_width": 48,
        "mem_width": 80,
        "banks": BANKS,
        "depth": DEPTH,
        "max_degree": 256,
        "cw": 9,
    }
    for field, want in expected.items():
        if cfg.get(field) != want:
            raise ValueError(
                f"{field}: JSON has {cfg.get(field)!r}, "
                f"but this bitstream requires {want!r}"
            )
    if verilog_hex(cfg["cap_log2_verilog"]) != 0x688:
        raise ValueError("Physical PE layout mismatch")

    substeps = cfg["substeps"]
    if not isinstance(substeps, int) or not (1 <= substeps <= DEPTH):
        raise ValueError("Substep count outside 1..32")

    rule = verilog_hex(cfg["rule_verilog"])
    degree = verilog_hex(cfg["degree_verilog"])
    if rule >> 4 or degree >> 36:
        raise ValueError("Rule or degree metadata exceeds hardware width")
    degrees = [(degree >> (i * 9)) & 0x1ff for i in range(4)]
    if any(d > 256 for d in degrees):
        raise ValueError(f"Packed degree exceeds MAX_DEGREE: {degrees}")

    words = {(int(w["addr"]), int(w["bank"])): int(w["data"], 16)
             for w in cfg["writes"]}
    if len(words) != len(cfg["writes"]):
        raise ValueError("Duplicate address/bank write in JSON")
    for addr, bank in words:
        if not (0 <= addr < substeps and 0 <= bank < BANKS):
            raise ValueError(f"Unexpected word address/bank: {addr}, {bank}")
    if any(not 0 <= v < (1 << 64) for v in words.values()):
        raise ValueError("Word exceeds 64 bits")

    # All words transmitted (missing words zero-filled). Lower 16 bits of
    # bank1 are meaningful for the 80-bit MIN configuration.
    payload = bytearray([1, substeps, rule])
    payload.extend(degree.to_bytes(5, "little"))
    for a in range(substeps):
        for b in range(BANKS):
            value = words.get((a, b), 0)
            if b == 1 and value >> 16:
                raise ValueError("Bank1 has nonzero bits above MEM_W=80")
            payload.extend(value.to_bytes(8, "little"))

    crc = binascii.crc_hqx(payload, 0xFFFF)
    return b"FG" + payload + crc.to_bytes(2, "little")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("config", nargs="?", help="Compiled ferreira_config.json")
    p.add_argument("--port", help="Windows COM port, e.g. COM5")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--list-ports", action="store_true")
    p.add_argument("--emit-hex", type=Path,
                   help="Write one hexadecimal byte per line for testbench")
    p.add_argument("--emit-bin", type=Path)
    args = p.parse_args()

    if args.list_ports:
        try:
            from serial.tools import list_ports
        except ImportError as exc:
            raise SystemExit("Install pyserial: py -m pip install pyserial") from exc
        for port in list_ports.comports():
            print(f"{port.device:8s}  {port.description}")
        return

    if not args.config:
        p.error("a compiled configuration JSON is required")
    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    packet = build_packet(cfg)
    print(f"Packet: {len(packet)} bytes; substeps={cfg['substeps']}; "
          f"rules={cfg['rule_verilog']}; degree={cfg['degree_verilog']}")

    if args.emit_hex:
        args.emit_hex.write_text("".join(f"{b:02x}\n" for b in packet),
                                 encoding="ascii")
        print(f"Wrote {args.emit_hex}")
    if args.emit_bin:
        args.emit_bin.write_bytes(packet)
        print(f"Wrote {args.emit_bin}")
    if args.dry_run:
        return

    if not args.port:
        p.error("--port is required unless --dry-run is used")
    try:
        import serial
    except ImportError as exc:
        raise SystemExit("Install pyserial: py -m pip install pyserial") from exc

    with serial.Serial(args.port, args.baud, timeout=3,
                       write_timeout=3, rtscts=False, dsrdtr=False,
                       xonxoff=False) as device:
        # Let VCP settle, then clear old bytes before starting the frame.
        time.sleep(0.05)
        device.reset_input_buffer()
        device.write(packet)
        device.flush()
        answer = device.read(1)

    if answer == b"\x06":
        print("ACK: graph installed. Change SW[3:0] and press BTNC.")
    elif answer == b"\x15":
        raise SystemExit("NAK: FPGA rejected the frame. LED14 indicates error.")
    else:
        raise SystemExit(
            "No ACK received. Check the USB-UART COM port/driver, "
            "100 MHz clock, and CPU reset. Device may need reset."
        )


if __name__ == "__main__":
    main()
