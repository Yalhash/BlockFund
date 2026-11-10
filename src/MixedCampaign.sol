// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignBase} from "./CampaignBase.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title Mixed Campaign
 * @notice Accepts ETH and one ERC-20 token. `goal` is in wei; token donations are valued
 *         in wei by a manipulation-resistant `IPriceOracle` (Chainlink / TWAP), never by a
 *         pool's spot price.
 * @dev ETH and token balances are tracked separately and refunded in the asset donated.
 */
contract MixedCampaign is CampaignBase {
    IERC20 public immutable token;
    IPriceOracle public immutable oracle;

    uint256 public ethCollected;
    uint256 public tokenCollected;
    mapping(address donor => uint256 amount) public ethDonations;
    mapping(address donor => uint256 amount) public tokenDonations;

    error UnsupportedToken(address token);

    constructor(address payable owner_, IERC20 token_, IPriceOracle oracle_, uint256 goalWei, uint256 deadline_)
        CampaignBase(owner_, goalWei, deadline_)
    {
        if (address(token_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        if (!oracle_.isSupported(address(token_))) revert UnsupportedToken(address(token_));
        token = token_;
        oracle = oracle_;
    }

    function donateEth() external payable nonReentrant acceptingDonations {
        if (msg.value == 0) revert ZeroDonation();
        ethCollected += msg.value;
        ethDonations[msg.sender] += msg.value;
        emit DonationReceived(msg.sender, ETH, msg.value);
    }

    /// @dev Requires `token.approve(address(this), amount)` first.
    function donateToken(uint256 amount) external nonReentrant acceptingDonations {
        if (amount == 0) revert ZeroDonation();
        uint256 received = _pullToken(token, amount);
        tokenCollected += received;
        tokenDonations[msg.sender] += received;
        emit DonationReceived(msg.sender, address(token), received);
    }

    /// @notice ETH raised plus the oracle's wei value of the tokens raised.
    function totalRaised() public view override returns (uint256) {
        return ethCollected + oracle.valueInWei(address(token), tokenCollected);
    }

    /// @dev If the oracle can't price the token, treat the goal as not reached so donors can
    ///      still get refunds after the deadline. (Settling still requires a working price.)
    function _goalReachedForRefunds() internal view override returns (bool) {
        try this.totalRaised() returns (uint256 raised) {
            return raised >= goal;
        } catch {
            return false;
        }
    }

    function _payOwner() internal override {
        uint256 tokenAmount = tokenCollected;
        uint256 ethAmount = ethCollected;
        tokenCollected = 0;
        ethCollected = 0;

        if (tokenAmount > 0) _sendToken(token, owner, tokenAmount);
        if (ethAmount > 0) _sendEth(owner, ethAmount);
    }

    function _refund(address payable donor) internal override {
        uint256 ethAmount = ethDonations[donor];
        uint256 tokenAmount = tokenDonations[donor];
        if (ethAmount == 0 && tokenAmount == 0) revert NothingToRefund();

        // Effects before interactions
        ethDonations[donor] = 0;
        tokenDonations[donor] = 0;
        ethCollected -= ethAmount;
        tokenCollected -= tokenAmount;

        if (tokenAmount > 0) {
            emit DonationRefunded(donor, address(token), tokenAmount);
            _sendToken(token, donor, tokenAmount);
        }
        if (ethAmount > 0) {
            emit DonationRefunded(donor, ETH, ethAmount);
            _sendEth(donor, ethAmount);
        }
    }
}
