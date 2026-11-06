
import json
import sys
from pathlib import Path

source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("ferreira_config.json")
config = json.loads(source.read_text(encoding="utf-8"))

depth = int(config["depth"])
banks = int(config["banks"])
words = [0] * (depth * banks)
seen = set()

for write in config["writes"]:
    addr = int(write["addr"])
    bank = int(write["bank"])
    value = int(write["data"], 16)

    if not (0 <= addr < depth and 0 <= bank < banks):
        raise ValueError(f"Invalid address/bank: {addr}/{bank}")

    if not (0 <= value < (1 << 64)):
        raise ValueError("Configuration word exceeds 64 bits")

    if (addr, bank) in seen:
        raise ValueError(f"Duplicate write: {addr}/{bank}")

    seen.add((addr, bank))
    words[addr * banks + bank] = value

output = source.with_name("ferreira_config.mem")
output.write_text(
    "".join(f"{word:016x}\n" for word in words),
    encoding="ascii"
)

print(f"Created {output}: {depth} addresses x {banks} banks")
