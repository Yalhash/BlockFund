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
 * Payouts are pulled, not pushed: settling only records the outcome, then the owner calls
 * `claimFunds(to)`. Refunds work the same way with `withdrawDonation(to)`. Both send to an
 * address the caller chooses, so a recipient that can't accept ETH (e.g. a contract
 * without `receive`) or a blacklisted token holder can't block the campaign.
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
    event DonationRefunded(address indexed donor, address indexed asset, uint256 amount, address to);
    event FundsClaimed(address indexed to, address indexed asset, uint256 amount);
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
    error NotSettled();
    error NothingToClaim();
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

    /// @notice Marks a successful campaign as settled; the funds then belong to the owner,
    ///         who collects them with `claimFunds`. Owner-only before the deadline, anyone after.
    function settleCampaign() external nonReentrant {
        if (state != State.Active) revert NotActive();
        if (block.timestamp < deadline && msg.sender != owner) revert OnlyOwnerBeforeDeadline();
        if (!goalReached()) revert GoalNotReached();

        state = State.Settled;
        emit CampaignSettled(msg.sender);
    }

    /// @notice Sends all raised funds to `to`, which can be any address the owner chooses.
    function claimFunds(address payable to) external onlyOwner nonReentrant {
        if (state != State.Settled) revert NotSettled();
        if (to == address(0)) revert ZeroAddress();
        _payOut(to);
    }

    /// @notice Cancels the campaign and opens refunds.
    function abortCampaign() external onlyOwner {
        if (state != State.Active) revert NotActive();
        state = State.Refunding;
        emit RefundsOpened(msg.sender);
    }

    /// @notice Sends all of the caller's donations to `to` (usually the caller's own address).
    ///         Available after an abort, or once the deadline has passed without the goal
    ///         being reached.
    function withdrawDonation(address payable to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (state == State.Active) {
            if (block.timestamp < deadline || _goalReachedForRefunds()) revert RefundsNotOpen();
            state = State.Refunding;
            emit RefundsOpened(msg.sender);
        } else if (state != State.Refunding) {
            revert RefundsNotOpen();
        }
        _refund(msg.sender, to);
    }

    // ---------------------------------------------------------------------
    // Hooks for child contracts
    // ---------------------------------------------------------------------

    /// @dev Used when deciding whether refunds may open. Override if `totalRaised` can
    ///      revert (e.g. an oracle outage), so donors are never locked out.
    function _goalReachedForRefunds() internal view virtual returns (bool) {
        return goalReached();
    }

    /// @dev Send all unclaimed raised funds to `to`, zeroing balances before transferring.
    ///      Must revert with NothingToClaim if there is nothing left. State is Settled.
    function _payOut(address payable to) internal virtual;

    /// @dev Send all of `donor`'s donations to `to`, zeroing balances before transferring.
    ///      Must revert with NothingToRefund if there is nothing to return.
    function _refund(address donor, address payable to) internal virtual;

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
