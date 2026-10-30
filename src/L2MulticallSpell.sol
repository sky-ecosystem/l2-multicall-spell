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

/// @notice Generic L2 spell executing a batch of calls on a remote chain. Deployed once per L2,
///         delegatecalled by L2GovernanceRelay, so each call is made with the relay as `msg.sender`.
/// @dev    `execute` is permissionless, so the spell must never be granted any permission.
contract L2MulticallSpell {

    struct Call {
        address target;
        bytes   data;
    }

    /// @notice Executes `calls` in order, reverting if any of them reverts.
    /// @dev    Reverts after `deadline`, so a failed or delayed message cannot be executed indefinitely.
    ///         Reverts on a target without code, as a call to it would silently succeed.
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
