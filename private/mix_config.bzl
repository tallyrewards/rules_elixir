"""Only application consumers transition MIX_ENV; tools stay in exec config."""

def _test_impl(_settings, _attr):
    return {"//:mix_env": "test"}

def _prod_impl(_settings, _attr):
    return {"//:mix_env": "prod"}

test_transition = transition(implementation = _test_impl, inputs = [], outputs = ["//:mix_env"])
prod_transition = transition(implementation = _prod_impl, inputs = [], outputs = ["//:mix_env"])
