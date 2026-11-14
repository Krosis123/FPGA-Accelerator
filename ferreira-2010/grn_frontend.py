"""Boolean expression IR, safe parser, and exact lowering to existing AI/MAJ PEs."""
import csv
import re
from dataclasses import dataclass
from pathlib import Path


def parse_expression(source):
    tokens = re.findall(r"[A-Za-z_][A-Za-z_0-9]*|[01]|[!~&|^(),]", source)
    if ''.join(tokens) != re.sub(r"\s+", "", source):
        raise ValueError(f"Invalid Boolean expression: {source!r}")
    pos = 0

    def expr(level=0):
        nonlocal pos
        operators = ('|', '^', '&')
        if level < 3:
            left = expr(level + 1)
            while pos < len(tokens) and tokens[pos] == operators[level]:
                op = tokens[pos]
                pos += 1
                left = (op, left, expr(level + 1))
            return left
        if pos >= len(tokens):
            raise ValueError("Missing Boolean operand")
        token = tokens[pos]
        pos += 1
        if token == 'MAJ' and pos < len(tokens) and tokens[pos] == '(':
            pos += 1
            arguments = [expr()]
            while pos < len(tokens) and tokens[pos] == ',':
                pos += 1
                arguments.append(expr())
            if pos >= len(tokens) or tokens[pos] != ')':
                raise ValueError("Unclosed majority function")
            pos += 1
            return ('maj', *arguments)
        if token in ('!', '~'):
            return ('!', expr(3))
        if token == '(':
            value = expr()
            if pos >= len(tokens) or tokens[pos] != ')':
                raise ValueError("Unclosed parenthesis")
            pos += 1
            return value
        if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*|[01]", token):
            return ('const', int(token)) if token in ('0', '1') else ('var', token)
        raise ValueError(f"Unexpected token {token!r}")

    tree = expr()
    if pos != len(tokens):
        raise ValueError("Trailing expression tokens")
    return tree


def variables(tree):
    if tree[0] == 'var':
        return {tree[1]}
    if tree[0] == 'const':
        return set()
    return set().union(*(variables(t) for t in tree[1:]))


def evaluate(tree, values):
    op = tree[0]
    if op == 'var':
        return bool(values[tree[1]])
    if op == 'const':
        return bool(tree[1])
    if op == '!':
        return not evaluate(tree[1], values)
    if op == 'maj':
        return sum(evaluate(t, values) for t in tree[1:]) > (len(tree) - 1) // 2
    a, b = evaluate(tree[1], values), evaluate(tree[2], values)
    return {'&': a and b, '|': a or b, '^': a != b}[op]


@dataclass
class Network:
    names: list
    expressions: list

    def next_state(self, state):
        values = {name: (state >> i) & 1 for i, name in enumerate(self.names)}
        return sum(int(evaluate(tree, values)) << i
                   for i, tree in enumerate(self.expressions))


def load_network(path):
    """CSV: gene,expression. BNET: targets,factors; first declaration is bit 0."""
    rows = []
    with Path(path).open(encoding='utf-8-sig', newline='') as stream:
        for row in csv.reader(line for line in stream
                              if line.strip() and not line.lstrip().startswith('#')):
            if len(row) != 2:
                raise ValueError("Expected two columns: gene,expression")
            name, expression = (x.strip() for x in row)
            if not rows and (name.lower(), expression.lower()) in (
                    ('gene', 'expression'), ('targets', 'factors')):
                continue
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', name):
                raise ValueError(f"Invalid gene name {name!r}")
            rows.append((name, parse_expression(expression)))
    names = [name for name, _ in rows]
    if not names or len(set(names)) != len(names):
        raise ValueError("Network must have unique gene declarations")
    for name, tree in rows:
        unknown = variables(tree) - set(names)
        if unknown:
            raise ValueError(f"{name}: undeclared genes {sorted(unknown)}")
    return Network(names, [tree for _, tree in rows])


def lower_ai(tree):
    """Recognize (OR activators) AND NOT (OR inhibitors), exactly; no approximation."""
    def flatten(node, op):
        return flatten(node[1], op) + flatten(node[2], op) if node[0] == op else [node]

    activators, inhibitors = [], []
    if tree == ('const', 0):
        return [], []
    for term in flatten(tree, '&'):
        if term[0] == '!':
            leaves = flatten(term[1], '|')
            if any(t[0] != 'var' for t in leaves):
                raise ValueError("Backend requires an OR of inhibitor variables")
            inhibitors.extend(t[1] for t in leaves)
        else:
            leaves = flatten(term, '|')
            if activators or any(t[0] != 'var' for t in leaves):
                raise ValueError("Boolean function unsupported by AI backend")
            activators.extend(t[1] for t in leaves)
    if not activators:
        raise ValueError("Pure NOT/constant-one functions need a different backend")
    return sorted(set(activators)), sorted(set(inhibitors))
