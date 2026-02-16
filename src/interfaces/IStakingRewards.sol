// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// https://docs.synthetix.io/contracts/source/interfaces/istakingrewards
interface IStakingRewards {
    // Views

    function earned(address account) external view returns (uint256);

    function getRewardForDuration() external view returns (uint256);

    function rewardPerToken() external view returns (uint256);

    function rewardsToken() external view returns (IERC20);

    // Mutative

    function exit() external;

    function getReward() external;

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;
}
