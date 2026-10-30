// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { OptimismBridgeTesting } from "xchain-helpers/testing/bridges/OptimismBridgeTesting.sol";
import { ArbitrumBridgeTesting } from "xchain-helpers/testing/bridges/ArbitrumBridgeTesting.sol";
import { LZBridgeTesting }       from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";

import { LZInit, GovOAppSenderLike }                         from "lz-init-lib/LZInit.sol";
import { L2GovernanceRelay as LZTimelockL2GovernanceRelay } from "lz-governance-relay/src/L2GovernanceRelay.sol";

import { L2MulticallSpell } from "src/L2MulticallSpell.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface L1GovernanceRelayLike {
    function l2GovernanceRelay() external view returns (address);
}

interface L1OptimismGovernanceRelayLike {
    function relay(address target, bytes calldata targetData, uint32 minGasLimit) external;
}

interface L1ArbitrumGovernanceRelayLike {
    function relay(
        address        target,
        bytes calldata targetData,
        uint256        l1CallValue,
        uint256        maxGas,
        uint256        gasPriceBid,
        uint256        maxSubmissionCost
    ) external payable;
}

interface L2GovernanceRelayLike {
    function relay(address target, bytes calldata targetData) external;
}

interface L2MessengerLike {
    function xDomainMessageSender() external view returns (address);
}

contract TargetMock {
    error CustomError(uint256 value);

    mapping(address => uint256) public wards;
    uint256[] public log;

    constructor(address ward) { wards[ward] = 1; }

    modifier auth() {
        require(wards[msg.sender] == 1, "TargetMock/not-authorized");
        _;
    }

    function push(uint256 value) external auth { log.push(value); }
    function failWithReason()    external view auth { revert("TargetMock/failed"); }
    function failWithCustom()    external view auth { revert CustomError(42); }
    function logLength()         external view returns (uint256) { return log.length; }
}

/// @notice Tests for `L2MulticallSpell`: its behaviour behind the Base L2GovernanceRelay, and a
///         message relayed from L1 through each governance relay implementation: Base (also used by
///         Unichain), Optimism, Arbitrum, and LayerZero, current and timelocked (on Avalanche).
/// @dev    Forks are not pinned: the tests only rely on the relays' wiring, and forge's default
///         Arbitrum node does not serve old blocks. The exception is the LayerZero forks, pinned
///         before Avalanche's planned migration stops L1 from relaying to its current relay.
contract L2MulticallSpellTest is Test {

    using DomainHelpers for *;

    ChainlogLike constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    address constant OP_L2_MESSENGER  = 0x4200000000000000000000000000000000000007;
    uint160 constant ARB_ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);
    uint32  constant MIN_GAS_LIMIT    = 1_000_000;

    // LayerZero: Avalanche, behind a non-timelocked relay until its planned migration
    uint32  constant ETH_EID           = 30101;
    uint32  constant AVAX_EID          = 30106;
    address constant AVAX_L2_GOV_RELAY = 0xe928885BCe799Ed933651715608155F01abA23cA; // not resolvable from mainnet
    uint256 constant LZ_MAINNET_BLOCK  = 26304600; // before Avalanche's migration
    uint256 constant LZ_AVAX_BLOCK     = 98942600; // before Avalanche's migration
    uint128 constant LZ_RECEIVE_GAS    = 500_000;
    uint256 constant LZ_MAX_FEE        = 1 ether;
    uint256 constant LZ_TIMELOCK_DELAY = 2 days;
    uint256 constant LZ_TIMELOCK_GRACE = 7 days;

    Domain mainnet;
    Bridge bridge;

    address PAUSE_PROXY;
    address BASE_L1_GOV_RELAY;
    address BASE_L2_GOV_RELAY;
    address LZ_GOV_SENDER;
    address LZ_GOV_RELAY;
    address AVAX_GOV_RECEIVER;

    L2MulticallSpell spell;
    TargetMock       targetA;
    TargetMock       targetB;

    function setUp() public {
        // xchain-helpers reads this variable directly to relay messages, so it cannot fall back to
        // forge's default.
        require(
            bytes(vm.envOr("MAINNET_RPC_URL", string(""))).length > 0,
            "L2MulticallSpellTest/MAINNET_RPC_URL-unset"
        );

        mainnet = getChain("mainnet").createSelectFork();

        PAUSE_PROXY = chainlog.getAddress("MCD_PAUSE_PROXY");
        (BASE_L1_GOV_RELAY, BASE_L2_GOV_RELAY) = _govRelays("BASE_GOV_RELAY");

        getChain("base").createSelectFork();

        spell   = new L2MulticallSpell();
        targetA = new TargetMock(BASE_L2_GOV_RELAY);
        targetB = new TargetMock(BASE_L2_GOV_RELAY);
    }

    // ==================================
    //  Execution
    // ==================================

    function test_executesCallsInOrder() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](3);
        calls[0] = L2MulticallSpell.Call(address(targetA), abi.encodeCall(TargetMock.push, (1)));
        calls[1] = L2MulticallSpell.Call(address(targetB), abi.encodeCall(TargetMock.push, (2)));
        calls[2] = L2MulticallSpell.Call(address(targetA), abi.encodeCall(TargetMock.push, (3)));

        _execute(calls, block.timestamp);

        assertEq(targetA.logLength(), 2);
        assertEq(targetA.log(0), 1);
        assertEq(targetA.log(1), 3);
        assertEq(targetB.logLength(), 1);
        assertEq(targetB.log(0), 2);
    }

    function test_executesAtDeadline() public {
        _execute(_pushCalls(targetA), block.timestamp);

        assertEq(targetA.logLength(), 2);
    }

    // ==================================
    //  Reverts
    // ==================================

    function test_revertsAfterDeadline() public {
        L2MulticallSpell.Call[] memory calls = _pushCalls(targetA);
        uint256 deadline = block.timestamp;

        vm.warp(deadline + 1);
        vm.expectRevert("L2MulticallSpell/deadline-expired");
        _execute(calls, deadline);
    }

    function test_revertsOnTargetWithoutCode() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](1);
        calls[0] = L2MulticallSpell.Call(makeAddr("noCode"), abi.encodeCall(TargetMock.push, (1)));

        vm.expectRevert("L2MulticallSpell/target-without-code");
        _execute(calls, block.timestamp);
    }

    /// @dev An entry left unset in a fixed-size array has a zero target.
    function test_revertsOnUnsetCall() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](2);
        calls[0] = L2MulticallSpell.Call(address(targetA), abi.encodeCall(TargetMock.push, (1)));

        vm.expectRevert("L2MulticallSpell/target-without-code");
        _execute(calls, block.timestamp);
    }

    function test_bubblesRevertReason() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](1);
        calls[0] = L2MulticallSpell.Call(address(targetA), abi.encodeCall(TargetMock.failWithReason, ()));

        vm.expectRevert("TargetMock/failed");
        _execute(calls, block.timestamp);
    }

    function test_bubblesCustomError() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](1);
        calls[0] = L2MulticallSpell.Call(address(targetA), abi.encodeCall(TargetMock.failWithCustom, ()));

        vm.expectRevert(abi.encodeWithSelector(TargetMock.CustomError.selector, 42));
        _execute(calls, block.timestamp);
    }

    /// @dev A call to a function the target does not have reverts without data.
    function test_revertsOnEmptyRevertData() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](1);
        calls[0] = L2MulticallSpell.Call(address(targetA), abi.encodeWithSignature("doesNotExist()"));

        vm.expectRevert("L2MulticallSpell/call-failed");
        _execute(calls, block.timestamp);
    }

    function test_revertsWhenLaterCallFails() public {
        L2MulticallSpell.Call[] memory calls = new L2MulticallSpell.Call[](2);
        calls[0] = L2MulticallSpell.Call(address(targetA), abi.encodeCall(TargetMock.push, (1)));
        calls[1] = L2MulticallSpell.Call(address(targetB), abi.encodeCall(TargetMock.failWithReason, ()));

        vm.expectRevert("TargetMock/failed");
        _execute(calls, block.timestamp);
    }

    /// @dev Called directly rather than delegatecalled by the relay, the spell is the caller.
    function test_directCallHasNoPower() public {
        vm.expectRevert("TargetMock/not-authorized");
        spell.execute(_pushCalls(targetA), block.timestamp);
    }

    // ==================================
    //  Relay from L1
    // ==================================

    function test_relaysToBase() public {
        _checkOptimismRelay("base", "BASE_GOV_RELAY");
    }

    function test_relaysToOptimism() public {
        _checkOptimismRelay("optimism", "OPTIMISM_GOV_RELAY");
    }

    function test_relaysToArbitrum() public {
        (address l1GovRelay, address l2GovRelay) = _govRelays("ARBITRUM_GOV_RELAY");
        bridge = ArbitrumBridgeTesting.createNativeBridge(mainnet, getChain("arbitrum_one").createFork());

        bridge.destination.selectFork();
        L2MulticallSpell l2Spell = new L2MulticallSpell();
        TargetMock target = new TargetMock(l2GovRelay);
        bytes memory data = abi.encodeCall(L2MulticallSpell.execute, (_pushCalls(target), block.timestamp + 1 days));

        _relayArbitrum(l1GovRelay, address(l2Spell), data);

        _assertPushed(target);
    }

    function test_relaysToLZGovernanceRelay() public {
        _createLZBridge();

        bridge.destination.selectFork();
        L2MulticallSpell l2Spell = new L2MulticallSpell();
        TargetMock target = new TargetMock(AVAX_L2_GOV_RELAY);
        bytes memory data = abi.encodeCall(L2MulticallSpell.execute, (_pushCalls(target), block.timestamp + 1 days));

        _relayLZ(AVAX_L2_GOV_RELAY, address(l2Spell), data);

        _assertPushed(target);
    }

    /// @dev A timelocked L2GovernanceRelay (lz-governance-relay `relay-timelock`), deployed behind the
    ///      live Avalanche receiver and whitelisted on L1 as in its planned migration. The relayed action
    ///      is queued, then executed after the delay.
    // TODO: once Avalanche's migration has run, use the live timelocked relay instead of deploying and
    //       whitelisting one, and drop the test against the replaced relay.
    function test_relaysToLZTimelockGovernanceRelay() public {
        _createLZBridge();

        bridge.destination.selectFork();
        LZTimelockL2GovernanceRelay l2GovRelay = new LZTimelockL2GovernanceRelay(
            ETH_EID, AVAX_GOV_RECEIVER, LZ_GOV_RELAY, LZ_TIMELOCK_DELAY, LZ_TIMELOCK_GRACE, new address[](0)
        );
        L2MulticallSpell l2Spell = new L2MulticallSpell();
        TargetMock target = new TargetMock(address(l2GovRelay));
        // The deadline is checked on execution, so it has to cover the relay's delay
        uint256 deadline = block.timestamp + LZ_TIMELOCK_DELAY + 1 days;
        bytes memory data = abi.encodeCall(L2MulticallSpell.execute, (_pushCalls(target), deadline));

        bridge.source.selectFork();
        vm.prank(PAUSE_PROXY);
        GovOAppSenderLike(LZ_GOV_SENDER).setCanCallTarget(
            LZ_GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(address(l2GovRelay)))), true
        );

        _relayLZ(address(l2GovRelay), address(l2Spell), data);
        assertEq(target.logLength(), 0); // only queued

        vm.warp(block.timestamp + LZ_TIMELOCK_DELAY);
        l2GovRelay.exec(0);

        _assertPushed(target);
    }

    // ==================================
    //  Legacy relays: the Optimism and Arbitrum L2GovernanceRelays discard the revert data
    // ==================================

    function test_optimismRelayDiscardsRevertData() public {
        (address l1GovRelay, address l2GovRelay) = _govRelays("OPTIMISM_GOV_RELAY");
        getChain("optimism").createSelectFork();
        L2MulticallSpell l2Spell = new L2MulticallSpell();
        L2MulticallSpell.Call[] memory calls = _pushCalls(new TargetMock(l2GovRelay));
        uint256 deadline = block.timestamp;

        vm.warp(deadline + 1);
        vm.expectRevert("L2GovernanceRelay/delegatecall-error");
        _relayFromL2Messenger(l1GovRelay, l2GovRelay, address(l2Spell), calls, deadline);
    }

    function test_arbitrumRelayDiscardsRevertData() public {
        (address l1GovRelay, address l2GovRelay) = _govRelays("ARBITRUM_GOV_RELAY");
        getChain("arbitrum_one").createSelectFork();
        L2MulticallSpell l2Spell = new L2MulticallSpell();
        L2MulticallSpell.Call[] memory calls = _pushCalls(new TargetMock(l2GovRelay));
        bytes memory data = abi.encodeCall(L2MulticallSpell.execute, (calls, block.timestamp));

        vm.warp(block.timestamp + 1);
        vm.expectRevert("L2GovernanceRelay/delegatecall-error");
        vm.prank(address(uint160(l1GovRelay) + ARB_ALIAS_OFFSET));
        L2GovernanceRelayLike(l2GovRelay).relay(address(l2Spell), data);
    }

    // ==================================
    //  Helpers
    // ==================================

    function _govRelays(bytes32 key) internal returns (address l1GovRelay, address l2GovRelay) {
        mainnet.selectFork();
        l1GovRelay = chainlog.getAddress(key);
        l2GovRelay = L1GovernanceRelayLike(l1GovRelay).l2GovernanceRelay();
    }

    function _pushCalls(TargetMock target) internal pure returns (L2MulticallSpell.Call[] memory calls) {
        calls = new L2MulticallSpell.Call[](2);
        calls[0] = L2MulticallSpell.Call(address(target), abi.encodeCall(TargetMock.push, (1)));
        calls[1] = L2MulticallSpell.Call(address(target), abi.encodeCall(TargetMock.push, (2)));
    }

    function _assertPushed(TargetMock target) internal view {
        assertEq(target.logLength(), 2);
        assertEq(target.log(0), 1);
        assertEq(target.log(1), 2);
    }

    function _execute(L2MulticallSpell.Call[] memory calls, uint256 deadline) internal {
        _relayFromL2Messenger(BASE_L1_GOV_RELAY, BASE_L2_GOV_RELAY, address(spell), calls, deadline);
    }

    /// @dev Calls an OP stack L2GovernanceRelay the way its messenger does on delivery. Unlike a
    ///      bridged message, a failure reverts here instead of being recorded by the messenger.
    function _relayFromL2Messenger(
        address                        l1GovRelay,
        address                        l2GovRelay,
        address                        l2Spell,
        L2MulticallSpell.Call[] memory calls,
        uint256                        deadline
    ) internal {
        vm.mockCall(OP_L2_MESSENGER, abi.encodeCall(L2MessengerLike.xDomainMessageSender, ()), abi.encode(l1GovRelay));
        vm.prank(OP_L2_MESSENGER);
        L2GovernanceRelayLike(l2GovRelay).relay(l2Spell, abi.encodeCall(L2MulticallSpell.execute, (calls, deadline)));
    }

    /// @dev The messenger does not revert on a failed message, so execution is checked on the target.
    function _checkOptimismRelay(string memory chainAlias, bytes32 key) internal {
        (address l1GovRelay, address l2GovRelay) = _govRelays(key);
        bridge = OptimismBridgeTesting.createNativeBridge(mainnet, getChain(chainAlias).createFork());

        bridge.destination.selectFork();
        L2MulticallSpell l2Spell = new L2MulticallSpell();
        TargetMock target = new TargetMock(l2GovRelay);
        bytes memory data = abi.encodeCall(L2MulticallSpell.execute, (_pushCalls(target), block.timestamp + 1 days));

        bridge.source.selectFork();
        vm.prank(PAUSE_PROXY);
        L1OptimismGovernanceRelayLike(l1GovRelay).relay(address(l2Spell), data, MIN_GAS_LIMIT);
        OptimismBridgeTesting.relayMessagesToDestination(bridge, true);

        _assertPushed(target);
    }

    function _relayArbitrum(address l1GovRelay, address l2Spell, bytes memory data) internal {
        bridge.source.selectFork();
        uint256 maxGas            = MIN_GAS_LIMIT;
        uint256 gasPriceBid       = 1 gwei;
        uint256 maxSubmissionCost = 0.01 ether;
        uint256 l1CallValue       = maxSubmissionCost + maxGas * gasPriceBid;
        vm.deal(PAUSE_PROXY, l1CallValue);
        vm.prank(PAUSE_PROXY);
        L1ArbitrumGovernanceRelayLike(l1GovRelay).relay{value: l1CallValue}(
            l2Spell, data, l1CallValue, maxGas, gasPriceBid, maxSubmissionCost
        );
        ArbitrumBridgeTesting.relayMessagesToDestination(bridge, true);
    }

    function _createLZBridge() internal {
        Domain memory source = getChain("mainnet").createSelectFork(LZ_MAINNET_BLOCK);
        LZ_GOV_SENDER     = chainlog.getAddress("LZ_GOV_SENDER");
        LZ_GOV_RELAY      = chainlog.getAddress("LZ_GOV_RELAY");
        AVAX_GOV_RECEIVER = address(uint160(uint256(GovOAppSenderLike(LZ_GOV_SENDER).peers(AVAX_EID))));

        bridge = LZBridgeTesting.createLZBridge(source, getChain("avalanche").createFork(LZ_AVAX_BLOCK));
    }

    function _relayLZ(address l2GovRelay, address l2Spell, bytes memory data) internal {
        bridge.source.selectFork();
        vm.deal(LZ_GOV_RELAY, LZ_MAX_FEE);
        vm.startPrank(PAUSE_PROXY);
        LZInit.relayToL2(AVAX_EID, l2GovRelay, l2Spell, data, LZ_RECEIVE_GAS, LZ_MAX_FEE);
        vm.stopPrank();

        LZBridgeTesting.relayMessagesToDestination(bridge, true, LZ_GOV_SENDER, AVAX_GOV_RECEIVER);
    }
}
