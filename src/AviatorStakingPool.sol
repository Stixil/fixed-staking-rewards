// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./AviatorRewardsVault.sol";

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
error TokenNotWhitelisted(address token);
error TokenAlreadyWhitelisted(address token);

contract AviatorStakingPool is ERC20Pausable, ReentrancyGuard, AccessControlEnumerable {
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

    /// @notice Reward schedule for a token
    struct RewardSchedule {
        uint256 rewardRate; // Tokens per second
        uint256 startTime;
        uint256 endTime;
        uint256 totalSupplied;
        uint256 pausedAt; // Timestamp when paused (0 if active)
        uint256 totalPausedTime; // Cumulative pause duration
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable stakingToken;
    AviatorRewardsVault public immutable vault;
    
    uint256 public minimumLockDuration; // Configurable minimum lock duration
    uint256 public claimFeeETH; // ETH fee for claiming rewards
    address public feeReceiver; // Address that receives ETH claim fees

    // Reward token whitelist
    mapping(address => bool) public whitelistedRewardTokens;
    address[] public rewardTokensList;

    // Reward schedules per token
    mapping(address => RewardSchedule[]) public rewardSchedules;
    mapping(address => uint256) public lastUpdateTimePerToken;
    mapping(address => uint256) public rewardPerTokenStoredPerToken;

    // User reward tracking per token
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaidPerToken;
    mapping(address => mapping(address => uint256)) public rewardsPerToken;

    // Blacklist
    mapping(address => bool) public blacklist;

    // Staking tracking
    mapping(address => uint256) public userStaked; // Total staked by user
    mapping(address => uint256) public lastStakeTime;
    mapping(address => StakePosition[]) public userStakePositions;
    mapping(address => uint256) public userStakeCount;

    // Pause tracking for when totalSupply == 0
    uint256 public lastTotalSupplyZeroTime;
    bool public wasTotalSupplyZero;

    /* ========== CONSTRUCTOR ========== */

    /// @notice Initializes the staking contract
    /// @param _admin The address that will have admin role
    /// @param _stakingToken The token users will stake
    /// @param _vault The rewards vault address
    constructor(address _admin, address _stakingToken, address _vault)
        ERC20("RewardsStakedAVI", "stAVI")
    {
        stakingToken = IERC20(_stakingToken);
        vault = AviatorRewardsVault(_vault);
        minimumLockDuration = 12 weeks; // Default to 12 weeks
        claimFeeETH = 0.005 ether; // Default 0.005 ETH
        feeReceiver = _admin; // Default fee receiver is admin
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    /* ========== VIEWS ========== */

    /// @notice Calculates the current reward per token for a specific reward token
    /// @param token The reward token address
    /// @return The reward per token value
    function rewardPerToken(address token) public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStoredPerToken[token];
        }

        uint256 activeRate = getActiveRewardRate(token);
        uint256 timeDelta = block.timestamp - lastUpdateTimePerToken[token];
        
        return rewardPerTokenStoredPerToken[token] + (timeDelta * activeRate);
    }

    /// @notice Get the active reward rate for a token (sum of all active schedules)
    /// @param token The reward token address
    /// @return Total active reward rate
    function getActiveRewardRate(address token) public view returns (uint256) {
        uint256 totalRate = 0;
        RewardSchedule[] storage schedules = rewardSchedules[token];
        
        for (uint256 i = 0; i < schedules.length; i++) {
            if (block.timestamp >= schedules[i].startTime && block.timestamp < schedules[i].endTime) {
                totalRate += schedules[i].rewardRate;
            }
        }
        
        return totalRate;
    }

    /// @notice Returns the total rewards earned by an account for a specific token
    /// @param account The address to check rewards for
    /// @param token The reward token address
    /// @return The amount of rewards earned
    function earned(address account, address token) public view returns (uint256) {
        return (balanceOf(account) * (rewardPerToken(token) - userRewardPerTokenPaidPerToken[account][token])) / 1e18 
            + rewardsPerToken[account][token];
    }

    /// @notice Returns the total rewards earned by an account (legacy interface compatibility)
    /// @param account The address to check rewards for
    /// @return The amount of rewards earned for the first whitelisted token
    function earned(address account) public view returns (uint256) {
        if (rewardTokensList.length > 0) {
            return earned(account, rewardTokensList[0]);
        }
        return 0;
    }

    /// @notice Gets the total reward amount for a 14-day period (legacy interface)
    /// @return The reward amount for the duration
    function getRewardForDuration() public view returns (uint256) {
        if (rewardTokensList.length > 0) {
            return getActiveRewardRate(rewardTokensList[0]) * 14 days;
        }
        return 0;
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

    /// @notice Get all whitelisted reward tokens
    /// @return Array of whitelisted token addresses
    function getWhitelistedRewardTokens() external view returns (address[] memory) {
        return rewardTokensList;
    }

    /// @notice Get all reward schedules for a token
    /// @param token The reward token address
    /// @return Array of reward schedules
    function getRewardSchedules(address token) external view returns (RewardSchedule[] memory) {
        return rewardSchedules[token];
    }

    /// @notice Get earned rewards for all whitelisted tokens
    /// @param account The address to check
    /// @return tokens Array of token addresses
    /// @return amounts Array of earned amounts
    function earnedAll(address account) external view returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](rewardTokensList.length);
        amounts = new uint256[](rewardTokensList.length);
        
        for (uint256 i = 0; i < rewardTokensList.length; i++) {
            tokens[i] = rewardTokensList[i];
            amounts[i] = earned(account, rewardTokensList[i]);
        }
        
        return (tokens, amounts);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Stake tokens with default minimum lock period (interface compatibility)
    /// @param amount The amount of tokens to stake
    function stake(uint256 amount) external nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotBlacklisted {
        _stakeWithLock(msg.sender, amount, minimumLockDuration);
    }

    /// @notice Stake tokens with a custom time lock (with bonus rewards)
    /// @param amount The amount of tokens to stake
    /// @param lock The lock duration in seconds (must be at least minimumLockDuration)
    function stakeWithBonus(uint256 amount, uint256 lock) external nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotBlacklisted {
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
    function withdraw(uint256 amount) public nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotBlacklisted {
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
    function withdrawStakePosition(uint256 stakeId) external nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotBlacklisted {
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

    /// @notice Claim rewards for a specific token
    /// @param token The reward token to claim
    function getRewardForToken(address token) public payable nonReentrant updateRewardForToken(token, msg.sender) whenNotPaused whenNotBlacklisted {
        require(msg.value >= claimFeeETH, "Insufficient claim fee");
        
        uint256 reward = rewardsPerToken[msg.sender][token];
        if (reward > 0) {
            rewardsPerToken[msg.sender][token] = 0;
            
            // Pay reward from vault
            vault.payReward(msg.sender, token, reward);
            
            emit RewardPaid(msg.sender, token, reward);
        }
        
        // Send ETH fee to fee receiver
        if (msg.value > 0) {
            payable(feeReceiver).transfer(msg.value);
        }
    }

    /// @notice Claim accumulated rewards (legacy interface - claims first whitelisted token)
    function getReward() public nonReentrant whenNotPaused whenNotBlacklisted {
        if (rewardTokensList.length > 0) {
            // For legacy compatibility, just update rewards without claiming
            // Users should use getRewardForToken or getAllRewards
            _updateRewardForToken(rewardTokensList[0], msg.sender);
        }
    }

    /// @notice Claim all rewards across all whitelisted tokens (single ETH fee)
    function getAllRewards() external payable nonReentrant whenNotPaused whenNotBlacklisted {
        require(msg.value >= claimFeeETH, "Insufficient claim fee");
        
        bool claimedAny = false;
        
        for (uint256 i = 0; i < rewardTokensList.length; i++) {
            address token = rewardTokensList[i];
            if (whitelistedRewardTokens[token]) {
                _updateRewardForToken(token, msg.sender);
                
                uint256 reward = rewardsPerToken[msg.sender][token];
                if (reward > 0) {
                    rewardsPerToken[msg.sender][token] = 0;
                    vault.payReward(msg.sender, token, reward);
                    emit RewardPaid(msg.sender, token, reward);
                    claimedAny = true;
                }
            }
        }
        
        // Send ETH fee to fee receiver
        if (msg.value > 0 && claimedAny) {
            payable(feeReceiver).transfer(msg.value);
        }
    }

    /// @notice Withdraw all unlocked staked tokens and claim all rewards
    function exit() external whenNotPaused whenNotBlacklisted {
        uint256 unlockedBalance = getUnlockedBalance(msg.sender);
        if (unlockedBalance > 0) {
            withdraw(unlockedBalance);
        }
        // Note: getReward() is legacy, users should call getAllRewards() separately with ETH
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Add a token to the rewards whitelist
    /// @param token The token address to whitelist
    function addRewardToken(address token) external onlyRole(ADMIN_ROLE) {
        require(token != address(0), "Invalid token address");
        if (whitelistedRewardTokens[token]) {
            revert TokenAlreadyWhitelisted(token);
        }
        
        whitelistedRewardTokens[token] = true;
        rewardTokensList.push(token);
        lastUpdateTimePerToken[token] = block.timestamp;
        
        emit RewardTokenAdded(token);
    }

    /// @notice Remove a token from the rewards whitelist (prevents new supplies, existing schedules continue)
    /// @param token The token address to remove
    function removeRewardToken(address token) external onlyRole(ADMIN_ROLE) {
        if (!whitelistedRewardTokens[token]) {
            revert TokenNotWhitelisted(token);
        }
        
        whitelistedRewardTokens[token] = false;
        
        // Remove from array (find and swap with last element)
        for (uint256 i = 0; i < rewardTokensList.length; i++) {
            if (rewardTokensList[i] == token) {
                rewardTokensList[i] = rewardTokensList[rewardTokensList.length - 1];
                rewardTokensList.pop();
                break;
            }
        }
        
        emit RewardTokenRemoved(token);
    }

    /// @notice Supply rewards for a specific token over a duration
    /// @param token The reward token address
    /// @param amount Total amount of reward tokens to distribute
    /// @param duration Duration in seconds over which to distribute rewards
    function supplyRewards(address token, uint256 amount, uint256 duration) external onlyRole(ADMIN_ROLE) updateRewardForToken(token, address(0)) {
        if (!whitelistedRewardTokens[token]) {
            revert TokenNotWhitelisted(token);
        }
        require(amount > 0, "Cannot supply 0 rewards");
        require(duration > 0, "Duration must be greater than 0");
        
        // Transfer tokens from caller to vault
        IERC20(token).safeTransferFrom(msg.sender, address(vault), amount);
        
        // Create new reward schedule
        rewardSchedules[token].push(RewardSchedule({
            rewardRate: amount / duration,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            totalSupplied: amount,
            pausedAt: 0,
            totalPausedTime: 0
        }));
        
        emit RewardAdded(token, amount, duration, amount / duration);
    }

    /// @notice Set the minimum lock duration
    /// @param _minimumLockDuration The new minimum lock duration in seconds
    function setMinimumLockDuration(uint256 _minimumLockDuration) external onlyRole(ADMIN_ROLE) {
        require(_minimumLockDuration > 0, "Lock duration must be greater than 0");
        minimumLockDuration = _minimumLockDuration;
        emit MinimumLockDurationSet(_minimumLockDuration);
    }

    /// @notice Set the ETH claim fee
    /// @param _claimFeeETH The new claim fee in wei
    function setClaimFeeETH(uint256 _claimFeeETH) external onlyRole(ADMIN_ROLE) {
        claimFeeETH = _claimFeeETH;
        emit ClaimFeeETHSet(_claimFeeETH);
    }

    /// @notice Set the fee receiver address
    /// @param _feeReceiver The new fee receiver address
    function setFeeReceiver(address _feeReceiver) external onlyRole(ADMIN_ROLE) {
        require(_feeReceiver != address(0), "Invalid address");
        feeReceiver = _feeReceiver;
        emit FeeReceiverSet(_feeReceiver);
    }

    /// @notice Add an address to the blacklist and return their staked tokens (forfeit all rewards)
    /// @param account Address to blacklist
    function blacklistWallet(address account) external onlyRole(ADMIN_ROLE) updateRewardForAllTokens(account) {
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
            
            // Forfeit all rewards for all tokens
            for (uint256 i = 0; i < rewardTokensList.length; i++) {
                rewardsPerToken[account][rewardTokensList[i]] = 0;
            }
            
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

    /// @notice Emergency withdraw ETH from contract
    /// @param recipient Address to receive the ETH
    /// @param amount Amount of ETH to withdraw
    function emergencyWithdrawETH(address payable recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        recipient.transfer(amount);
        emit EmergencyWithdrawETH(msg.sender, recipient, amount);
    }

    /// @notice Emergency withdraw ERC20 tokens from contract
    /// @param recipient Address to receive the tokens
    /// @param amount Amount of tokens to withdraw
    function emergencyWithdrawERC20(address tokenAddress, address recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        IERC20(tokenAddress).safeTransfer(recipient, amount);
        emit EmergencyWithdrawERC20(msg.sender, tokenAddress, recipient, amount);
    }


    /// @notice Emergency withdraw ERC721 NFTs from contract
    /// @param tokenAddress The ERC721 token address
    /// @param recipient Address to receive the NFT
    /// @param tokenId The NFT token ID
    function emergencyWithdrawERC721(address tokenAddress, address recipient, uint256 tokenId) external onlyRole(ADMIN_ROLE) {
        IERC721 token = IERC721(tokenAddress);
        token.transferFrom(address(this), recipient, tokenId);
        emit EmergencyWithdrawERC721(msg.sender, tokenAddress, recipient, tokenId);
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

    /// @notice Internal function to update rewards for a specific token and account
    function _updateRewardForToken(address token, address account) internal {
        // Handle pause/resume logic when totalSupply changes
        _handleSupplyChange();
        
        // Update reward per token stored
        if (totalSupply() > 0) {
            uint256 activeRate = getActiveRewardRate(token);
            uint256 timeDelta = block.timestamp - lastUpdateTimePerToken[token];
            rewardPerTokenStoredPerToken[token] += (timeDelta * activeRate);
        }
        
        lastUpdateTimePerToken[token] = block.timestamp;
        
        // Update user rewards
        if (account != address(0)) {
            rewardsPerToken[account][token] = earned(account, token);
            userRewardPerTokenPaidPerToken[account][token] = rewardPerTokenStoredPerToken[token];
        }
    }

    /// @notice Handle pause/resume of reward schedules when totalSupply changes
    function _handleSupplyChange() internal {
        bool isZeroNow = (totalSupply() == 0);
        
        if (isZeroNow && !wasTotalSupplyZero) {
            // Just hit zero - pause all schedules
            lastTotalSupplyZeroTime = block.timestamp;
            wasTotalSupplyZero = true;
            
            // Mark all active schedules as paused
            for (uint256 i = 0; i < rewardTokensList.length; i++) {
                address token = rewardTokensList[i];
                RewardSchedule[] storage schedules = rewardSchedules[token];
                
                for (uint256 j = 0; j < schedules.length; j++) {
                    if (schedules[j].pausedAt == 0 && 
                        block.timestamp >= schedules[j].startTime && 
                        block.timestamp < schedules[j].endTime) {
                        schedules[j].pausedAt = block.timestamp;
                    }
                }
            }
        } else if (!isZeroNow && wasTotalSupplyZero) {
            // Just resumed from zero - unpause all schedules
            uint256 pauseDuration = block.timestamp - lastTotalSupplyZeroTime;
            wasTotalSupplyZero = false;
            
            // Add pause duration to all schedules that were paused
            for (uint256 i = 0; i < rewardTokensList.length; i++) {
                address token = rewardTokensList[i];
                RewardSchedule[] storage schedules = rewardSchedules[token];
                
                for (uint256 j = 0; j < schedules.length; j++) {
                    if (schedules[j].pausedAt > 0) {
                        schedules[j].totalPausedTime += pauseDuration;
                        schedules[j].pausedAt = 0;
                    }
                }
            }
        }
    }

    /// @notice Override ERC20 _update to update rewards on token transfers
    function _update(address from, address to, uint256 value) internal override(ERC20Pausable) {
        // Update rewards for both sender and receiver for all tokens
        for (uint256 i = 0; i < rewardTokensList.length; i++) {
            address token = rewardTokensList[i];
            if (whitelistedRewardTokens[token]) {
                _updateRewardForToken(token, from);
                _updateRewardForToken(token, to);
            }
        }
        
        super._update(from, to, value);
    }

    /// @notice Override supportsInterface for AccessControlEnumerable
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControlEnumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /* ========== MODIFIERS ========== */

    /// @notice Updates reward calculations for a specific token and account
    modifier updateRewardForToken(address token, address account) {
        _updateRewardForToken(token, account);
        _;
    }

    /// @notice Updates reward calculations for all whitelisted tokens for an account
    modifier updateRewardForAllTokens(address account) {
        for (uint256 i = 0; i < rewardTokensList.length; i++) {
            address token = rewardTokensList[i];
            if (whitelistedRewardTokens[token]) {
                _updateRewardForToken(token, account);
            }
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

    event RewardTokenAdded(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event RewardAdded(address indexed token, uint256 amount, uint256 duration, uint256 rewardRate);
    event Staked(address indexed user, uint256 amount, uint256 lock);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, address indexed token, uint256 reward);
    event BlacklistAdded(address indexed account);
    event BlacklistRemoved(address indexed account);
    event StakeReturnedDueToBlacklist(address indexed account, uint256 amount);
    event MinimumLockDurationSet(uint256 duration);
    event ClaimFeeETHSet(uint256 fee);
    event FeeReceiverSet(address indexed feeReceiver);
    event EmergencyWithdrawETH(address indexed caller, address indexed recipient, uint256 amount);
    event EmergencyWithdrawERC20(address indexed caller, address indexed token, address indexed recipient, uint256 amount);
    event EmergencyWithdrawERC721(address indexed caller, address indexed token, address indexed recipient, uint256 tokenId);
}