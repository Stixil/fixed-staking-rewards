// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./AviatorRewardsVault.sol";

/* ========== CUSTOM ERRORS ========== */

error CannotStakeZero(string reason);
error IsBlacklisted(address account, string reason);
error IsFrozen(address account, string reason);
error LockDurationTooShort(uint256 provided, uint256 minimum);
error DepositStillLocked(uint256 currentTime, uint256 unlockTime);
error TokenNotWhitelisted(address token);
error TokenAlreadyWhitelisted(address token);
error NotStakeOwner(uint256 tokenId);
error StakeAlreadyWithdrawn(uint256 tokenId);

contract AviatorStakingPool is ERC721Enumerable, Pausable, ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    /* ========== ROLES ========== */

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    /* ========== STRUCTS ========== */

    /// @notice Individual stake represented as NFT
    struct StakeNFT {
        uint256 amount;      // Amount staked
        uint256 unlockTime;  // When it can be withdrawn
        uint256 stakeTime;   // When it was created
        bool withdrawn;      // Has it been withdrawn
    }

    /// @notice Reward schedule for a token
    struct RewardSchedule {
        uint256 rewardRate;      // Tokens per second
        uint256 startTime;
        uint256 endTime;
        uint256 totalSupplied;
        uint256 pausedAt;        // Timestamp when paused (0 if active)
        uint256 totalPausedTime; // Cumulative pause duration
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable stakingToken;
    AviatorRewardsVault public immutable vault;
    
    uint256 public nextTokenId = 1;  // NFT token ID counter
    uint256 public totalStakedAmount; // Total amount staked across all NFTs
    
    uint256 public minimumLockDuration; // Configurable minimum lock duration
    uint256 public claimFeeETH;         // ETH fee for claiming rewards
    address public feeReceiver;         // Address that receives ETH claim fees

    // NFT stake data
    mapping(uint256 => StakeNFT) public stakes;

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

    // Freeze tracking
    mapping(address => bool) public frozen;

    // Blacklist
    mapping(address => bool) public blacklist;

    // Pause tracking for when totalStakedAmount == 0
    uint256 public lastTotalSupplyZeroTime;
    bool public wasTotalSupplyZero;

    /* ========== CONSTRUCTOR ========== */

    /// @notice Initializes the staking contract
    /// @param _admin The address that will have admin role
    /// @param _stakingToken The token users will stake
    /// @param _vault The rewards vault address
    constructor(address _admin, address _stakingToken, address _vault)
        ERC721("Aviator Stake Position", "stAVI-NFT")
    {
        stakingToken = IERC20(_stakingToken);
        vault = AviatorRewardsVault(_vault);
        minimumLockDuration = 12 weeks; // Default to 12 weeks
        claimFeeETH = 0.005 ether;      // Default 0.005 ETH
        feeReceiver = _admin;           // Default fee receiver is admin
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(FREEZER_ROLE, _admin);
    }

    /* ========== VIEWS ========== */

    /// @notice Get total staked amount for a user (sum of all their NFT stakes)
    /// @param account The address to check
    /// @return Total amount staked
    function balanceOfStaked(address account) public view returns (uint256) {
        uint256 nftBalance = balanceOf(account);
        uint256 total = 0;
        
        for (uint256 i = 0; i < nftBalance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(account, i);
            if (!stakes[tokenId].withdrawn) {
                total += stakes[tokenId].amount;
            }
        }
        
        return total;
    }

    /// @notice Calculates the current reward per token for a specific reward token
    /// @param token The reward token address
    /// @return The reward per token value
    function rewardPerToken(address token) public view returns (uint256) {
        if (totalStakedAmount == 0) {
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
        return (balanceOfStaked(account) * (rewardPerToken(token) - userRewardPerTokenPaidPerToken[account][token])) / 1e18 
            + rewardsPerToken[account][token];
    }

    /// @notice Returns the total rewards earned by an account (first whitelisted token)
    /// @param account The address to check rewards for
    /// @return The amount of rewards earned for the first whitelisted token
    function earned(address account) public view returns (uint256) {
        if (rewardTokensList.length > 0) {
            return earned(account, rewardTokensList[0]);
        }
        return 0;
    }

    /// @notice Gets the total reward amount for a 14-day period
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

    /// @notice Checks if an address is frozen
    /// @param account The address to check
    /// @return True if frozen, false otherwise
    function isFrozen(address account) public view returns (bool) {
        return frozen[account];
    }

    /// @notice Get the unlocked balance for a user
    /// @param account The address to check
    /// @return The amount of tokens that are unlocked and can be withdrawn
    function getUnlockedBalance(address account) public view returns (uint256) {
        uint256 nftBalance = balanceOf(account);
        uint256 unlocked = 0;
        
        for (uint256 i = 0; i < nftBalance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(account, i);
            StakeNFT storage stakeData = stakes[tokenId];
            
            if (!stakeData.withdrawn && block.timestamp >= stakeData.unlockTime) {
                unlocked += stakeData.amount;
            }
        }
        
        return unlocked;
    }

    /// @notice Get the locked balance for a user
    /// @param account The address to check
    /// @return The amount of tokens that are still locked
    function getLockedBalance(address account) public view returns (uint256) {
        uint256 nftBalance = balanceOf(account);
        uint256 locked = 0;
        
        for (uint256 i = 0; i < nftBalance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(account, i);
            StakeNFT storage stakeData = stakes[tokenId];
            
            if (!stakeData.withdrawn && block.timestamp < stakeData.unlockTime) {
                locked += stakeData.amount;
            }
        }
        
        return locked;
    }

    /// @notice Get all stake NFT IDs for a user
    /// @param account The address to check
    /// @return Array of token IDs
    function getUserStakeIds(address account) external view returns (uint256[] memory) {
        uint256 nftBalance = balanceOf(account);
        uint256[] memory tokenIds = new uint256[](nftBalance);
        
        for (uint256 i = 0; i < nftBalance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(account, i);
        }
        
        return tokenIds;
    }

    /// @notice Get all stake positions for a user with full details
    /// @param account The address to check
    /// @return Array of stake NFT data
    function getUserStakePositions(address account) external view returns (StakeNFT[] memory) {
        uint256 nftBalance = balanceOf(account);
        StakeNFT[] memory positions = new StakeNFT[](nftBalance);
        
        for (uint256 i = 0; i < nftBalance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(account, i);
            positions[i] = stakes[tokenId];
        }
        
        return positions;
    }

    /// @notice Get a specific stake position by token ID
    /// @param tokenId The NFT token ID
    /// @return The stake position
    function getStakePosition(uint256 tokenId) external view returns (StakeNFT memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return stakes[tokenId];
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

    /// @notice Stake tokens with default minimum lock period
    /// @param amount The amount of tokens to stake
    /// @return tokenId The NFT token ID representing this stake
    function stakeTokens(uint256 amount) external nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotFrozenOrBlacklisted returns (uint256) {
        return _stakeWithLock(msg.sender, amount, minimumLockDuration);
    }

    /// @notice Stake tokens with a custom time lock (with bonus rewards)
    /// @param amount The amount of tokens to stake
    /// @param lock The lock duration in seconds (must be at least minimumLockDuration)
    /// @return tokenId The NFT token ID representing this stake
    function stakeWithBonus(uint256 amount, uint256 lock) external nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotFrozenOrBlacklisted returns (uint256) {
        return _stakeWithLock(msg.sender, amount, lock);
    }

    /// @notice Internal stake implementation
    /// @param user The user address staking
    /// @param amount The amount of tokens to stake
    /// @param lock The lock duration in seconds
    /// @return tokenId The NFT token ID
    function _stakeWithLock(address user, uint256 amount, uint256 lock) internal returns (uint256) {
        require(amount > 0, "Cannot stake 0");
        
        // Check minimum lock duration
        if (lock < minimumLockDuration) {
            revert LockDurationTooShort(lock, minimumLockDuration);
        }

        // Transfer tokens from user to contract
        stakingToken.safeTransferFrom(user, address(this), amount);

        // Mint NFT to user
        uint256 tokenId = nextTokenId++;
        _safeMint(user, tokenId);

        // Store stake data
        stakes[tokenId] = StakeNFT({
            amount: amount,
            unlockTime: block.timestamp + lock,
            stakeTime: block.timestamp,
            withdrawn: false
        });

        // Update total staked
        totalStakedAmount += amount;

        emit Staked(user, tokenId, amount, lock);
        
        return tokenId;
    }

    /// @notice Withdraw a specific stake position by NFT token ID
    /// @param tokenId The NFT token ID to withdraw
    function withdraw(uint256 tokenId) public nonReentrant updateRewardForAllTokens(msg.sender) whenNotPaused whenNotFrozenOrBlacklisted {
        if (ownerOf(tokenId) != msg.sender) {
            revert NotStakeOwner(tokenId);
        }

        StakeNFT storage stakeData = stakes[tokenId];
        
        if (stakeData.withdrawn) {
            revert StakeAlreadyWithdrawn(tokenId);
        }
        
        if (block.timestamp < stakeData.unlockTime) {
            revert DepositStillLocked(block.timestamp, stakeData.unlockTime);
        }

        uint256 amount = stakeData.amount;
        stakeData.withdrawn = true;

        // Update total staked
        totalStakedAmount -= amount;

        // Burn NFT
        _burn(tokenId);

        // Transfer tokens back to user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, tokenId, amount);
    }

    /// @notice Withdraw multiple stake positions at once
    /// @param tokenIds Array of NFT token IDs to withdraw
    function withdrawMultiple(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            withdraw(tokenIds[i]);
        }
    }

    /// @notice Withdraw all unlocked stake positions
    function withdrawAllUnlocked() external {
        uint256 nftBalance = balanceOf(msg.sender);
        
        // Collect unlocked token IDs
        uint256[] memory unlockedIds = new uint256[](nftBalance);
        uint256 count = 0;
        
        for (uint256 i = 0; i < nftBalance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(msg.sender, i);
            StakeNFT storage stakeData = stakes[tokenId];
            
            if (!stakeData.withdrawn && block.timestamp >= stakeData.unlockTime) {
                unlockedIds[count] = tokenId;
                count++;
            }
        }
        
        // Withdraw all unlocked
        for (uint256 i = 0; i < count; i++) {
            withdraw(unlockedIds[i]);
        }
    }

    /// @notice Claim rewards for a specific token
    /// @param token The reward token to claim
    function getRewardForToken(address token) public payable nonReentrant updateRewardForToken(token, msg.sender) whenNotPaused whenNotFrozenOrBlacklisted {
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

    /// @notice Claim all rewards across all whitelisted tokens (single ETH fee)
    function getAllRewards() external payable nonReentrant whenNotPaused whenNotFrozenOrBlacklisted {
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

    /* ========== FREEZE FUNCTIONS  ========== */

    /// @notice Freeze a wallet for compliance purposes (rewards still accrue)
    /// @param account Address to freeze
    function freezeWallet(address account) external onlyRole(FREEZER_ROLE) {
        require(!frozen[account], "Already frozen");
        frozen[account] = true;
        emit WalletFrozen(account, block.timestamp);
    }

    /// @notice Unfreeze a wallet
    /// @param account Address to unfreeze
    function unfreezeWallet(address account) external onlyRole(FREEZER_ROLE) {
        require(frozen[account], "Not frozen");
        frozen[account] = false;
        emit WalletUnfrozen(account, block.timestamp);
    }

    /* ========== BLACKLIST FUNCTIONS ========== */

    /// @notice Blacklist an address and return their stake (forfeit all rewards as penalty)
    /// @param account Address to blacklist
    function blacklistWallet(address account) external onlyRole(ADMIN_ROLE) updateRewardForAllTokens(account) {
        blacklist[account] = true;
        
        // Get all user's NFTs
        uint256 nftBalance = balanceOf(account);
        uint256 totalToReturn = 0;
        
        if (nftBalance > 0) {
            // Process all stakes - mark as withdrawn but don't burn NFT
            for (uint256 i = 0; i < nftBalance; i++) {
                uint256 tokenId = tokenOfOwnerByIndex(account, i);
                StakeNFT storage stakeData = stakes[tokenId];
                
                if (!stakeData.withdrawn) {
                    totalToReturn += stakeData.amount;
                    stakeData.withdrawn = true; // Voids the NFT
                    totalStakedAmount -= stakeData.amount;
                }
            }
            
            // Forfeit all rewards for all tokens (penalty for breaking TOS)
            for (uint256 i = 0; i < rewardTokensList.length; i++) {
                rewardsPerToken[account][rewardTokensList[i]] = 0;
            }
            
            // Return staked tokens to user (we don't confiscate principal)
            if (totalToReturn > 0) {
                stakingToken.safeTransfer(account, totalToReturn);
                emit StakeReturnedDueToBlacklist(account, totalToReturn);
            }
        }
        
        emit BlacklistAdded(account);
    }

    /// @notice Remove an address from the blacklist
    /// @param account Address to remove from blacklist
    function unblacklistWallet(address account) external onlyRole(ADMIN_ROLE) {
        blacklist[account] = false;
        emit BlacklistRemoved(account);
    }

    /* ========== ADMIN FUNCTIONS ========== */

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

    /// @notice Emergency withdraw ETH from contract
    /// @param recipient Address to receive the ETH
    /// @param amount Amount of ETH to withdraw
    function emergencyWithdrawETH(address payable recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        recipient.transfer(amount);
        emit EmergencyWithdrawETH(msg.sender, recipient, amount);
    }

    /// @notice Emergency withdraw ERC20 tokens from contract (use for court-ordered confiscations)
    /// @param tokenAddress The ERC20 token address
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
        // Handle pause/resume logic when totalStakedAmount changes
        _handleSupplyChange();
        
        // Update reward per token stored
        if (totalStakedAmount > 0) {
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

    /// @notice Handle pause/resume of reward schedules when totalStakedAmount changes
    function _handleSupplyChange() internal {
        bool isZeroNow = (totalStakedAmount == 0);
        
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

    /// @notice Override _update to block transfers from frozen wallets and update rewards
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721Enumerable) returns (address) {
        address from = _ownerOf(tokenId);
        
        // Block transfers from frozen accounts (compliance hold)
        if (from != address(0)) { // Not a mint
            if (frozen[from]) {
                revert IsFrozen(from, "Cannot transfer: account is frozen");
            }
        }
        
        // Update rewards for both sender and receiver for all tokens
        for (uint256 i = 0; i < rewardTokensList.length; i++) {
            address token = rewardTokensList[i];
            if (whitelistedRewardTokens[token]) {
                _updateRewardForToken(token, from);
                _updateRewardForToken(token, to);
            }
        }
        
        return super._update(to, tokenId, auth);
    }

    /// @notice Override supportsInterface for multiple inheritance
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(ERC721Enumerable, AccessControlEnumerable) 
        returns (bool) 
    {
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

    /// @notice Prevents frozen or blacklisted addresses from calling function
    modifier whenNotFrozenOrBlacklisted() {
        if (frozen[msg.sender]) {
            revert IsFrozen(msg.sender, "Account is frozen for compliance purposes");
        }
        if (blacklist[msg.sender]) {
            revert IsBlacklisted(msg.sender, "Account is blacklisted");
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardTokenAdded(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event RewardAdded(address indexed token, uint256 amount, uint256 duration, uint256 rewardRate);
    event Staked(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 lock);
    event Withdrawn(address indexed user, uint256 indexed tokenId, uint256 amount);
    event RewardPaid(address indexed user, address indexed token, uint256 reward);
    event WalletFrozen(address indexed account, uint256 timestamp);
    event WalletUnfrozen(address indexed account, uint256 timestamp);
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