// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./libs/reentrancy-guard.sol";
import "./libs/pausable.sol";
import "./libs/BEP20.sol";
import "./libs/safe-math.sol";

import "./interfaces/pool.sol";

contract B4shPool is ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct Claim {
        uint256 amount;
        uint256 timestamp;
    }

    // STATE VARIABLES

    IBEP20 public rewardsToken;
    IBEP20 public stakingToken;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 7890000; // 3 months
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public claimUnlockPeriod;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _locked;
    mapping(address => Claim) private _claims;

    address private _stakingPool;

    // CONSTRUCTOR

    constructor(
        address _rewardsToken,
        address _stakingToken
    ) public {
        rewardsToken = IBEP20(_rewardsToken);
        if (_stakingToken != address(0)) {
            stakingToken = IBEP20(_stakingToken);
        }
    }

    // VIEWS

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account].add(_locked[account]);
    }

    function lockedOf(address account) external view returns (uint256) {
        return _locked[account];
    }

    function claimable(address account) external view returns (Claim memory) {
        return _claims[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(_totalSupply)
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            _balances[account]
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    // PUBLIC FUNCTIONS

    function deposit(uint256 amount)
        external
        nonReentrant
        notPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot stake 0");

        uint256 balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = stakingToken.balanceOf(address(this));
        uint256 actualReceived = balAfter.sub(balBefore);

        _totalSupply = _totalSupply.add(actualReceived);

        if (_claims[msg.sender].amount == 0) {
            _balances[msg.sender] = _balances[msg.sender].add(actualReceived);
        } else {
            _locked[msg.sender] = _locked[msg.sender].add(actualReceived);
        }
        
        emit Deposited(msg.sender, actualReceived);
    }

    function withdraw(uint256 amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot withdraw 0");
        require(_balances[msg.sender] >= amount, '!balance');

        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function claim() public nonReentrant updateReward(msg.sender) {
        require(_claims[msg.sender].amount == 0, '!outstanding');

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _claims[msg.sender].amount = _claims[msg.sender].amount.add(reward);
            _claims[msg.sender].timestamp = block.timestamp;
            _locked[msg.sender] = _locked[msg.sender].add(_balances[msg.sender]);
            _balances[msg.sender] = 0;
            
            emit ClaimRequested(msg.sender, reward, block.timestamp);
        }
    }

    function collect() public nonReentrant updateReward(msg.sender) {
        require(_claims[msg.sender].amount > 0, '!claim');
        require(block.timestamp > _claims[msg.sender].timestamp.add(claimUnlockPeriod), '!period');

        uint256 reward = _claims[msg.sender].amount;
        _balances[msg.sender] = _locked[msg.sender];
        _claims[msg.sender].amount = 0;
        _locked[msg.sender] = 0;

        rewardsToken.safeTransfer(msg.sender, reward);
    }

    function cancel() public nonReentrant updateReward(msg.sender) {
        require(_claims[msg.sender].amount > 0, '!claim');

        uint256 reward = _claims[msg.sender].amount;
        _balances[msg.sender] = _locked[msg.sender];
        _claims[msg.sender].amount = 0;
        _locked[msg.sender] = 0;
        rewards[msg.sender] = reward;
    }

    function stake() public nonReentrant updateReward(msg.sender) {
        require(_claims[msg.sender].amount == 0, '!outstanding');

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(_stakingPool, reward);
            IPool(_stakingPool).depositFor(msg.sender, reward);
        }
    }

    // RESTRICTED FUNCTIONS

    function setStakingToken(address _stakingToken)
        external
        restricted
    {
        require(address(stakingToken) == address(0), "!stakingToken");
        stakingToken = IBEP20(_stakingToken);
    }

    function setClaimUnlockPeriod(uint256 _claimUnlockPeriod)
        external
        restricted
    {
        require(_claimUnlockPeriod <= 2 days, '!claimUnlockPeriod');
        claimUnlockPeriod = _claimUnlockPeriod;
    }

    function setStakingPool(address stakingPool_)
        external
        restricted
    {
        require(stakingPool_ != address(0), '!stakingPool');
        _stakingPool = stakingPool_;
    }

    function notifyRewardAmount(uint256 reward)
        external
        restricted
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(
            rewardRate <= balance.div(rewardsDuration),
            "Provided reward too high"
        );

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverBEP20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        // Cannot recover the staking token or the rewards token
        require(
            tokenAddress != address(stakingToken) &&
                tokenAddress != address(rewardsToken),
            "Cannot withdraw the staking or rewards tokens"
        );
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external restricted {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    // *** MODIFIERS ***

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    modifier restricted {
        require(
            msg.sender == owner(),
            '!restricted'
        );

        _;
    }

    // EVENTS

    event RewardAdded(uint256 reward);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event ClaimRequested(address indexed user, uint256 amount, uint256 timestamp);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}