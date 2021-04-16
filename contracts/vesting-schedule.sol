// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libs/BEP20.sol";
import "./libs/safe-math.sol";
import "./libs/ownable.sol";

/**
 * @dev A token holder contract that will allow a beneficiary to extract the
 * tokens after a given release time.
 *
 * Useful for simple vesting schedules like "advisors get all of their tokens
 * after 1 year".
 */
contract TffVestingSchedule is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // BEP20 basic token contract being held
    IBEP20 private _token;

    // presale contract that will set the token
    address private _presale;

    // beneficiaries of tokens after they are released
    address[] private _beneficiaries;

    // timestamp when token release is enabled
    uint256 private _releaseTime;

    // minimum release time
    uint256 private _minReleaseTime = 365 days;

    constructor (address[] memory beneficiaries_, uint256 releaseTime_) public {
        // solhint-disable-next-line not-rely-on-time
        require(releaseTime_ > block.timestamp, "VestingSchedule: release time is before current time");
        require(releaseTime_ > block.timestamp.add(_minReleaseTime), "VestingSchedule: release time below minimum");
        _beneficiaries = beneficiaries_;
        _releaseTime = releaseTime_;
    }

    /**
     * @return the token being held.
     */
    function token() public view returns (IBEP20) {
        return _token;
    }

    /**
     * @return the beneficiary of the tokens.
     */
    function beneficiaries() public view returns (address[] memory) {
        return _beneficiaries;
    }

    /**
     * @return the time when the tokens are released.
     */
    function releaseTime() public view returns (uint256) {
        return _releaseTime;
    }

    /**
     * @notice Set the token held by the timelock.
     */
    function set_token(address token_) public restricted {
        require(address(_token) == address(0), '!VestingSchedule: token already set');
        _token = IBEP20(token_);
    }

    /**
     * @notice Transfers tokens held by timelock to beneficiary.
     */
    function release() public virtual {
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp >= _releaseTime, "VestingSchedule: current time is before release time");

        uint256 amount = _token.balanceOf(address(this));
        require(amount > 0, "VestingSchedule: no tokens to release");

        uint256 _beneficiary = amount.div(_beneficiaries.length);
        for (uint256 index = 0; index < _beneficiaries.length; index++) {
            _token.safeTransfer(_beneficiaries[index], _beneficiary);
        }
    }

    // *** MODIFIERS ***

    modifier restricted {
        require(
            msg.sender == owner(),
            '!restricted'
        );

        _;
    }
}