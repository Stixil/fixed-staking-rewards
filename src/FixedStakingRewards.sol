// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Inheritance
import "./interfaces/IStakingRewards.sol";

/* ========== CUSTOM ERRORS ========== */

error CannotStakeZero(string reason);
error NotEnoughRewards(uint256 available, uint256 required);
error RewardsNotAvailableYet(uint256 currentTime, uint256 availableTime);
error CannotWithdrawZero(string reason);
error CannotWithdrawStakingToken(address attemptedToken);
error IsBlacklisted(address account, string reason);
error LockDurationTooShort(uint256 provided, uint256 minimum);
error DepositStillLocked(uint256 currentTime, uint256 unlockTime);
error InsufficientUnlockedBalance(uint256 requested, uint256 available);
error InvalidStakeId(uint256 stakeId);

contract FixedStakingRewards is IStakingRewards, ERC20Pausable, ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    /* ========== ROLES ========== */

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /* ========== STRUCTS ========== */

    /// @notice Individual stake position
    struct StakePosition {
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable rewardsToken;
    IERC20 public immutable stakingToken;
    uint256 public rewardRate = 0; // Rewards distributed per second
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardsAvailableDate;
    uint256 public claimFee; // Fee percentage (e.g., 5 for 0.5%)
    uint256 public minimumLockDuration; // Configurable minimum lock duration

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public blacklist;
    mapping(address => uint256) public userStaked; // Total staked by user
    mapping(address => uint256) public lastStakeTime;
    
    // Track individual stake positions
    mapping(address => StakePosition[]) public userStakePositions;
    mapping(address => uint256) public userStakeCount;

    /* ========== CONSTRUCTOR ========== */

    /// @notice Initializes the staking contract with token addresses
    /// @param _admin The address that will have admin role
    /// @param _rewardsToken The token used for rewards
    /// @param _stakingToken The token users will stake
    constructor(address _admin, address _rewardsToken, address _stakingToken)
        ERC20("RewardsStakedAVI", "stAVI")
    {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsAvailableDate = block.timestamp + 86400 * 365;
        minimumLockDuration = 12 weeks; // Default to 12 weeks
        lastUpdateTime = block.timestamp; // Initialize to deployment time
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    /* ========== VIEWS ========== */

    /// @notice Calculates the current reward per token staked
    /// @return The reward per token value
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (block.timestamp - lastUpdateTime) * rewardRate;
    }

    /// @notice Returns the total rewards earned by an account
    /// @param account The address to check rewards for
    /// @return The amount of rewards earned
    function earned(address account) public view override returns (uint256) {
        return (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    /// @notice Gets the total reward amount for a 14-day period
    /// @return The reward amount for the duration
    function getRewardForDuration() public view override returns (uint256) {
        return rewardRate * 14 days;
    }

    /// @notice Checks if an address is blacklisted
    /// @param account The address to check
    /// @return True if blacklisted, false otherwise
    function isBlacklisted(address account) public view returns (bool) {
        return blacklist[account];
    }

    /// @notice Get the unlocked balance for a user
    /// @param account The address to check
    /// @return The amount of tokens that are unlocked and can be withdrawn
    function getUnlockedBalance(address account) public view returns (uint256) {
        uint256 unlocked = 0;
        StakePosition[] storage positions = userStakePositions[account];
        
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].withdrawn && block.timestamp >= positions[i].unlockTime) {
                unlocked += positions[i].amount;
            }
        }
        
        return unlocked;
    }

    /// @notice Get the locked balance for a user
    /// @param account The address to check
    /// @return The amount of tokens that are still locked
    function getLockedBalance(address account) public view returns (uint256) {
        uint256 locked = 0;
        StakePosition[] storage positions = userStakePositions[account];
        
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].withdrawn && block.timestamp < positions[i].unlockTime) {
                locked += positions[i].amount;
            }
        }
        
        return locked;
    }

    /// @notice Get all stake positions for a user
    /// @param account The address to check
    /// @return Array of stake positions
    function getUserStakePositions(address account) external view returns (StakePosition[] memory) {
        return userStakePositions[account];
    }

    /// @notice Get a specific stake position
    /// @param account The address to check
    /// @param stakeId The index of the stake position
    /// @return The stake position
    function getStakePosition(address account, uint256 stakeId) external view returns (StakePosition memory) {
        if (stakeId >= userStakePositions[account].length) {
            revert InvalidStakeId(stakeId);
        }
        return userStakePositions[account][stakeId];
    }

    /// @notice Get total number of stake positions for a user
    /// @param account The address to check
    /// @return The number of stake positions
    function getUserStakePositionCount(address account) external view returns (uint256) {
        return userStakePositions[account].length;
    }

    /// @notice Get the current reward rate in a human-readable format
    /// @return rewardsPerDay The amount of rewards distributed per day
    function getRewardsPerDay() external view returns (uint256 rewardsPerDay) {
        return rewardRate * 1 days;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Stake tokens with default minimum lock period (interface compatibility)
    /// @param amount The amount of tokens to stake
    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender) whenNotPaused whenNotBlacklisted {
        // Call the lock version with minimum lock duration
        _stakeWithLock(msg.sender, amount, minimumLockDuration);
    }

    /// @notice Stake tokens with a custom time lock (with bonus rewards)
    /// @param amount The amount of tokens to stake
    /// @param lock The lock duration in seconds (must be at least minimumLockDuration)
    function stakeWithBonus(uint256 amount, uint256 lock) external nonReentrant updateReward(msg.sender) whenNotPaused whenNotBlacklisted {
        _stakeWithLock(msg.sender, amount, lock);
    }

    /// @notice Internal stake implementation
    /// @param user The user address staking
    /// @param amount The amount of tokens to stake
    /// @param lock The lock duration in seconds
    function _stakeWithLock(address user, uint256 amount, uint256 lock) internal {
        require(amount > 0, "Cannot stake 0");
        
        // Check minimum lock duration
        if (lock < minimumLockDuration) {
            revert LockDurationTooShort(lock, minimumLockDuration);
        }

        // Transfer tokens from user to contract
        stakingToken.safeTransferFrom(user, address(this), amount);

        // Mint staking receipt tokens (stAVI) to user
        _mint(user, amount);

        // Create new stake position
        userStakePositions[user].push(StakePosition({
            amount: amount,
            unlockTime: block.timestamp + lock,
            withdrawn: false
        }));

        // Update user's total stake
        userStaked[user] += amount;
        userStakeCount[user]++;
        lastStakeTime[user] = block.timestamp;

        emit Staked(user, amount, lock);
    }

    /// @notice Withdraw unlocked staked tokens
    /// @param amount The amount of tokens to withdraw
    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) whenNotPaused whenNotBlacklisted {
        require(amount > 0, "Cannot withdraw 0");
        
        uint256 availableToWithdraw = getUnlockedBalance(msg.sender);
        
        if (amount > availableToWithdraw) {
            revert InsufficientUnlockedBalance(amount, availableToWithdraw);
        }

        // Withdraw from unlocked positions (FIFO)
        uint256 remaining = amount;
        StakePosition[] storage positions = userStakePositions[msg.sender];
        
        for (uint256 i = 0; i < positions.length && remaining > 0; i++) {
            if (!positions[i].withdrawn && block.timestamp >= positions[i].unlockTime) {
                if (positions[i].amount <= remaining) {
                    // Withdraw entire position
                    remaining -= positions[i].amount;
                    positions[i].withdrawn = true;
                } else {
                    // Partial withdrawal - split the position
                    positions[i].amount -= remaining;
                    remaining = 0;
                }
            }
        }

        // Update user's stake
        userStaked[msg.sender] -= amount;

        // Burn staking receipt tokens
        _burn(msg.sender, amount);

        // Transfer tokens back to user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Withdraw a specific stake position by ID
    /// @param stakeId The ID of the stake position to withdraw
    function withdrawStakePosition(uint256 stakeId) external nonReentrant updateReward(msg.sender) whenNotPaused whenNotBlacklisted {
        if (stakeId >= userStakePositions[msg.sender].length) {
            revert InvalidStakeId(stakeId);
        }

        StakePosition storage position = userStakePositions[msg.sender][stakeId];
        
        require(!position.withdrawn, "Position already withdrawn");
        
        if (block.timestamp < position.unlockTime) {
            revert DepositStillLocked(block.timestamp, position.unlockTime);
        }

        uint256 amount = position.amount;
        position.withdrawn = true;

        // Update user's stake
        userStaked[msg.sender] -= amount;

        // Burn staking receipt tokens
        _burn(msg.sender, amount);

        // Transfer tokens back to user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim accumulated rewards (minus any fees)
    function getReward() public override nonReentrant updateReward(msg.sender) whenNotPaused whenNotBlacklisted {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            uint256 feeAmount = (reward * claimFee) / 1000; // Calculate fee (0.1% to 10%)
            uint256 netReward = reward - feeAmount;

            // Reset rewards before transfer
            rewards[msg.sender] = 0;

            // Transfer fee to DEFAULT_ADMIN_ROLE holder
            if (feeAmount > 0) {
                address admin = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
                rewardsToken.safeTransfer(admin, feeAmount);
            }

            // Transfer net reward to user
            rewardsToken.safeTransfer(msg.sender, netReward);

            emit RewardPaid(msg.sender, netReward);
        }
    }

    /// @notice Withdraw all unlocked staked tokens and claim all rewards
    function exit() external override whenNotPaused whenNotBlacklisted {
        uint256 unlockedBalance = getUnlockedBalance(msg.sender);
        if (unlockedBalance > 0) {
            withdraw(unlockedBalance);
        }
        getReward();
    }

    /// @notice Admin emergency function to shut down contract and recover rewards
    function reclaim() external onlyRole(ADMIN_ROLE) {
        // contract is effectively shut down
        rewardsAvailableDate = block.timestamp;
        rewardRate = 0;
        
        // Transfer to DEFAULT_ADMIN_ROLE holder
        address admin = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        rewardsToken.safeTransfer(admin, rewardsToken.balanceOf(address(this)));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Emergency withdraw ETH from contract
    /// @param recipient Address to receive the ETH
    /// @param amount Amount of ETH to withdraw
    function emergencyWithdrawETH(address payable recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(address(this).balance >= amount, "Insufficient ETH balance");
        recipient.transfer(amount);
    }

    /// @notice Emergency withdraw ERC20 tokens from contract
    /// @param tokenAddress The ERC20 token address
    /// @param recipient Address to receive the tokens
    /// @param amount Amount of tokens to withdraw
    function emergencyWithdrawERC20(address tokenAddress, address recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
        token.safeTransfer(recipient, amount);
    }

    /// @notice Emergency withdraw ERC721 NFTs from contract
    /// @param tokenAddress The ERC721 token address
    /// @param recipient Address to receive the NFT
    /// @param tokenId The NFT token ID
    function emergencyWithdrawERC721(address tokenAddress, address recipient, uint256 tokenId) external onlyRole(ADMIN_ROLE) {
        IERC721 token = IERC721(tokenAddress);
        require(token.ownerOf(tokenId) == address(this), "Not owner of token");
        token.transferFrom(address(this), recipient, tokenId);
    }

    /// @notice Set the fee percentage for reward claims
    /// @param _fee Fee in basis points (e.g., 5 = 0.5%)
    function setClaimFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
        require(_fee <= 100, "Fee cannot exceed 10%"); // Max 10%
        claimFee = _fee;
        emit ClaimFeeSet(_fee);
    }

    /// @notice Set the minimum lock duration
    /// @param _minimumLockDuration The new minimum lock duration in seconds
    function setMinimumLockDuration(uint256 _minimumLockDuration) external onlyRole(ADMIN_ROLE) {
        require(_minimumLockDuration > 0, "Lock duration must be greater than 0");
        minimumLockDuration = _minimumLockDuration;
        emit MinimumLockDurationSet(_minimumLockDuration);
    }

    /// @notice Make rewards available for claiming immediately
    function releaseRewards() external onlyRole(ADMIN_ROLE) {
        rewardsAvailableDate = block.timestamp;
        emit RewardsMadeAvailable(block.timestamp);
    }

    /// @notice Set the reward rate (rewards distributed per second)
    /// @param _rewardRate The new reward rate in wei per second
    function setRewardRate(uint256 _rewardRate) external onlyRole(ADMIN_ROLE) updateReward(address(0)) {
        rewardRate = _rewardRate;
        emit RewardRateSet(_rewardRate);
    }

    /// @notice Add reward tokens to the contract (callable by anyone)
    /// @param amount Amount of reward tokens to add
    function supplyRewards(uint256 amount) external updateReward(address(0)) {
        rewardsToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(amount);
    }

    /// @notice Add an address to the blacklist and return their staked tokens (forfeit rewards)
    /// @param account Address to blacklist
    function blacklistWallet(address account) external onlyRole(ADMIN_ROLE) updateReward(account) {
        blacklist[account] = true;
        
        // Return all staked tokens to user (both locked and unlocked)
        uint256 totalStaked = userStaked[account];
        if (totalStaked > 0) {
            // Mark all positions as withdrawn
            StakePosition[] storage positions = userStakePositions[account];
            for (uint256 i = 0; i < positions.length; i++) {
                if (!positions[i].withdrawn) {
                    positions[i].withdrawn = true;
                }
            }
            
            // Reset user's stake
            userStaked[account] = 0;
            
            // Forfeit all rewards
            rewards[account] = 0;
            
            // Burn staking receipt tokens
            _burn(account, totalStaked);
            
            // Return staked tokens to user
            stakingToken.safeTransfer(account, totalStaked);
            
            emit StakeReturnedDueToBlacklist(account, totalStaked);
        }
        
        emit BlacklistAdded(account);
    }

    /// @notice Remove an address from the blacklist
    /// @param account Address to remove from blacklist
    function unblacklistWallet(address account) external onlyRole(ADMIN_ROLE) {
        blacklist[account] = false;
        emit BlacklistRemoved(account);
    }

    /// @notice Pause all contract operations
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause contract operations
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Override ERC20 _update to update rewards on token transfers
    function _update(address from, address to, uint256 value) internal override(ERC20Pausable) updateReward(from) updateReward(to) {
        super._update(from, to, value);
    }

    /// @notice Override supportsInterface for AccessControlEnumerable
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControlEnumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /* ========== MODIFIERS ========== */

    /// @notice Updates reward calculations for an account
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /// @notice Prevents blacklisted addresses from calling function
    modifier whenNotBlacklisted() {
        if (blacklist[msg.sender]) {
            revert IsBlacklisted(msg.sender, "You are not allowed to interact with this contract.");
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, uint256 lock);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsMadeAvailable(uint256 timestampAvailable);
    event RewardRateSet(uint256 rewardRate);
    event BlacklistAdded(address indexed account);
    event BlacklistRemoved(address indexed account);
    event StakeReturnedDueToBlacklist(address indexed account, uint256 amount);
    event ClaimFeeSet(uint256 fee);
    event MinimumLockDurationSet(uint256 duration);
}