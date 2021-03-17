// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libs/reentrancy-guard.sol";
import "./libs/pausable.sol";
import "./libs/bep20.sol";
import "./libs/safe-math.sol";

import "./interfaces/master.sol";

contract TffRetirementFund is ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // STATE VARIABLES

    IMaster public master;

    IBEP20 public rewardsToken;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 2630000; // 1 month
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    uint256 private _totalDeposited;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _deposits;
    mapping(address => uint256) private _periods;
    mapping(address => uint256) private _locks;

    uint256 private minimumLock = 2 weeks;
    uint256 private maximumLock = 4 weeks;

    uint256 public multiplier = 10; // 10 %
    uint256 private constant multiplierBase = 100;

    // CONSTRUCTOR

    constructor(
        address _rewardsToken,
        address _master
    ) public {
        rewardsToken = IBEP20(_rewardsToken);
        master = IMaster(_master);
    }

    // VIEWS

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function totalDeposited() external view returns (uint256) {
        return _totalDeposited;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function depositOf(address account) external view returns (uint256) {
        return _deposits[account];
    }

    function unlockedAt(address account) external view returns (uint256) {
        return _locks[account];
    }

    function lockedFor(address account) external view returns (uint256) {
        return _periods[account];
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

    function stake(uint256 amount, uint256 lockPeriod)
        external
        nonReentrant
        notPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "!stake-0");
        require(lockPeriod >= minimumLock, "!stake-<2weeks");
        require(master.availableForRetirementFund(msg.sender) >= amount, '!stake-funds');

        if (_deposits[msg.sender] > 0) {
            require(lockPeriod >= _periods[msg.sender], "!stake-lock");
        }

        if (lockPeriod > maximumLock) {
            lockPeriod = maximumLock;
        }

        // lock amount in master contract
        master.lock(msg.sender, amount);

        // add already deposited amount to current deposit
        uint256 total = _deposits[msg.sender].add(amount);
        uint256 shares = 0;

        // calculate multiplier: (lock weeks - two weeks) / 1 week + add base
        uint256 lockMultiplier = ((lockPeriod - minimumLock).div(1 weeks)).mul(multiplier).add(multiplierBase);

        // calculate shares: total deposited amount * multiplier / base
        shares = total.mul(lockMultiplier).div(multiplierBase);

        // update all balances
        _deposits[msg.sender] = total;
        _totalDeposited = _totalDeposited.add(amount);

        _totalSupply = _totalSupply.sub(_balances[msg.sender]);
        _balances[msg.sender] = shares;
        _totalSupply = _totalSupply.add(shares);

        _periods[msg.sender] = lockPeriod;
        _locks[msg.sender] = block.timestamp.add(lockPeriod);
        emit Staked(msg.sender, amount, lockPeriod);
    }

    function extend(uint256 lockPeriod)
        external
        nonReentrant
        updateReward(msg.sender)
    {
        require(_deposits[msg.sender] > 0, "!extend-nostake");
        require(lockPeriod > _periods[msg.sender], "!extend-lowerlock");

        if (lockPeriod > maximumLock) {
            lockPeriod = maximumLock;
        }

        uint256 shares = 0;

        // calculate multiplier: (lock weeks - two weeks) / 1 week + add base
        uint256 lockMultiplier = ((lockPeriod - minimumLock).div(1 weeks)).mul(multiplier).add(multiplierBase);

        // calculate shares: total deposited amount * multiplier / base
        shares = _deposits[msg.sender].mul(lockMultiplier).div(multiplierBase);

        _totalSupply = _totalSupply.sub(_balances[msg.sender]);
        _balances[msg.sender] = shares;
        _totalSupply = _totalSupply.add(shares);

        emit Extended(msg.sender, _periods[msg.sender], lockPeriod);
        _periods[msg.sender] = lockPeriod;
        _locks[msg.sender] = block.timestamp.add(lockPeriod);
    }

    function withdraw(uint256 amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "!withdraw-0");
        require(_deposits[msg.sender] > 0, "!withdraw-nostake");
        require(block.timestamp >= _locks[msg.sender], "!withdraw-lock");

        // Calculate percentage of principal being withdrawn
        uint256 percentage = (amount.mul(1e18).div(_deposits[msg.sender]));

        // Calculate amount of shares to be removed
        uint256 shares = _balances[msg.sender].mul(percentage).div(1e18);

        _deposits[msg.sender] = _deposits[msg.sender].sub(amount);
        _totalDeposited = _totalDeposited.sub(amount);

        _balances[msg.sender] = _balances[msg.sender].sub(shares);
        _totalSupply = _totalSupply.sub(shares);

        master.unlock(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_deposits[msg.sender]);
        getReward();
    }

    // RESTRICTED FUNCTIONS

    function setMaster(address _master)
        external
        restricted
    {
        master = IMaster(_master);
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

    function setLockingPeriods(uint256 _minimumLock, uint256 _maximumLock) external restricted {
        require(
            _maximumLock <= 12 weeks,
            '!maximumLock'
        );
        require(
            _minimumLock < _maximumLock,
            '!minLock>maxLock'
        );
        minimumLock = _minimumLock;
        maximumLock = _maximumLock;
    }

    function setMultiplier(uint256 _multiplier) external restricted {
        multiplier = _multiplier;
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
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod);
    event Extended(address indexed user, uint256 oldPeriod, uint256 newPeriod);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}