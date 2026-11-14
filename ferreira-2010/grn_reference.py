"""Independent visited-state attractor oracle; never uses routing or Floyd RTL."""


def attractor(network, seed, max_states=1000000):
    seen, trajectory = {}, []
    state = seed

    while state not in seen:
        if len(trajectory) >= max_states:
            raise ValueError(f"CPU reference state budget exceeded ({max_states})")
        seen[state] = len(trajectory)
        trajectory.append(state)
        state = network.next_state(state)

    mu = seen[state]
    return {'transient': mu, 'period': len(trajectory) - mu,
            'entry_state': state, 'cycle_states': trajectory[mu:]}
