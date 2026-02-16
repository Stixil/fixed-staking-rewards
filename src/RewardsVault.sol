// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

contract RewardsVault is AccessControlEnumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    address public stakingContract;
    bool public stakingContractSet;

    event StakingContractSet(address indexed stakingContract);
    event RewardPaid(address indexed user, address indexed token, uint256 amount);
    event EmergencyWithdraw(address indexed token, address indexed recipient, uint256 amount);

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    /// @notice Set the staking contract address (one-time only)
    /// @param _stakingContract The staking contract address
    function setStakingContract(address _stakingContract) external onlyRole(ADMIN_ROLE) {
        require(!stakingContractSet, "Staking contract already set");
        require(_stakingContract != address(0), "Invalid address");
        
        stakingContract = _stakingContract;
        stakingContractSet = true;
        
        emit StakingContractSet(_stakingContract);
    }

    /// @notice Pay reward to user (only callable by staking contract)
    /// @param user The user to pay
    /// @param token The reward token
    /// @param amount The amount to pay
    function payReward(address user, address token, uint256 amount) 
        external 
        onlyStakingContract 
    {
        IERC20(token).safeTransfer(user, amount);
        emit RewardPaid(user, token, amount);
    }

    /// @notice Emergency withdraw tokens from vault
    /// @param token The token to withdraw
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function emergencyWithdraw(address token, address recipient, uint256 amount) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencyWithdraw(token, recipient, amount);
    }

    /// @notice Get token balance in vault
    /// @param token The token address
    /// @return The balance
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    modifier onlyStakingContract() {
        require(msg.sender == stakingContract, "Only staking contract");
        _;
    }

    /// @notice Override supportsInterface for AccessControlEnumerable
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(AccessControlEnumerable) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
}