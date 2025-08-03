// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;
// External
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
using StateLibrary for IPoolManager;


// Internal
import "contracts/SimpleCampaign.sol";
import "contracts/TokenCampaign.sol";



/**
 * @title Block Fund
 * @dev Has the ability to create campaigns which accepts donations
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts

 */
contract BlockFund {

    mapping(Currency => PoolId) token_pools;
    address public owner;
    IPoolManager public immutable pool_manager;


    enum CampaignType {
        SIMPLE,
        TOKEN
    }

    event createdCampaign(address, CampaignType);

    modifier onlyOwner() {
        require(msg.sender == owner, "This function is only accessible by the owner");
        _;
    }

    constructor(address _owner, IPoolManager _pool_manager) {
        pool_manager = _pool_manager;
        owner = _owner;
    }


    function addTokenPool(PoolId _pool, Currency _currency) public onlyOwner {
        token_pools[_currency] = _pool;
        pool_manager.getSlot0(_pool);
    }

    function changeOwner(address _new_owner) public onlyOwner {
        owner = _new_owner;
    }
    
    function createSimpleCampaign(address payable campaign_owner, uint256 campaign_goal_wei) public returns (address) {
        SimpleCampaign new_campaign = new SimpleCampaign(campaign_owner, campaign_goal_wei);
        emit createdCampaign(address(new_campaign), CampaignType.SIMPLE);
        return address(new_campaign);
    }

    function createTokenCampaign(address campaign_owner, IERC20 token, uint256 campaign_goal) public returns (address) {
        TokenCampaign new_campaign = new TokenCampaign(campaign_owner, token, campaign_goal);
        emit createdCampaign(address(new_campaign), CampaignType.TOKEN);
        return address(new_campaign);
    }

    function createMixedCampaign(address campaign_owner, IERC20 token, uint256 campaign_goal) public returns (address) {
        TokenCampaign new_campaign = new TokenCampaign(campaign_owner, token, campaign_goal);
        emit createdCampaign(address(new_campaign), CampaignType.TOKEN);
        return address(new_campaign);
    }
}
