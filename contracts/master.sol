// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libs/bep20.sol";
import "./libs/enumerable-set.sol";
import "./libs/safe-math.sol";
import "./libs/ownable.sol";
import "./libs/pausable.sol";
import "./libs/reentrancy-guard.sol";

import "./token.sol";

contract TuttiFruttiMaster is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 pendingRewards; // Pending rewards for user.
        uint256 depositedAt; // Time of deposit for user.
        uint256 claimAmount; // Claim amount of tokens for user.
        uint256 claimTimestamp; // Time of claim of the user.
        uint256 lockedAmount; // Locked amount of tokens for user.
    }

    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. TFFs to distribute per block.
        uint256 lastRewardBlock; // Last block number that TFFs distribution occurs.
        uint256 accTffPerShare; // Accumulated TFFs per share, times 1e12. See below.
        uint256 totalDeposited; // Total deposited amount in pool.
        uint256 totalLocked; // Total amount of tokens locked in the pool.
    }

    // TFF token
    TuttiFruttiFinance public tff;

    // Project addresses
    address public treasury = address(0x968c7Fc2E1651C088704c77A6D5DcCe4c3B023bf);
    address public rewards = address(0x2439047Fa09b97Acf0B1c64a0d1C653E939C3e03);
    address public fund = address(0);

    // Early withdrawal fees
    uint256 public earlyFee = 20;
    uint256 public normalFee = 2;
    uint256 public treasuryFee = 50;
    uint256 public rewardsFee = 25;
    uint256 public baseFee = 100;

    uint256 private maxEarlyFee = 20;
    uint256 private maxNormalFee = 5;

    uint256 public penaltyPeriod = 7 days;
    uint256 public unlockPeriod = 24 hours;

    // TFF tokens created per block.
    uint256 public tffPerBlock;

    // The total amount of rewards the master contract will distribute
    uint256 public rewardsAmount = 285000000000000000000000000;

    // The amount of rewards the master contract has already distributed
    uint256 public distributedRewardsAmount = 0;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Info for each user about amount in retirement fund.
    mapping(address => uint256) public fundInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when TFF mining starts.
    uint256 public startBlock;
    // End of distribution
    uint256 public ended;

    // Events
    event Recovered(address token, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Locked(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 amount);
    event PendingClaim(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimCollected(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimCancelled(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimAndStake(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event IntParameterChanged(string parameter, uint256 value);
    event AddressParameterChanged(string parameter, address target);
    event Ended();
    event Dusted();
    event Saved();

    constructor(
        TuttiFruttiFinance _tff,
        uint256 _tffPerBlock,
        uint256 _startBlock
    ) public {
        tff = _tff;
        tffPerBlock = _tffPerBlock;
        startBlock = _startBlock;

        poolInfo.push(PoolInfo({
            lpToken: _tff,
            allocPoint: 10000,
            lastRewardBlock: startBlock,
            accTffPerShare: 0,
            totalDeposited: 0,
            totalLocked: 0
        }));

        totalAllocPoint = 10000;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (distributedRewardsAmount >= rewardsAmount) {
            return 0;
        }
        return _to.sub(_from);
    }

    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accTffPerShare: 0,
                totalDeposited: 0,
                totalLocked: 0
            })
        );
        updateStakingPool();
    }

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(4);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    function pendingTff(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTffPerShare = pool.accTffPerShare;
        if (block.number > pool.lastRewardBlock && pool.totalDeposited != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 tffReward = multiplier
                .mul(tffPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accTffPerShare = accTffPerShare.add(
                tffReward.mul(1e12).div(pool.totalDeposited)
            );
        }
        return
            user.amount.mul(accTffPerShare).div(1e12).sub(user.rewardDebt).add(user.pendingRewards);
    }

    function available(address account)
        external
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[0][account];
        return user.amount.sub(fundInfo[account]);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.totalDeposited == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tffReward = multiplier
            .mul(tffPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
        distributedRewardsAmount = distributedRewardsAmount.add(tffReward);
        pool.accTffPerShare = pool.accTffPerShare.add(
            tffReward.mul(1e12).div(pool.totalDeposited)
        );
        pool.lastRewardBlock = block.number;
    }

    function deposit(uint256 _pid, uint256 _amount) public nonReentrant notPaused {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accTffPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            
            if (pending > 0) {
                user.pendingRewards = user.pendingRewards.add(pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            pool.totalDeposited = pool.totalDeposited.add(_amount);
            user.amount = user.amount.add(_amount);
            user.depositedAt = block.timestamp;
        }
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        require (_pid != 0, '!w-tff');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount.sub(user.lockedAmount) >= _amount, "!w-invalid");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalDeposited = pool.totalDeposited.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function unstake(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(fundInfo[msg.sender].add(user.lockedAmount) <= user.amount, '!w');
        require(user.amount.sub(fundInfo[msg.sender]).sub(user.lockedAmount) >= _amount, "!w-invalid");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalDeposited = pool.totalDeposited.sub(_amount);

            uint256 _total;
            if (block.timestamp >= user.depositedAt.add(penaltyPeriod)) {
                _total = _amount.mul(normalFee).div(baseFee);
            } else {
                _total = _amount.mul(earlyFee).div(baseFee);
            }

            pool.lpToken.safeTransfer(address(msg.sender), _amount.sub(_total));

            if (_total > 0) {
                uint256 _treasury = _total.mul(treasuryFee).div(baseFee); 
                uint256 _rewards = _total.mul(rewardsFee).div(baseFee);
                uint256 _burn = _total.sub(_treasury).sub(_rewards);
                pool.lpToken.safeTransfer(treasury, _treasury);
                pool.lpToken.safeTransfer(rewards, _rewards);
                tff.burn(_burn);
            }
        }

        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
        emit Withdraw(msg.sender, 0, _amount);
    }

    function lock(address account, uint256 _amount) public onlyFund {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][account];
        require(user.amount.sub(fundInfo[account]) >= _amount, "!lock");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        fundInfo[account] = fundInfo[account].add(_amount);

        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
        emit Locked(account, _amount);
    }

    function unlock(address account, uint256 _amount) public onlyFund {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][account];
        require(fundInfo[account] >= _amount, "!unlock");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        fundInfo[account] = fundInfo[account].sub(_amount);

        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
        emit Unlocked(account, _amount);
    }

    function emergency(uint256 _pid) public nonReentrant {
        require (_pid != 0, '!w-unstake');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function claimRewards(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require (user.claimAmount == 0, '!cl');
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0 || user.pendingRewards > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
            uint256 claimAmount = user.pendingRewards;
            emit PendingClaim(msg.sender, _pid, user.pendingRewards);
            user.pendingRewards = 0;
            user.claimAmount = claimAmount;
            user.claimTimestamp = block.timestamp;
            user.lockedAmount = user.amount;
            pool.totalLocked = pool.totalLocked.add(user.amount);
            pool.totalDeposited = pool.totalDeposited.sub(user.amount);
            user.amount = 0;
        }
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
    }

    function collectClaim(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require (user.claimAmount > 0, '!no-claim');
        require (block.timestamp >= user.claimTimestamp.add(unlockPeriod), '!claim-period');
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        uint256 amount = user.claimAmount;
        user.claimAmount = 0;
        user.amount = user.amount.add(user.lockedAmount);
        pool.totalDeposited = pool.totalDeposited.add(user.lockedAmount);
        pool.totalLocked = pool.totalLocked.sub(user.lockedAmount);
        user.lockedAmount = 0;
        user.claimTimestamp = 0;
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
        safeTffTransfer(msg.sender, amount);
        emit ClaimCollected(msg.sender, _pid, amount);
    }

    function cancelClaim(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require (user.claimAmount > 0, '!no-claim');
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        uint256 amount = user.claimAmount;
        user.claimAmount = 0;
        user.amount = user.amount.add(user.lockedAmount);
        pool.totalDeposited = pool.totalDeposited.add(user.lockedAmount);
        pool.totalLocked = pool.totalLocked.sub(user.lockedAmount);
        user.lockedAmount = 0;
        user.claimTimestamp = 0;

        emit ClaimCancelled(msg.sender, _pid, amount);
        user.pendingRewards = user.pendingRewards.add(amount);
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
    }

    function stakeRewards(uint256 _pid) public notPaused {
        require (_pid != 0, '!stake-tff');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0 || user.pendingRewards > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
            transferToStake(user.pendingRewards);
            emit ClaimAndStake(msg.sender, _pid, user.pendingRewards);
            user.pendingRewards = 0;
        }
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);
    }

    function transferToStake(uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                user.pendingRewards = user.pendingRewards.add(pending);
            }
        }
        if (_amount > 0) {
            user.amount = user.amount.add(_amount);
            pool.totalDeposited = pool.totalDeposited.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);

        emit Deposit(msg.sender, 0, _amount);
    }

    function restake() public notPaused {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        uint256 rewardsToStake;
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accTffPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                user.pendingRewards = user.pendingRewards.add(pending);
            }
        }
        if (user.pendingRewards > 0) {
            rewardsToStake = user.pendingRewards;
            user.pendingRewards = 0;
            user.amount = user.amount.add(rewardsToStake);
            pool.totalDeposited = pool.totalDeposited.add(rewardsToStake);
        }
        user.rewardDebt = user.amount.mul(pool.accTffPerShare).div(1e12);

        emit Deposit(msg.sender, 0, rewardsToStake);
    }

    function safeTffTransfer(address _to, uint256 _amount) internal {
        uint256 tffBal = tff.balanceOf(address(this));
        if (_amount > tffBal) {
            IBEP20(tff).safeTransfer(_to, tffBal);
        } else {
            IBEP20(tff).safeTransfer(_to, _amount);
        }
    }

    // **** RESTRICTED ****

    function setTffPerBlock(uint256 _tffPerBlock) public onlyOwner {
        require(_tffPerBlock > 0, "!null");
        tffPerBlock = _tffPerBlock;
        emit IntParameterChanged('tffPerBlock', tffPerBlock);
    }

    function setWithdrawalFees(uint256 _early, uint256 _normal) external onlyOwner {
        require(_early <= maxEarlyFee && _normal <= maxNormalFee, '!fee');
        earlyFee = _early;
        normalFee = _normal;
        emit IntParameterChanged('earlyFee', earlyFee);
        emit IntParameterChanged('normalFee', normalFee);
    }

    function setFees(uint256 _treasuryFee, uint256 _rewardsFee) external onlyOwner {
        require(_treasuryFee.add(_rewardsFee) <= baseFee, '!fee');
        treasuryFee = _treasuryFee;
        rewardsFee = _rewardsFee;
        emit IntParameterChanged('treasuryFee', treasuryFee);
        emit IntParameterChanged('rewardsFee', rewardsFee);
    }

    function setPeriods(uint256 _unlockPeriod, uint256 _penaltyPeriod) external onlyOwner {
        require(_unlockPeriod <= 2 days && _penaltyPeriod <= 4 weeks, '!period');
        unlockPeriod = _unlockPeriod;
        penaltyPeriod = _penaltyPeriod;
        emit IntParameterChanged('unlockPeriod', unlockPeriod);
        emit IntParameterChanged('penaltyPeriod', penaltyPeriod);
    }

    function setTreasury(address _treasury) external {
        require(msg.sender == treasury, '!treasury');
        treasury = _treasury;
        emit AddressParameterChanged('treasury', treasury);
    }

    function setRewards(address _rewards) external {
        require(msg.sender == rewards, '!rewards');
        rewards = _rewards;
        emit AddressParameterChanged('rewards', rewards);
    }

    function setFund(address _fund) external onlyOwner {
        require(fund == address(0), '!fund');
        fund = _fund;
        emit AddressParameterChanged('fund', fund);
    }

    function end() external onlyOwner {
        require(ended == 0, '!ended');
        if (distributedRewardsAmount >= rewardsAmount) {
            setPaused(true);
            ended = block.timestamp;
        }
        emit Ended();
    }

    function dust() external onlyOwner {
        require(ended != 0, '!ended');
        require(block.timestamp >= ended.add(30 days), '!grace');
        uint256 balance = tff.balanceOf(address(this));
        if (balance > 0) {
            safeTffTransfer(msg.sender, balance);
        }
        emit Dusted();
    }

    function save() external onlyOwner {
        require(block.number <= startBlock.add(57600), '!2late');
        setPaused(true);
        uint256 balance = tff.balanceOf(address(this));
        if (balance > 0) {
            safeTffTransfer(msg.sender, balance);
        }
        emit Saved();
    }

    // *** MODIFIERS **** //

    modifier onlyFund {
        require(
            msg.sender == fund,
            '!fund'
        );

        _;
    }
}
