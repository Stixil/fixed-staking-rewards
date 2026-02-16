// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FixedStakingRewards} from "../src/FixedStakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20, IERC20Errors} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {console} from "forge-std/console.sol";

// Import custom errors
import {
    CannotStakeZero,
    NotEnoughRewards,
    RewardsNotAvailableYet,
    CannotWithdrawZero,
    CannotWithdrawStakingToken,
    InvalidPriceFeed,
    NotWhitelisted
} from "../src/FixedStakingRewards.sol";

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockChainlinkAggregator is IChainlinkAggregator {
    uint80 public roundId = 0;
    uint8 public keyDecimals = 0;

    struct Entry {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    mapping(uint256 => Entry) public entries;

    bool public allRoundDataShouldRevert;
    bool public latestRoundDataShouldRevert;

    // Mock setup function
    function setLatestAnswer(int256 answer, uint256 timestamp) external {
        roundId++;
        entries[roundId] = Entry({
            roundId: roundId,
            answer: answer,
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: roundId
        });
    }

    function setLatestAnswerWithRound(int256 answer, uint256 timestamp, uint80 _roundId) external {
        roundId = _roundId;
        entries[roundId] = Entry({
            roundId: roundId,
            answer: answer,
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: roundId
        });
    }

    function setAllRoundDataShouldRevert(bool _shouldRevert) external {
        allRoundDataShouldRevert = _shouldRevert;
    }

    function setLatestRoundDataShouldRevert(bool _shouldRevert) external {
        latestRoundDataShouldRevert = _shouldRevert;
    }

    function setDecimals(uint8 _decimals) external {
        keyDecimals = _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (latestRoundDataShouldRevert) {
            revert("latestRoundData reverted");
        }
        return getRoundData(uint80(latestRound()));
    }

    function latestRound() public view returns (uint256) {
        return roundId;
    }

    function decimals() external view returns (uint8) {
        return keyDecimals;
    }

    function getAnswer(uint256 _roundId) external view returns (int256) {
        Entry memory entry = entries[_roundId];
        return entry.answer;
    }

    function getTimestamp(uint256 _roundId) external view returns (uint256) {
        Entry memory entry = entries[_roundId];
        return entry.updatedAt;
    }

    function getRoundData(uint80 _roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (allRoundDataShouldRevert) {
            revert("getRoundData reverted");
        }

        Entry memory entry = entries[_roundId];
        // Emulate a Chainlink aggregator
        return (entry.roundId, entry.answer, entry.startedAt, entry.updatedAt, entry.answeredInRound);
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}

contract FixedStakingRewardsTest is Test {
    FixedStakingRewards public stakingRewards;
    MockERC20 public rewardsToken;
    MockERC20 public stakingToken;
    MockERC20 public otherToken;
    MockChainlinkAggregator public mockAggregator;

    address public owner;
    address public user1;
    address public user2;

    uint256 public constant INITIAL_REWARDS_SUPPLY = 10000e18;
    uint256 public constant INITIAL_STAKING_SUPPLY = 10000e18;
    uint256 public constant REWARDS_DURATION = 86400 * 14; // 14 days

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        vm.warp(1000000000);

        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy tokens
        rewardsToken = new MockERC20("RewardsToken", "RT", INITIAL_REWARDS_SUPPLY);
        stakingToken = new MockERC20("StakingToken", "ST", INITIAL_STAKING_SUPPLY);
        otherToken = new MockERC20("OtherToken", "OT", 1000e18);

        // Deploy mock aggregator
        mockAggregator = new MockChainlinkAggregator();

        // assuming a 50c reward token rate
        mockAggregator.setDecimals(8);
        mockAggregator.setLatestAnswer(1e8 / 2, block.timestamp);

        // Deploy staking contract
        stakingRewards =
            new FixedStakingRewards(owner, address(rewardsToken), address(stakingToken), address(mockAggregator));

        // setup token allowances so we dont have to do it later
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        rewardsToken.approve(address(stakingRewards), type(uint256).max);

        // Setup initial token distributions
        stakingToken.transfer(user1, 1000e18);
        stakingToken.transfer(user2, 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(stakingRewards.rewardsToken()), address(rewardsToken));
        assertEq(address(stakingRewards.stakingToken()), address(stakingToken));
        assertEq(stakingRewards.owner(), owner);
        assertEq(stakingRewards.rewardRate(), 0);
        assertEq(stakingRewards.name(), "FixedStakingRewards");
        assertEq(stakingRewards.symbol(), "FSR");

        // Check rewardsAvailableDate is set to 1 year from deployment
        assertEq(stakingRewards.rewardsAvailableDate(), block.timestamp + 86400 * 365);
    }

    function test_Constructor_WithDifferentOwner() public {
        address newOwner = makeAddr("newOwner");
        FixedStakingRewards newStaking =
            new FixedStakingRewards(newOwner, address(rewardsToken), address(stakingToken), address(mockAggregator));

        assertEq(newStaking.owner(), newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RewardPerToken_WithZeroTotalSupply() public view {
        uint256 result = stakingRewards.rewardPerToken();
        assertEq(result, 0);
    }

    function test_RewardPerToken_WithNonZeroTotalSupply() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600); // 1 hour

        uint256 result = stakingRewards.rewardPerToken();
        uint256 expected = 100 * 3600 * (1e18 * 2 / uint256(365 days)) * 1e18 / 100e18; // timeElapsed * rewardRate * 1e18 / totalSupply
        assertEq(result, expected);
    }

    function test_Earned_WithoutStaking() public view {
        uint256 result = stakingRewards.earned(user1);
        assertEq(result, 0);
    }

    function test_Earned_WithStaking() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600); // 1 hour

        uint256 result = stakingRewards.earned(user1);
        uint256 expected = 100 * 3600 * (1e18 * 2 / uint256(365 days)); // 100 tokens * 1 hour * 1 token per second / 0.5 token rate
        assertEq(result, expected);
    }

    function test_GetRewardForDuration_ReturnsCorrectValue() public {
        stakingRewards.setRewardYieldForYear(1e18);
        uint256 result = stakingRewards.getRewardForDuration();
        uint256 expected = (1e18 * 2 / uint256(365 days)) * (86400 * 14); // Should use rewardsDuration instead
        assertEq(result, expected);
    }

    /*//////////////////////////////////////////////////////////////
                             STAKING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Stake_Success() public {
        uint256 amount = 100e18;

        // Set up rewards so staking is allowed
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), amount);

        vm.expectEmit(true, true, false, true);
        emit Staked(user1, amount);

        stakingRewards.stake(amount);

        assertEq(stakingRewards.balanceOf(user1), amount);
        assertEq(stakingRewards.totalSupply(), amount);
        assertEq(stakingToken.balanceOf(address(stakingRewards)), amount);
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_AmountIsZero() public {
        // Add user to whitelist first
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 0);

        vm.expectRevert(abi.encodeWithSelector(CannotStakeZero.selector));
        stakingRewards.stake(0);
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_InsufficientRewards() public {
        // Add user to whitelist first
        stakingRewards.addToWhitelist(user1);

        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1e18);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);

        uint256 available = 1e18;
        // rounding makes it hard so just put the value directly
        uint256 required = 7671232876648320000;

        vm.expectRevert(abi.encodeWithSelector(NotEnoughRewards.selector, available, required));
        stakingRewards.stake(100e18);
        vm.stopPrank();
    }

    function test_Stake_UpdatesRewards() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // First stake
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        // Second stake should update rewards
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);

        uint256 rewards = stakingRewards.rewards(user1);
        assertGt(rewards, 0);
        vm.stopPrank();
    }

    function test_Stake_TransferShareTokens_UpdatesRewards() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        uint256 rewardsPerHour = 2 * 100e18 * 3600 / uint256(365 days);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        uint256 user1Rewards = stakingRewards.earned(user1);
        assertApproxEqAbs(user1Rewards, rewardsPerHour, 1000000, "first hour rewards");

        // User transfers share tokens to user2
        vm.startPrank(user1);
        stakingRewards.transfer(user2, 50e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        // Both user1 and user2 should be able to receive their corresponding rewards
        user1Rewards = stakingRewards.earned(user1);
        uint256 user2Rewards = stakingRewards.earned(user2);
        assertApproxEqAbs(user1Rewards, rewardsPerHour + rewardsPerHour / 2, 1000000, "second hour rewards user1");
        // half of the rewards because user2 only has half the shares for half of the time
        assertApproxEqAbs(user2Rewards, rewardsPerHour / 2, 1000000, "second hour rewards user2");
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_RevertWhen_BeforeRewardsAvailableDate() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(2000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsNotAvailableYet.selector, block.timestamp, stakingRewards.rewardsAvailableDate()
            )
        );
        stakingRewards.withdraw(50e18);
        vm.stopPrank();
    }

    function test_Withdraw_RevertWhen_AmountIsZero() public {
        // Release rewards and add user to whitelist first
        stakingRewards.releaseRewards();
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(CannotWithdrawZero.selector));
        stakingRewards.withdraw(0);
        vm.stopPrank();
    }

    function test_Withdraw_Success() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(2000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Release rewards
        stakingRewards.releaseRewards();

        uint256 withdrawAmount = 50e18;
        uint256 initialBalance = stakingToken.balanceOf(user1);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(user1, withdrawAmount);

        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.balanceOf(user1), 50e18);
        assertEq(stakingRewards.totalSupply(), 50e18);
        assertEq(stakingToken.balanceOf(user1), initialBalance + withdrawAmount);
        vm.stopPrank();
    }

    function test_Withdraw_SuccessWhenRebalanceFails() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(2000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Release rewards
        stakingRewards.releaseRewards();

        uint256 withdrawAmount = 50e18;
        uint256 initialBalance = stakingToken.balanceOf(user1);

        mockAggregator.setLatestRoundDataShouldRevert(true);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(user1, withdrawAmount);

        stakingRewards.withdraw(withdrawAmount);

        vm.expectRevert("latestRoundData reverted");
        stakingRewards.rebalance();
    }

    function test_Withdraw_RevertWhen_InsufficientBalance() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(2000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Release rewards
        stakingRewards.releaseRewards();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 100e18, 200e18));
        stakingRewards.withdraw(200e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             REWARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetReward_RevertWhen_BeforeRewardsAvailableDate() public {
        // Add user to whitelist first
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsNotAvailableYet.selector, block.timestamp, stakingRewards.rewardsAvailableDate()
            )
        );
        stakingRewards.getReward();
        vm.stopPrank();
    }

    function test_GetReward_WithNoRewards() public {
        // Release rewards and add user to whitelist
        stakingRewards.releaseRewards();
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingRewards.getReward(); // Should not revert, just do nothing
        vm.stopPrank();
    }

    function test_GetReward_Success() public {
        // Set up staking and rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward to accumulate rewards
        skip(3600);

        // Release rewards
        stakingRewards.releaseRewards();

        uint256 expectedReward = stakingRewards.earned(user1);
        uint256 initialBalance = rewardsToken.balanceOf(user1);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(user1, expectedReward);

        stakingRewards.getReward();

        assertEq(stakingRewards.rewards(user1), 0);
        assertEq(rewardsToken.balanceOf(user1), initialBalance + expectedReward);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             EXIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Exit_Success() public {
        // Set up staking and rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward to accumulate rewards
        skip(3600);

        // Release rewards
        stakingRewards.releaseRewards();

        uint256 expectedReward = stakingRewards.earned(user1);
        uint256 stakedAmount = stakingRewards.balanceOf(user1);
        uint256 initialStakingBalance = stakingToken.balanceOf(user1);
        uint256 initialRewardsBalance = rewardsToken.balanceOf(user1);

        vm.startPrank(user1);
        stakingRewards.exit();

        assertEq(stakingRewards.balanceOf(user1), 0);
        assertEq(stakingRewards.rewards(user1), 0);
        assertEq(stakingToken.balanceOf(user1), initialStakingBalance + stakedAmount);
        assertEq(rewardsToken.balanceOf(user1), initialRewardsBalance + expectedReward);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReleaseRewards_Success() public {
        uint256 oldDate = stakingRewards.rewardsAvailableDate();

        stakingRewards.releaseRewards();

        assertEq(stakingRewards.rewardsAvailableDate(), block.timestamp);
        assertLt(stakingRewards.rewardsAvailableDate(), oldDate);
    }

    function test_ReleaseRewards_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.releaseRewards();
        vm.stopPrank();
    }

    function test_SetRewardRate_Success() public {
        uint256 newRate = 5e18;

        stakingRewards.setRewardYieldForYear(newRate);

        assertEq(stakingRewards.rewardRate(), newRate * 2 / 365 days);
    }

    function test_SetRewardRate_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.setRewardYieldForYear(5e18);
        vm.stopPrank();
    }

    function test_SetRewardYieldForYear_ChangeAfterUserDeposit() public {
        // Set initial reward rate and supply rewards
        stakingRewards.setRewardYieldForYear(1e18); // 1 token per year
        stakingRewards.supplyRewards(5000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 300e18);
        stakingRewards.stake(300e18);
        vm.stopPrank();

        // Move time forward by 1 hour (should earn at 1e18/year rate)
        skip(3600); // 1 hour

        // Calculate expected rewards at old rate
        uint256 expectedRewardsOldRate = 300 * 3600 * (1e18 * 2 / uint256(365 days));
        uint256 earnedAfterFirstHour = stakingRewards.earned(user1);
        assertEq(earnedAfterFirstHour, expectedRewardsOldRate);

        // Change reward rate to 2 tokens per year
        stakingRewards.setRewardYieldForYear(2e18);

        // Verify rate changed
        assertEq(stakingRewards.rewardRate(), 2e18 * 2 / uint256(365 days));

        // Move time forward by another hour (should earn at 2e18/year rate)
        skip(3600); // Another hour

        // Calculate total expected rewards: 1 hour at old rate + 1 hour at new rate
        uint256 expectedRewardsNewRate = 300 * 3600 * (2e18 * 2 / uint256(365 days));
        uint256 totalExpectedRewards = expectedRewardsOldRate + expectedRewardsNewRate;

        uint256 earnedAfterRateChange = stakingRewards.earned(user1);
        assertEq(earnedAfterRateChange, totalExpectedRewards);

        // stake again to make sure rewards are preserved
        mockAggregator.setLatestAnswer(1e8 / 2, block.timestamp);
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 200e18);
        stakingRewards.stake(200e18);
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(user1), 500e18);

        // Verify rewards are preserved when rate changes by checking stored rewards
        // The updateReward modifier should have stored the accumulated rewards
        uint256 storedRewards = stakingRewards.rewards(user1);
        assertEq(storedRewards, totalExpectedRewards);
        uint256 earnedAfterFirstStake = stakingRewards.earned(user1);
        assertEq(earnedAfterFirstStake, totalExpectedRewards);

        // move time forward to make sure rewards are still preserved
        skip(3600);

        // verify rewards are still preserved
        expectedRewardsNewRate = 500 * 3600 * (2e18 * 2 / uint256(365 days));
        totalExpectedRewards += expectedRewardsNewRate;

        uint256 earnedAfterSecondStake = stakingRewards.earned(user1);
        assertEq(earnedAfterSecondStake, totalExpectedRewards);
    }

    function test_SupplyRewards_Success() public {
        stakingRewards.setRewardYieldForYear(1e18);

        vm.expectEmit(true, false, false, true);
        emit RewardAdded(1000e18);

        stakingRewards.supplyRewards(1000e18);

        assertEq(stakingRewards.lastUpdateTime(), block.timestamp);
    }

    function test_SupplyRewards_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.supplyRewards(1000e18);
        vm.stopPrank();
    }

    function test_RecoverERC20_Success() public {
        uint256 amount = 100e18;
        otherToken.transfer(address(stakingRewards), amount);

        uint256 initialBalance = otherToken.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit Recovered(address(otherToken), amount);

        stakingRewards.recoverERC20(address(otherToken), amount);

        assertEq(otherToken.balanceOf(owner), initialBalance + amount);
    }

    function test_RecoverERC20_RevertWhen_StakingToken() public {
        vm.expectRevert(abi.encodeWithSelector(CannotWithdrawStakingToken.selector, address(stakingToken)));
        stakingRewards.recoverERC20(address(stakingToken), 100e18);
    }

    function test_RecoverERC20_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.recoverERC20(address(otherToken), 100e18);
        vm.stopPrank();
    }

    function test_Reclaim_Success() public {
        uint256 amount = 1000e18;
        stakingRewards.supplyRewards(amount);
        uint256 initialBalance = rewardsToken.balanceOf(owner);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        mockAggregator.setLatestAnswer(1e8, block.timestamp);
        stakingRewards.reclaim();

        assertEq(rewardsToken.balanceOf(owner), initialBalance + amount);
        assertEq(rewardsToken.balanceOf(address(stakingRewards)), 0);

        // deposited users can still pull their original staked tokens
        vm.startPrank(user1);
        stakingRewards.exit();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        assertEq(stakingToken.balanceOf(user1), 1000e18);
        assertEq(rewardsToken.balanceOf(user1), 0);
    }

    function test_Reclaim_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.reclaim();
        vm.stopPrank();
    }

    function test_Rebalance_Success() public {
        // Set target APY to 1 token per year
        uint256 targetApy = 1e18;
        stakingRewards.setRewardYieldForYear(targetApy);

        // Verify initial state - aggregator is set to 0.5 (1e18 / 2) in setUp
        int256 initialRate = 1e18 / 2; // 0.5 tokens per USD
        uint256 expectedRewardRate = targetApy * 1e18 / uint256(initialRate) / 365 days;
        assertEq(stakingRewards.rewardRate(), expectedRewardRate);

        // Change aggregator rate to 0.25 (token price doubled)
        mockAggregator.setLatestAnswer(1e8 / 4, block.timestamp);

        // Call rebalance
        stakingRewards.rebalance();

        // Verify reward rate updated correctly
        uint256 newExpectedRewardRate = targetApy * 1e18 / uint256(1e18 / 4) / 365 days;
        assertEq(stakingRewards.rewardRate(), newExpectedRewardRate);

        // New rate should be double the original (since token price halved)
        assertApproxEqAbs(stakingRewards.rewardRate(), expectedRewardRate * 2, 10);
    }

    function test_Rebalance_UpdatesRewards() public {
        // Set up staking scenario
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward to accumulate rewards
        skip(3600); // 1 hour

        uint256 earnedBefore = stakingRewards.earned(user1);
        assertGt(earnedBefore, 0);

        // Change the aggregator rate and rebalance
        mockAggregator.setLatestAnswer(1e8, block.timestamp); // Rate changes from 0.5 to 1.0
        stakingRewards.rebalance();

        // Rewards should be preserved due to updateReward modifier
        uint256 earnedAfter = stakingRewards.earned(user1);
        assertEq(earnedAfter, earnedBefore);
    }

    function test_Rebalance_WithZeroTargetApy() public {
        // Set target APY to 0
        stakingRewards.setRewardYieldForYear(0);

        // Change aggregator rate
        mockAggregator.setLatestAnswer(1e8, block.timestamp);

        // Rebalance should result in 0 reward rate
        stakingRewards.rebalance();
        assertEq(stakingRewards.rewardRate(), 0);
    }

    function test_Rebalance_RevertWhen_PriceFeedReturnsZero() public {
        // Set target APY
        stakingRewards.setRewardYieldForYear(1e18);

        // Set aggregator to return zero rate
        mockAggregator.setLatestAnswer(0, block.timestamp);

        // Rebalance should revert with InvalidPriceFeed
        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, block.timestamp, int256(0)));
        stakingRewards.rebalance();
    }

    function test_Rebalance_RevertWhen_PriceFeedIsStale() public {
        // Set target APY
        stakingRewards.setRewardYieldForYear(1e18);

        // Set aggregator with stale data (2 days old)
        uint256 staleTimestamp = block.timestamp - 2 days;
        mockAggregator.setLatestAnswer(1e8 / 2, staleTimestamp);

        // Rebalance should revert with InvalidPriceFeed
        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, staleTimestamp, int256(1e8 / 2)));
        stakingRewards.rebalance();
    }

    function test_Rebalance_RevertWhen_PriceFeedIsStaleExactly1Day1Hour() public {
        // Set target APY
        stakingRewards.setRewardYieldForYear(1e18);

        // Set aggregator with data exactly 1 day + 1 hour old (should still revert)
        uint256 staleTimestamp = block.timestamp - 1 days - 1 hours - 1;
        mockAggregator.setLatestAnswer(1e8 / 2, staleTimestamp);

        // Rebalance should revert with InvalidPriceFeed
        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, staleTimestamp, int256(1e8 / 2)));
        stakingRewards.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                             MODIFIER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateReward_WithZeroAddress() public {
        stakingRewards.setRewardYieldForYear(1e18);

        // This should work without reverting
        stakingRewards.supplyRewards(1000e18);
    }

    function test_UpdateReward_WithValidAddress() public {
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        rewardsToken.transfer(address(stakingRewards), 2000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        // Another action should update rewards
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);

        assertGt(stakingRewards.rewards(user1), 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Stake_ValidAmounts(uint96 amount) public {
        // Bound to reasonable values
        amount = uint96(bound(amount, 1, 1000e18));

        // Setup rewards
        stakingRewards.setRewardYieldForYear(1e18);
        rewardsToken.transfer(address(stakingRewards), 10000e18);

        // Give user enough tokens
        stakingToken.mint(user1, amount);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);

        assertEq(stakingRewards.balanceOf(user1), amount);
        vm.stopPrank();
    }

    function testFuzz_Withdraw_ValidAmounts(uint96 stakeAmount, uint96 withdrawAmount) public {
        // Bound to reasonable values
        stakeAmount = uint96(bound(stakeAmount, 1, 1000e18));
        withdrawAmount = uint96(bound(withdrawAmount, 1, stakeAmount));

        // Setup rewards and staking
        stakingRewards.setRewardYieldForYear(1e18);
        rewardsToken.transfer(address(stakingRewards), 10000e18);
        stakingToken.mint(user1, stakeAmount);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), stakeAmount);
        stakingRewards.stake(stakeAmount);
        vm.stopPrank();

        // Release rewards
        stakingRewards.releaseRewards();

        vm.startPrank(user1);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.balanceOf(user1), stakeAmount - withdrawAmount);
        vm.stopPrank();
    }

    function testFuzz_RewardRate_ValidRates(uint96 rate) public {
        // Bound to reasonable values (not too high to avoid overflow)
        rate = uint96(bound(rate, 1, 1000e18));

        stakingRewards.setRewardYieldForYear(rate);

        assertEq(stakingRewards.rewardRate(), rate * 2 / 365 days);
    }

    /*//////////////////////////////////////////////////////////////
                             INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CompleteFlow() public {
        // 1. Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        rewardsToken.transfer(address(stakingRewards), 5000e18);

        // 2. Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // 3. User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // 4. Time passes
        skip(3600);

        // 5. Check earned rewards
        uint256 earned = stakingRewards.earned(user1);
        assertEq(earned, 100 * 3600 * (1e18 * 2 / uint256(365 days)));

        // 6. Release rewards
        stakingRewards.releaseRewards();

        // 7. User exits
        vm.startPrank(user1);
        stakingRewards.exit();
        vm.stopPrank();

        // 8. Verify final state
        assertEq(stakingRewards.balanceOf(user1), 0);
        assertEq(stakingRewards.rewards(user1), 0);
        assertEq(rewardsToken.balanceOf(user1), earned);
    }

    function test_Integration_MultipleUsers() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(2e18);
        stakingRewards.supplyRewards(1000e18);

        // Add users to whitelist
        stakingRewards.addToWhitelist(user1);
        stakingRewards.addToWhitelist(user2);

        // User1 stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Time passes
        skip(1800); // 30 minutes

        // User2 stakes
        vm.startPrank(user2);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // More time passes
        skip(1800); // Another 30 minutes

        // Check rewards
        uint256 user1Earned = stakingRewards.earned(user1);
        uint256 user2Earned = stakingRewards.earned(user2);

        // User1 should have more rewards (staked earlier)
        assertGt(user1Earned, user2Earned);

        // Total rewards should be reasonable
        assertApproxEqAbs(user1Earned + user2Earned, 100 * 3600 * 2e18 / uint256(365 days), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                             WHITELIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Whitelist_InitialState() public view {
        // Initially no addresses should be whitelisted
        assertFalse(stakingRewards.isWhitelisted(user1));
        assertFalse(stakingRewards.isWhitelisted(user2));
        assertFalse(stakingRewards.isWhitelisted(owner));
    }

    function test_AddToWhitelist_Success() public {
        vm.expectEmit(true, false, false, true);
        emit WhitelistAdded(user1);

        stakingRewards.addToWhitelist(user1);

        assertTrue(stakingRewards.isWhitelisted(user1));
        assertFalse(stakingRewards.isWhitelisted(user2));
    }

    function test_AddToWhitelist_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.addToWhitelist(user2);
        vm.stopPrank();
    }

    function test_RemoveFromWhitelist_Success() public {
        // First add to whitelist
        stakingRewards.addToWhitelist(user1);
        assertTrue(stakingRewards.isWhitelisted(user1));

        vm.expectEmit(true, false, false, true);
        emit WhitelistRemoved(user1);

        stakingRewards.removeFromWhitelist(user1);

        assertFalse(stakingRewards.isWhitelisted(user1));
    }

    function test_RemoveFromWhitelist_RevertWhen_NotOwner() public {
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.removeFromWhitelist(user1);
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_NotWhitelisted() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);

        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.stake(100e18);
        vm.stopPrank();
    }

    function test_Stake_SuccessWhen_Whitelisted() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);

        vm.expectEmit(true, true, false, true);
        emit Staked(user1, 100e18);

        stakingRewards.stake(100e18);

        assertEq(stakingRewards.balanceOf(user1), 100e18);
        vm.stopPrank();
    }

    function test_Stake_OnlyWhitelistedUsersCanStake() public {
        // Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // Add only user1 to whitelist
        stakingRewards.addToWhitelist(user1);

        // user1 can stake
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // user2 cannot stake
        vm.startPrank(user2);
        stakingToken.approve(address(stakingRewards), 100e18);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user2));
        stakingRewards.stake(100e18);
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(user1), 100e18);
        assertEq(stakingRewards.balanceOf(user2), 0);
    }

    function test_WithdrawAndGetReward_WorkAfterWhitelistRemoval() public {
        // Set up rewards and whitelist user
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward and release rewards
        skip(3600);
        stakingRewards.releaseRewards();

        // User should be able to withdraw and get rewards while still whitelisted
        vm.startPrank(user1);
        stakingRewards.withdraw(50e18);
        stakingRewards.getReward();
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(user1), 50e18);
        assertGt(rewardsToken.balanceOf(user1), 0);
    }

    function test_Withdraw_RevertWhen_NotWhitelisted() public {
        // Set up staking first (user needs to be whitelisted to stake)
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(2000e18);
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Remove user from whitelist and release rewards
        stakingRewards.removeFromWhitelist(user1);
        stakingRewards.releaseRewards();

        // User should not be able to withdraw after being removed from whitelist
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.withdraw(50e18);
        vm.stopPrank();
    }

    function test_GetReward_RevertWhen_NotWhitelisted() public {
        // Set up staking and rewards first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward and release rewards
        skip(3600);
        stakingRewards.releaseRewards();

        // Remove user from whitelist
        stakingRewards.removeFromWhitelist(user1);

        // User should not be able to get rewards after being removed from whitelist
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.getReward();
        vm.stopPrank();
    }

    function test_Exit_RevertWhen_NotWhitelisted() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Release rewards and remove from whitelist
        stakingRewards.releaseRewards();
        stakingRewards.removeFromWhitelist(user1);

        // User should not be able to exit after being removed from whitelist
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.exit();
        vm.stopPrank();
    }

    function test_Integration_WhitelistFlow() public {
        // 1. Set up rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);

        // 2. Add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // 3. User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // 4. Remove user from whitelist
        stakingRewards.removeFromWhitelist(user1);

        // 5. User cannot stake more
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // 6. Re-add user to whitelist
        stakingRewards.addToWhitelist(user1);

        // 7. User can stake again
        vm.startPrank(user1);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(user1), 200e18);
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_InitialState() public view {
        // Contract should not be paused initially
        assertFalse(stakingRewards.paused());
    }

    function test_Pause_Success() public {
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);

        stakingRewards.pause();

        assertTrue(stakingRewards.paused());
    }

    function test_Pause_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.pause();
        vm.stopPrank();
    }

    function test_Unpause_Success() public {
        // First pause
        stakingRewards.pause();
        assertTrue(stakingRewards.paused());

        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);

        stakingRewards.unpause();

        assertFalse(stakingRewards.paused());
    }

    function test_Unpause_RevertWhen_NotOwner() public {
        stakingRewards.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        stakingRewards.unpause();
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_Paused() public {
        // Set up rewards and whitelist
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        // Pause the contract
        stakingRewards.pause();

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        stakingRewards.stake(100e18);
        vm.stopPrank();
    }

    function test_Withdraw_RevertWhen_Paused() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(2000e18);
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Release rewards and pause
        stakingRewards.releaseRewards();
        stakingRewards.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        stakingRewards.withdraw(50e18);
        vm.stopPrank();
    }

    function test_GetReward_RevertWhen_Paused() public {
        // Set up staking and rewards
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Move time forward and release rewards
        skip(3600);
        stakingRewards.releaseRewards();

        // Pause the contract
        stakingRewards.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        stakingRewards.getReward();
        vm.stopPrank();
    }

    function test_Exit_RevertWhen_Paused() public {
        // Set up staking first
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // Release rewards and pause
        stakingRewards.releaseRewards();
        stakingRewards.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        stakingRewards.exit();
        vm.stopPrank();
    }

    function test_OwnerFunctions_WorkWhen_Paused() public {
        // Owner functions should still work when paused
        stakingRewards.pause();

        // These should all work
        stakingRewards.addToWhitelist(user1);
        stakingRewards.removeFromWhitelist(user1);
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(100e18);
        stakingRewards.releaseRewards();

        assertTrue(stakingRewards.paused());
    }

    function test_Integration_PauseUnpauseFlow() public {
        // 1. Set up rewards and whitelist
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(1000e18);
        stakingRewards.addToWhitelist(user1);

        // 2. User stakes successfully
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // 3. Pause contract
        stakingRewards.pause();

        // 4. User cannot stake more
        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), 100e18);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        stakingRewards.stake(100e18);
        vm.stopPrank();

        // 5. Unpause contract
        stakingRewards.unpause();

        // 6. User can stake again
        vm.startPrank(user1);
        stakingRewards.stake(100e18);
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(user1), 200e18);
        assertFalse(stakingRewards.paused());
    }
}
