// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title StarGazingFinance
 * @dev Staking contract with built-in affiliate system for passive income
 */
contract StarGazingFinance is Ownable, ReentrancyGuard, Pausable {
    // Token being staked
    IERC20 public stakingToken;
    
    // Staking constants
    uint256 public constant REWARD_RATE = 5; // 5% monthly rewards
    uint256 public constant REFERRAL_REWARD_RATE = 10; // 10% of referred staker's rewards
    uint256 public constant MINIMUM_STAKE_AMOUNT = 100 * 10**18; // 100 tokens minimum
    uint256 public constant SECONDS_IN_MONTH = 30 days;
    
    // Staking data structures
    struct StakerInfo {
        uint256 stakedAmount;
        uint256 stakedTimestamp;
        uint256 lastClaimTimestamp;
        address referrer;
        address[] referrals;
        bool isActive;
    }
    
    // Mappings
    mapping(address => StakerInfo) public stakers;
    mapping(address => uint256) public totalReferralRewards;
    mapping(address => uint256) public totalDirectRewards;
    
    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ReferralRewardPaid(address indexed referrer, address indexed staker, uint256 amount);
    event ReferralAdded(address indexed referrer, address indexed referred);
    
    // Owner address for initial setup
    address public deployer;
    
    /**
     * @dev Constructor sets the owner and staking token
     * @param _stakingToken Address of the token to be staked
     */
    constructor(address _stakingToken) Ownable(msg.sender) {
        require(_stakingToken != address(0), "Invalid token address");
        stakingToken = IERC20(_stakingToken);
        deployer = msg.sender;
        
        // Auto-setup deployer as first staker with zero stake
        StakerInfo storage deployerInfo = stakers[deployer];
        deployerInfo.stakedTimestamp = block.timestamp;
        deployerInfo.lastClaimTimestamp = block.timestamp;
        deployerInfo.isActive = true;
    }
    
    /**
     * @dev Stake tokens with optional referrer
     * @param amount Amount of tokens to stake
     * @param referrer Address of the referrer (zero address if none)
     */
    function stake(uint256 amount, address referrer) external nonReentrant whenNotPaused {
        require(amount >= MINIMUM_STAKE_AMOUNT, "Stake amount too small");
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        StakerInfo storage stakerInfo = stakers[msg.sender];
        
        // If first time staking, set up staker info
        if (!stakerInfo.isActive) {
            stakerInfo.stakedTimestamp = block.timestamp;
            stakerInfo.lastClaimTimestamp = block.timestamp;
            stakerInfo.isActive = true;
            
            // Handle referral system
            if (referrer != address(0) && referrer != msg.sender && stakers[referrer].isActive) {
                stakerInfo.referrer = referrer;
                stakers[referrer].referrals.push(msg.sender);
                emit ReferralAdded(referrer, msg.sender);
            } else if (msg.sender != deployer) {
                // If no valid referrer, default to deployer
                stakerInfo.referrer = deployer;
                stakers[deployer].referrals.push(msg.sender);
                emit ReferralAdded(deployer, msg.sender);
            }
        } else {
            // Claim any pending rewards before adding more stake
            _claimRewards(msg.sender);
        }
        
        stakerInfo.stakedAmount += amount;
        emit Staked(msg.sender, amount);
    }
    
    /**
     * @dev Unstake tokens
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        StakerInfo storage stakerInfo = stakers[msg.sender];
        require(stakerInfo.isActive, "Not staking");
        require(amount > 0 && amount <= stakerInfo.stakedAmount, "Invalid unstake amount");
        
        // Claim any pending rewards first
        _claimRewards(msg.sender);
        
        stakerInfo.stakedAmount -= amount;
        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
        
        // If completely unstaked, keep record but mark as inactive
        if (stakerInfo.stakedAmount == 0) {
            stakerInfo.isActive = false;
        }
        
        emit Unstaked(msg.sender, amount);
    }
    
    /**
     * @dev Claim pending rewards
     */
    function claimRewards() external nonReentrant {
        _claimRewards(msg.sender);
    }
    
    /**
     * @dev Internal function to claim rewards
     * @param staker Address of the staker
     */
    function _claimRewards(address staker) internal {
        StakerInfo storage stakerInfo = stakers[staker];
        require(stakerInfo.isActive, "Not staking");
        
        uint256 rewards = calculateRewards(staker);
        if (rewards > 0) {
            stakerInfo.lastClaimTimestamp = block.timestamp;
            
            // Transfer direct rewards to staker
            require(stakingToken.transfer(staker, rewards), "Reward transfer failed");
            totalDirectRewards[staker] += rewards;
            emit RewardClaimed(staker, rewards);
            
            // Handle referral rewards if there's a referrer
            if (stakerInfo.referrer != address(0)) {
                uint256 referralReward = (rewards * REFERRAL_REWARD_RATE) / 100;
                if (referralReward > 0) {
                    require(stakingToken.transfer(stakerInfo.referrer, referralReward), "Referral reward transfer failed");
                    totalReferralRewards[stakerInfo.referrer] += referralReward;
                    emit ReferralRewardPaid(stakerInfo.referrer, staker, referralReward);
                }
            }
        }
    }
    
    /**
     * @dev Calculate pending rewards for a staker
     * @param staker Address of the staker
     * @return uint256 Pending rewards
     */
    function calculateRewards(address staker) public view returns (uint256) {
        StakerInfo storage stakerInfo = stakers[staker];
        if (!stakerInfo.isActive || stakerInfo.stakedAmount == 0) {
            return 0;
        }
        
        uint256 timeElapsed = block.timestamp - stakerInfo.lastClaimTimestamp;
        uint256 monthlyReward = (stakerInfo.stakedAmount * REWARD_RATE) / 100;
        uint256 rewardsPerSecond = monthlyReward / SECONDS_IN_MONTH;
        
        return rewardsPerSecond * timeElapsed;
    }
    
    /**
     * @dev Get all referrals for an address
     * @param referrer Address of the referrer
     * @return address[] Array of referral addresses
     */
    function getReferrals(address referrer) external view returns (address[] memory) {
        return stakers[referrer].referrals;
    }
    
    /**
     * @dev Get number of referrals for an address
     * @param referrer Address of the referrer
     * @return uint256 Number of referrals
     */
    function getReferralCount(address referrer) external view returns (uint256) {
        return stakers[referrer].referrals.length;
    }
    
    /**
     * @dev Get total rewards (direct + referral) for an address
     * @param staker Address of the staker
     * @return uint256 Total rewards earned
     */
    function getTotalEarnings(address staker) external view returns (uint256) {
        return totalDirectRewards[staker] + totalReferralRewards[staker];
    }
    
    /**
     * @dev Emergency pause by owner
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Resume from paused state
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Set up deployer wallet to receive funds from contract (in case of emergency)
     * @param _deployer Address to set as deployer
     */
    function setDeployer(address _deployer) external onlyOwner {
        require(_deployer != address(0), "Invalid deployer address");
        deployer = _deployer;
    }
    
    /**
     * @dev Emergency withdraw stuck tokens by owner
     * @param tokenAddress Address of the token to withdraw
     */
    function emergencyWithdraw(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(deployer, balance), "Emergency withdraw failed");
    }
}