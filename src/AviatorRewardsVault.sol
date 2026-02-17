// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract AviatorRewardsVault is Initializable, AccessControlEnumerableUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURY = keccak256("TREASURY");

    address public stakingContract;
    bool public stakingContractSet;

    // Storage gap for future upgrades
    uint256[50] private __gap;

    /* ========== CONSTRUCTOR & INITIALIZER ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault contract
    /// @param _admin The address that will have admin and treasury roles
    function initialize(address _admin) public initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(TREASURY, _admin);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Set the staking contract address (one-time only)
    /// @param _stakingContract The staking contract address
    function setStakingContract(address _stakingContract) external onlyRole(TREASURY) {
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
    function payReward(address user, address token, uint256 amount) external onlyStakingContract {
        IERC20(token).safeTransfer(user, amount);
        emit RewardPaid(user, token, amount);
    }

    /// @notice Emergency withdraw ETH from vault
    /// @param recipient Address to receive the ETH
    /// @param amount Amount of ETH to withdraw
    function emergencyWithdrawETH(address payable recipient, uint256 amount) external onlyRole(TREASURY) {
        recipient.transfer(amount);
        emit EmergencyWithdrawETH(msg.sender, recipient, amount);
    }

    /// @notice Emergency withdraw ERC20 tokens from vault (use for court-ordered confiscations)
    /// @param tokenAddress The ERC20 token address
    /// @param recipient Address to receive the tokens
    /// @param amount Amount of tokens to withdraw
    function emergencyWithdrawERC20(address tokenAddress, address recipient, uint256 amount) external onlyRole(TREASURY) {
        IERC20(tokenAddress).safeTransfer(recipient, amount);
        emit EmergencyWithdrawERC20(msg.sender, tokenAddress, recipient, amount);
    }

    /// @notice Emergency withdraw ERC721 NFTs from vault
    /// @param tokenAddress The ERC721 token address
    /// @param recipient Address to receive the NFT
    /// @param tokenId The NFT token ID
    function emergencyWithdrawERC721(address tokenAddress, address recipient, uint256 tokenId) external onlyRole(TREASURY) {
        IERC721 token = IERC721(tokenAddress);
        token.transferFrom(address(this), recipient, tokenId);
        emit EmergencyWithdrawERC721(msg.sender, tokenAddress, recipient, tokenId);
    }

    /// @notice Get token balance in vault
    /// @param token The token address
    /// @return The balance
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Override supportsInterface for AccessControlEnumerable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyStakingContract() {
        require(msg.sender == stakingContract, "Only staking contract");
        _;
    }

    /* ========== EVENTS ========== */

    event StakingContractSet(address indexed stakingContract);
    event RewardPaid(address indexed user, address indexed token, uint256 amount);
    event EmergencyWithdrawETH(address indexed caller, address indexed recipient, uint256 amount);
    event EmergencyWithdrawERC20(address indexed caller, address indexed token, address indexed recipient, uint256 amount);
    event EmergencyWithdrawERC721(address indexed caller, address indexed token, address indexed recipient, uint256 tokenId);
}