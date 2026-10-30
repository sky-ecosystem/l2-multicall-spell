# L2 Multicall Spell

Generic L2 spell for Sky governance to execute a batch of calls on a remote chain.

`L2MulticallSpell` is deployed once per L2 and delegatecalled by the `L2GovernanceRelay`, so each call is made with the relay as `msg.sender`. The calls are encoded in the L1 spell, so no dedicated L2 spell needs to be deployed.

## Usage

- **`execute(calls, deadline)`** - Executes `calls` in order. Reverts if any of them reverts, if a target has no code, or if executed after `deadline`.

For example, from an L1 spell relaying to Base:

```solidity
L2MulticallSpellLike.Call[] memory calls = new L2MulticallSpellLike.Call[](2);
calls[0] = L2MulticallSpellLike.Call(BEAM_STATE, abi.encodeCall(BeamStateLike.addCBeam, (CBEAM)));
calls[1] = L2MulticallSpellLike.Call(BEAM_STATE, abi.encodeCall(BeamStateLike.setCBeamForRateLimits, (RATE_LIMITS, CBEAM)));

L1GovernanceRelayLike(chainlog.getAddress("BASE_GOV_RELAY")).relay(
    L2_MULTICALL_SPELL,
    abi.encodeCall(L2MulticallSpellLike.execute, (calls, block.timestamp + 7 days)),
    MIN_GAS_LIMIT
);
```

## Assumptions

- `execute` is permissionless, so the spell must never be granted any permission: anyone could use it to make arbitrary calls with that permission.
- `deadline` is checked when the calls are executed on L2, so it should account for any delay before execution.
- Calls sending ETH, and logic depending on return values or on-chain checks between calls, are not supported and require a dedicated L2 spell.

## Build

```bash
git submodule update --init --recursive
forge build
```

## Test

```bash
MAINNET_RPC_URL=<mainnet_rpc> forge test
```

`MAINNET_RPC_URL` must be an archive node, as some tests fork from a pinned block.
