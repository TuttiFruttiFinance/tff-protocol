// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./master.sol";

contract TffController is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    TuttiFruttiMaster public master = TuttiFruttiMaster(0x554e44DEb162585A7234FD53E682192e66c42280);

    // POOL FUNCTIONS

    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        bool _withUpdate
    ) external onlyOwner {
        master.add(_allocPoint, _lpToken, _withUpdate);
    }

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) external onlyOwner {
        master.set(_pid, _allocPoint, _withUpdate);
    }

    // PARAMETER FUNCTIONS

    function setTffPerBlock(
        uint256 _tffPerBlock
    ) external onlyOwner {
        master.setTffPerBlock(_tffPerBlock);
    }

    function setWithdrawalFees(
        uint256 _early, 
        uint256 _normal
    ) external onlyOwner {
        master.setWithdrawalFees(_early, _normal);
    }

    function setFees(
        uint256 _treasuryFee, 
        uint256 _rewardsFee
    ) external onlyOwner {
        master.setFees(_treasuryFee, _rewardsFee);
    }

    function setPeriods(
        uint256 _unlockPeriod, 
        uint256 _penaltyPeriod
    ) external onlyOwner {
        master.setPeriods(_unlockPeriod, _penaltyPeriod);
    }

    function setFund(
        address _fund
    ) external onlyOwner {
        master.setFund(_fund);
    }

    function end() 
    external onlyOwner {
        master.end();
    }

    function dust()
    external onlyOwner {
        master.dust();
    }

    // OWNER FUNCTIONS

    function setPaused(
        bool _paused
    )
    external onlyOwner {
        master.setPaused(_paused);
    }

    function revoke()
    external onlyOwner {
        master.renounceOwnership();
    }
}