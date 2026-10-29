// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

/**
 * @title  L2MulticallSpell
 * @notice A generic, reusable L2 spell. Deployed once per L2 and delegatecalled by the
 *         L2GovernanceRelay, so every target sees the relay (its ward/admin) as the caller.
 *         The L1 spell encodes the full list of calls, in order, and relays it in one message.
 * @dev    Calling this contract directly (not via delegatecall) is harmless: it holds no
 *         permissions anywhere, and must never be granted any.
 *         Out of scope by design: calls that send ETH, delegatecalls, and logic that depends on
 *         return values or on-chain checks between calls. Those still need a bespoke L2 spell.
 */
contract L2MulticallSpell {

    struct Call {
        address target;
        bytes   data;
    }

    /**
     * @notice Executes `calls` in order. Reverts, undoing all of them, if any call reverts.
     * @dev    Reverts if executed after `deadline`, so a message that failed or was delayed, and
     *         may no longer be desirable, cannot be replayed indefinitely.
     *         Targets without code are rejected, since a call to them would silently succeed
     *         (e.g. a wrong address for the current chain).
     * @param  calls    Calls to execute, in order.
     * @param  deadline Latest destination chain timestamp (inclusive) at which the spell can be
     *                  executed.
     */
    function execute(Call[] calldata calls, uint256 deadline) external {
        require(block.timestamp <= deadline, "L2MulticallSpell/deadline-expired");

        for (uint256 i; i < calls.length; ++i) {
            address target = calls[i].target;
            require(target.code.length > 0, "L2MulticallSpell/target-without-code");

            (bool success, bytes memory result) = target.call(calls[i].data);
            if (!success) {
                if (result.length == 0) revert("L2MulticallSpell/call-failed");
                assembly ("memory-safe") {
                    revert(add(32, result), mload(result))
                }
            }
        }
    }
}
