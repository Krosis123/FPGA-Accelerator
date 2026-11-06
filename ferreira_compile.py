
import argparse
import json
from collections import Counter
from pathlib import Path


def power_of_two(n):
    return 1 << (n - 1).bit_length()


def compile_graph(graph, min_substeps=2, depth=32):

    n = graph["genes"]
    caps = graph["capacities"]
    rules = graph.get("rules", ["AI"] * n)

    edges = [
        (int(e["src"]), int(e["dst"]),
         e.get("type", "A").upper())
        for e in graph["edges"]
    ]

    assert n > 0
    assert len(caps) == n
    assert len(rules) == n

    assert all(
        c > 0 and c & (c - 1) == 0 and c <= 32
        for c in caps
    )

    assert all(
        r.upper() in ("AI", "MAJ")
        for r in rules
    )

    assert all(
        0 <= s < n and 0 <= d < n and t in ("A", "I")
        for s, d, t in edges
    )

    # ==========================================
    # 1. Physical PE slot allocation
    # ==========================================

    base = []
    offset = 0

    for c in caps:
        base.append(offset)
        offset += c

    used_lines = sum(caps)
    route_n = power_of_two(max(2, used_lines))

    stages = route_n.bit_length() - 1 + 2

    switch_w = (route_n // 2) * stages
    mem_w = switch_w + 2 * route_n
    banks = (mem_w + 63) // 64

    # Exactly matches ferreira_min.v shuffle.
    shuffle = [
        ((2 * w) % route_n) +
        (w // (route_n // 2))
        for w in range(route_n)
    ]

    # Each source gene is replicated onto the
    # physical input slots allocated to its PE.
    source_gene = [-1] * route_n

    for g, c in enumerate(caps):
        source_gene[base[g]:base[g] + c] = [g] * c

    # ==========================================
    # 2. Greedy routing and sub-step scheduling
    # ==========================================

    pending = list(edges)
    words = []
    assignments = []

    while pending:

        # -1 = unconfigured, 0 = straight,
        # 1 = crossed
        cfg = [
            [-1] * (route_n // 2)
            for _ in range(stages)
        ]

        # Occupied physical wires at each level.
        occupied = [
            [False] * route_n
            for _ in range(stages + 1)
        ]

        valid = 0
        inhibit = 0

        successful = []
        frame_assignments = []

        for edge in pending:

            src, dst, typ = edge

            # Find paths through the layered MIN.
            predecessors = [
                {} for _ in range(stages + 1)
            ]

            # Any unused physical copy of src
            # can start this connection.
            for w in range(
                base[src],
                base[src] + caps[src]
            ):
                if not occupied[0][w]:
                    predecessors[0][w] = None

            # Search each routing stage.
            for stage in range(stages):

                for w in predecessors[stage]:

                    pair = w // 2

                    if cfg[stage][pair] == -1:
                        options = (0, 1)
                    else:
                        options = (cfg[stage][pair],)

                    for swap in options:

                        after = w ^ swap

                        if stage < stages - 1:
                            next_wire = shuffle[after]
                        else:
                            next_wire = after

                        if (
                            not occupied[stage + 1][next_wire]
                            and next_wire not in
                            predecessors[stage + 1]
                        ):
                            predecessors[stage + 1][
                                next_wire
                            ] = (w, swap)

            # Destination can use any free input
            # slot belonging to its physical PE.
            dest = next(
                (
                    w for w in range(
                        base[dst],
                        base[dst] + caps[dst]
                    )
                    if w in predecessors[stages]
                ),
                None
            )

            # A blocking conflict means this
            # edge is deferred to another sub-step.
            if dest is None:
                continue

            # Reconstruct and reserve the path.
            path = [0] * (stages + 1)
            path[stages] = dest

            for stage in range(
                stages - 1, -1, -1
            ):

                prev, swap = predecessors[
                    stage + 1
                ][path[stage + 1]]

                path[stage] = prev
                pair = prev // 2

                assert cfg[stage][pair] in (
                    -1, swap
                )

                cfg[stage][pair] = swap

            for stage, w in enumerate(path):
                assert not occupied[stage][w]
                occupied[stage][w] = True

            valid |= 1 << dest

            if typ == "I":
                inhibit |= 1 << dest

            successful.append(edge)
            frame_assignments.append(
                [src, dst, typ, dest]
            )

        if not successful:
            raise RuntimeError(
                "Edge cannot be routed even "
                "in an empty sub-step"
            )

        for edge in successful:
            pending.remove(edge)

        # ======================================
        # 3. Pack routing configuration
        # ======================================

        switch_cfg = sum(
            1 << (stage * (route_n // 2) + p)
            for stage in range(stages)
            for p in range(route_n // 2)
            if cfg[stage][p] == 1
        )

        # Packing must match ferreira_system.v:
        #
        # {inhibitor_mask, valid_mask, switches}

        word = (
            switch_cfg
            | (valid << switch_w)
            | (inhibit << (switch_w + route_n))
        )

        words.append(word)
        assignments.append(frame_assignments)

        if len(words) > depth:
            raise RuntimeError(
                f"Need {len(words)} substeps, "
                f"but DEPTH={depth}"
            )

    # Add empty sub-steps if the controller
    # is configured for more than were needed.
    while len(words) < min_substeps:
        words.append(0)
        assignments.append([])

    if len(words) > depth:
        raise RuntimeError(
            "Insufficient configuration RAM depth"
        )

    # ==========================================
    # 4. Independent route verification
    # ==========================================

    recovered = []

    for word, frame in zip(
        words, assignments
    ):

        lanes = source_gene[:]

        cfg_bits = word & (
            (1 << switch_w) - 1
        )

        for stage in range(stages):

            nxt = lanes[:]

            for pair in range(route_n // 2):

                bit = (
                    cfg_bits >>
                    (stage * (route_n // 2) + pair)
                ) & 1

                if bit:
                    a = 2 * pair
                    b = a + 1

                    nxt[a], nxt[b] = (
                        nxt[b], nxt[a]
                    )

            if stage < stages - 1:

                shuffled = [-1] * route_n

                for i, gene in enumerate(nxt):
                    shuffled[shuffle[i]] = gene

                lanes = shuffled

            else:
                lanes = nxt

        valid = (
            word >> switch_w
        ) & ((1 << route_n) - 1)

        inhib = (
            word >> (switch_w + route_n)
        ) & ((1 << route_n) - 1)

        expected = {
            dstline: (src, dst, typ)
            for src, dst, typ, dstline in frame
        }

        assert valid.bit_count() == len(frame)
        assert (inhib & ~valid) == 0

        for lane in range(route_n):

            if (valid >> lane) & 1:

                assert lane in expected

                src, dst, typ = expected[lane]

                assert lanes[lane] == src

                assert (
                    base[dst] <= lane <
                    base[dst] + caps[dst]
                )

                assert bool(
                    (inhib >> lane) & 1
                ) == (typ == "I")

                recovered.append(
                    (src, dst, typ)
                )

    assert Counter(recovered) == Counter(edges)

    # ==========================================
    # 5. Generate hardware parameters
    # ==========================================

    degrees = [0] * n

    for _, dst, _ in edges:
        degrees[dst] += 1

    max_degree = max(
        256,
        power_of_two(max(1, max(degrees)))
    )

    cw = (max_degree + 1).bit_length()

    cap_bits = sum(
        (c.bit_length() - 1) << (3 * g)
        for g, c in enumerate(caps)
    )

    rule_bits = sum(
        (r.upper() == "MAJ") << g
        for g, r in enumerate(rules)
    )

    degree_bits = sum(
        deg << (cw * g)
        for g, deg in enumerate(degrees)
    )

    # ==========================================
    # 6. Generate 64-bit BRAM write operations
    # ==========================================

    writes = [
        {
            "addr": a,
            "bank": b,
            "data": (
                f"{(word >> (64 * b)) & ((1 << 64) - 1):016x}"
            )
        }
        for a, word in enumerate(words)
        for b in range(banks)
    ]

    return {
        "genes": n,
        "capacities": caps,
        "route_n": route_n,
        "kmax": max(caps),
        "stages": stages,
        "switch_width": switch_w,
        "mem_width": mem_w,
        "banks": banks,
        "depth": depth,
        "substeps": len(words),
        "edge_count": len(edges),
        "cap_log2_verilog": (
            f"{3*n}'h{cap_bits:x}"
        ),
        "rule_verilog": (
            f"{n}'h{rule_bits:x}"
        ),
        "max_degree": max_degree,
        "cw": cw,
        "degree_verilog": (
            f"{n*cw}'h{degree_bits:x}"
        ),
        "writes": writes,
        "verification": (
            "PASS: all routed edges reconstructed"
        )
    }


if __name__ == "__main__":

    ap = argparse.ArgumentParser()

    ap.add_argument("graph")
    ap.add_argument(
        "--min-substeps",
        type=int,
        default=2
    )
    ap.add_argument(
        "--depth",
        type=int,
        default=32
    )
    ap.add_argument(
        "--output",
        default="ferreira_config.json"
    )

    args = ap.parse_args()

    graph = json.loads(
        Path(args.graph).read_text()
    )

    result = compile_graph(
        graph,
        args.min_substeps,
        args.depth
    )

    Path(args.output).write_text(
        json.dumps(result, indent=2)
    )

    print(
        f"PASS: {result['edge_count']} edges "
        f"routed in {result['substeps']} substeps"
    )

    print(
        f"ROUTE_N={result['route_n']} "
        f"KMAX={result['kmax']} "
        f"MEM_W={result['mem_width']} "
        f"BANKS={result['banks']}"
    )

    print(
        "CAP_LOG2 =",
        result["cap_log2_verilog"]
    )

    print("Config:", args.output)
