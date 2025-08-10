// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
using StateLibrary for IPoolManager;

/**
 * @title Mixed Campaign
 * @dev A simple campaign which accepts donations of an ERC20 token as well as .
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts
 */



contract MixedCampaign {
    address payable public immutable owner;
    IPoolManager public immutable pool_manager;
    PoolId public immutable uni_pool;
    IERC20 public immutable token;
    uint256 public immutable goal;

    uint256 collected;
    uint256 token_collected;
    bool active;
    mapping(address => uint256) refund_mapping;
    mapping(address => uint256) token_refund_mapping;


    event DonationRecieved(address donator, uint256 amount);
    event DonationRefunded(address donator, uint256 amount);

    constructor(address payable _owner, IPoolManager _pool_manager, PoolId _uni_pool, address _token, uint256 _goal_wei) {
        owner = _owner;
        pool_manager = _pool_manager;
        uni_pool = _uni_pool;
        token = IERC20(_token);
        goal = _goal_wei;
        active = true;
        collected = 0;
        token_collected = 0;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "This function is only accessible by the owner");
        _;
    }

    modifier onlyActiveCampaign() {
        require (active, "This function can only be accessed while a campaign is active");
        _;
    }

    // This function expects the contract to have been approved for the amount donated already
    function donate_token(uint256 amount) public onlyActiveCampaign {
        token_collected += amount;
        token_refund_mapping[msg.sender] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "Failed to recieve donation, transfer failed");
        emit DonationRecieved(msg.sender, amount);
    }
    
    function donate_eth() public payable onlyActiveCampaign {
        require(msg.value > 0, "Must include a donation");
        collected += msg.value;
        refund_mapping[msg.sender] += msg.value;
        emit DonationRecieved(msg.sender, msg.value);
    }

    
    function get_token_amount_in_eth(uint256 amount) private view returns (uint256) {
        (uint160 sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _lpFee) = pool_manager.getSlot0(uni_pool);
        // sqrtPriceX96 is an encoded value of Token1 in per Token0
        // Token0 is always eth since it is native, and so the lower stored value in the pool
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        return amount * price;
    }

    // On settling the campaign the total amount needs to be calculated based on the current token price.
    function settleCampaign() public onlyOwner onlyActiveCampaign {
        uint256 wei_collected = collected + get_token_amount_in_eth(token_collected);

        require(wei_collected >= goal, "The campaign goal has not been reached yet.");
        active = false;
        uint256 token_amount_to_send = token_collected;
        token_collected = 0;
        uint256 amount_to_send = collected;
        collected = 0;
        require(token.transfer(owner, token_amount_to_send), "Failed to settle campaign, transfer failed");
        owner.transfer(amount_to_send);
    }

    function withdrawDonation() public {
        require(!active, "The campaign must be aborted to allow refunds");
        uint256 refund_amount = refund_mapping[msg.sender];
        refund_mapping[msg.sender] = 0;
        collected -= refund_amount;        
        require(token.transfer(msg.sender, refund_amount), "Failed to refund donation, transfer failed");
        emit DonationRefunded(msg.sender, refund_amount);
    }

    // Abort the campaign early, donators can still withdraw their donations
    function abortCampaign() public onlyOwner {
        active = false;
    }
}