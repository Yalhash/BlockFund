// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Campaign base
 * @notice Shared all-or-nothing lifecycle for every campaign type.
 *
 *  - Donations are accepted while the campaign is Active and before `deadline`.
 *  - Once the goal is reached, the owner can settle at any time. After the deadline,
 *    anyone can settle a campaign that reached its goal (so funds can't sit idle).
 *  - If the deadline passes without reaching the goal, or the owner aborts, refunds open
 *    and each donor withdraws their own donation.
 *  - The first settle or refund decides the outcome: the state never changes again,
 *    so a later price swing can't flip a campaign that is already refunding.
 *
 * Children define what counts toward the goal (`totalRaised`) and how assets move.
 */
abstract contract CampaignBase is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        Active,
        Settled,
        Refunding
    }

    uint256 public constant MAX_DURATION = 365 days;

    /// @dev Asset id used in events for native ETH.
    address internal constant ETH = address(0);

    address payable public immutable owner;
    uint256 public immutable goal;
    uint256 public immutable deadline;
    State public state;

    event DonationReceived(address indexed donor, address indexed asset, uint256 amount);
    event DonationRefunded(address indexed donor, address indexed asset, uint256 amount);
    event CampaignSettled(address indexed caller);
    event RefundsOpened(address indexed caller);

    error ZeroAddress();
    error ZeroGoal();
    error InvalidDeadline();
    error OnlyOwner();
    error NotActive();
    error DonationsClosed();
    error ZeroDonation();
    error GoalNotReached();
    error OnlyOwnerBeforeDeadline();
    error RefundsNotOpen();
    error NothingToRefund();
    error EthTransferFailed();

    constructor(address payable owner_, uint256 goal_, uint256 deadline_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp || deadline_ > block.timestamp + MAX_DURATION) revert InvalidDeadline();
        owner = owner_;
        goal = goal_;
        deadline = deadline_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier acceptingDonations() {
        if (state != State.Active || block.timestamp >= deadline) revert DonationsClosed();
        _;
    }

    /// @notice Amount raised so far, in the same unit as `goal`.
    function totalRaised() public view virtual returns (uint256);

    function goalReached() public view returns (bool) {
        return totalRaised() >= goal;
    }

    /// @notice Pays out to the owner. Owner-only before the deadline, anyone after it.
    function settleCampaign() external nonReentrant {
        if (state != State.Active) revert NotActive();
        if (block.timestamp < deadline && msg.sender != owner) revert OnlyOwnerBeforeDeadline();
        if (!goalReached()) revert GoalNotReached();

        state = State.Settled;
        emit CampaignSettled(msg.sender);
        _payOwner();
    }

    /// @notice Cancels the campaign and opens refunds.
    function abortCampaign() external onlyOwner {
        if (state != State.Active) revert NotActive();
        state = State.Refunding;
        emit RefundsOpened(msg.sender);
    }

    /// @notice Returns all of the caller's donations. Available after an abort, or once the
    ///         deadline has passed without the goal being reached.
    function withdrawDonation() external nonReentrant {
        if (state == State.Active) {
            if (block.timestamp < deadline || _goalReachedForRefunds()) revert RefundsNotOpen();
            state = State.Refunding;
            emit RefundsOpened(msg.sender);
        } else if (state != State.Refunding) {
            revert RefundsNotOpen();
        }
        _refund(payable(msg.sender));
    }

    // ---------------------------------------------------------------------
    // Hooks for child contracts
    // ---------------------------------------------------------------------

    /// @dev Used when deciding whether refunds may open. Override if `totalRaised` can
    ///      revert (e.g. an oracle outage), so donors are never locked out.
    function _goalReachedForRefunds() internal view virtual returns (bool) {
        return goalReached();
    }

    /// @dev Send all raised funds to `owner`. State is already Settled.
    function _payOwner() internal virtual;

    /// @dev Return all of `donor`'s donations, zeroing balances before transferring.
    ///      Must revert with NothingToRefund if there is nothing to return.
    function _refund(address payable donor) internal virtual;

    // ---------------------------------------------------------------------
    // Asset helpers
    // ---------------------------------------------------------------------

    function _sendEth(address payable to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Pulls `amount` from msg.sender (requires prior approval) and returns what actually
    ///      arrived, so fee-on-transfer tokens are credited correctly.
    function _pullToken(IERC20 token, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroDonation();
    }

    function _sendToken(IERC20 token, address to, uint256 amount) internal {
        token.safeTransfer(to, amount);
    }
}
