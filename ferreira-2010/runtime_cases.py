"""Deterministic validation inputs; all graph information stays in data."""
import csv
from pathlib import Path

from grn_frontend import Network, parse_expression, load_network


def ring(n):
    names = [f'G{i}' for i in range(n)]
    return Network(names, [parse_expression(names[(i-1) % n]) for i in range(n)])


def mixed_expressions():
    # Four different feedback components drive a 22-node feed-forward chain.
    # This differs from a single ring in topology, fan-in and update semantics.
    expressions = []
    for base, length in [(0, 5), (5, 7), (12, 9), (21, 11)]:
        expressions += [f'G{base+(i-1) % length}' for i in range(length)]
    for i in range(32, 54):
        a, b, c, d = (7*i) % 32, (11*i+3) % 32, (13*i+9) % 32, (i+17) % 32
        prior = i-1
        expressions.append(
            f'MAJ(G{a},G{b},G{prior})' if i % 3 == 0 else
            f'(G{a}|G{prior})&!G{c}' if i % 3 == 1 else
            f'(G{a}|G{b}|G{prior})&!(G{c}|G{d})')
    return expressions


def mixed54():
    return Network([f'G{i}' for i in range(54)],
                   [parse_expression(s) for s in mixed_expressions()])


def majority64():
    names = [f'G{i}' for i in range(64)]
    return Network(names, [parse_expression('MAJ('+','.join(names)+')')] +
                   [parse_expression(name) for name in names[1:]])


def cases():
    small = Network(list('ABCD'), [parse_expression(s) for s in
                    ['(A|B)&!D', 'MAJ(A,C,D)', 'B', 'D']])
    items = [('small4', small, s) for s in range(16)]
    items += [('ring20', ring(20), (1 << 19) | 1),
              ('ring50', ring(50), 1 << 49),
              ('mixed54', mixed54(), (1 << 53) | (1 << 21) | (1 << 12) | (1 << 5) | 1),
              ('ring54', ring(54), 1 << 53),
              ('ring64', ring(64), 1 << 63),
              ('broadcast64', Network([f'G{i}' for i in range(64)],
                                      [parse_expression('G0')]*64), 1),
              ('constant64', Network([f'G{i}' for i in range(64)],
                                     [parse_expression('0')]*64), (1 << 64)-1),
              ('majority64_full', majority64(), (1 << 64)-1),
              ('majority64_tie', majority64(), ((1 << 64)-1) ^ ((1 << 32)-1)),
              ('majority64_rise', majority64(), (1 << 64)-2),
              ('small4_after_large', small, 9)]
    return items


def file_cases():
    directory = Path(__file__).parent/'examples/runtime'
    result = []
    for name, network, seed in cases():
        base = 'small4' if name.startswith('small4') else name
        if name.startswith('majority64'):
            base = 'majority64'
        suffix = '.csv' if base in ('small4', 'mixed54', 'majority64') else '.bnet'
        result.append((name, load_network(directory/(base+suffix)), seed))
    return result


def write_examples(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory/'small4.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['gene', 'expression'])
        writer.writerows(zip('ABCD', ['(A|B)&!D', 'MAJ(A,C,D)', 'B', 'D']))
    for n in [20, 50, 54, 64]:
        with (directory / f'ring{n}.bnet').open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(['targets', 'factors'])
            writer.writerows((f'G{i}', f'G{(i-1) % n}') for i in range(n))
    expressions = mixed_expressions()
    with (directory / 'mixed54.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['gene', 'expression'])
        writer.writerows((f'G{i}', value) for i, value in enumerate(expressions))
    for name, expression in [('broadcast64', 'G0'), ('constant64', '0')]:
        with (directory/(name+'.bnet')).open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(['targets', 'factors'])
            writer.writerows((f'G{i}', expression) for i in range(64))
    with (directory/'majority64.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['gene', 'expression'])
        writer.writerow(['G0', 'MAJ('+','.join(f'G{i}' for i in range(64))+')'])
        writer.writerows((f'G{i}', f'G{i}') for i in range(1, 64))


if __name__ == '__main__':
    write_examples(Path(__file__).parent / 'examples/runtime')
