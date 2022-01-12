// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import './interfaces/IInvite.sol';
import './interfaces/IPartner.sol';

contract FeeCallee{
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public factory;
    mapping(address => bool) public whitelist;
    address public inviteAddress;
    address public partnerAddress;
    address public _burnTo = 0x0000000000000000000000000000000000000001;
    address public groupFeeTo;
    address public settleToken;
    struct Income {
        // 1
        uint attrsAmount;
        uint attrsWithdrawAmount;
        // 2
        uint heroAmount;
        uint heroWithdrawAmount;
        // -
        uint partnerAmount;
        uint partnerWithdrawAmount;
        // 3
        uint boxAmount;
        uint boxWithdrawAmount;
        // 4
        uint marketAmount;
        uint marketWithdrawAmount;
        // 5
        uint pledgeAmount;
        uint pledgeWithdrawAmount;
    }
    struct GroupIncome {
        // 1
        uint attrsAmount;
        uint attrsWithdrawAmount;
    }
    mapping(address => Income) public totalIncome; // 佣金总额记录
    mapping(address => GroupIncome) public groupIncome;

    event Log(uint256);

    constructor() {
        factory = msg.sender;
    }

    function feeCall(address from, uint amount, uint typeValue) external returns(bool){
        require(whitelist[msg.sender], 'Tip: 0001');
        require(inviteAddress != address(0), 'Tip: 1000');
        require(partnerAddress != address(0), 'Tip: 1001');
        address[2] memory parents = IInvite(inviteAddress).getParents(from);
        address[2] memory partners = IPartner(partnerAddress).getPartners(from);
        if(typeValue == 1){
            // 生成属性收费
            attrsFee(amount, parents, partners);
        } else if(typeValue == 2){
            // 铸造英雄收费
            heroFee(amount, parents, partners);
        } else if(typeValue == 3){
            // 开盲盒收费
            boxFee(amount, parents, partners);
        } else if(typeValue == 4){
            // 市场收费
            marketFee(amount, parents, partners);
        } else if(typeValue == 5){
            uint256 _selfAmount = amount.mul(96).div(100);
            IERC20(settleToken).safeTransfer(from, _selfAmount);
            // 质押佣金
            pledgeFee(amount, parents, partners);
        }
        return true;
    }

    function attrsFee(uint amount, address[2] memory parents, address[2] memory partners) private returns(bool){
        if(parents[0] != address(0)){
            // 一级2%
            totalIncome[parents[0]].attrsAmount += amount.mul(2).div(100);
        }
        if(parents[1] != address(0)){
            // 二级1%
            totalIncome[parents[1]].attrsAmount += amount.mul(1).div(100);
        }
        if(partners[0] != address(0)){
            // 诸侯
            totalIncome[partners[0]].attrsAmount += amount.mul(10).div(100);
        }
        // 团队
        groupIncome[groupFeeTo].attrsAmount += amount.mul(50).div(100);
        // 燃烧
        IERC20(settleToken).safeTransfer(_burnTo, amount.mul(37).div(100));

        return true;
    }

    function heroFee(uint amount, address[2] memory parents, address[2] memory partners) private returns(bool){
        if(parents[0] != address(0)){
            // 一级2%
            totalIncome[parents[0]].heroAmount += amount.mul(2).div(100);
        }
        if(parents[1] != address(0)){
            // 二级1%
            totalIncome[parents[1]].heroAmount += amount.mul(1).div(100);
        }
        if(partners[0] != address(0)){
            // 工会
            totalIncome[partners[0]].heroAmount += amount.mul(4).div(100);
        }
        // 燃烧
        IERC20(settleToken).safeTransfer(_burnTo, amount.mul(93).div(100));
        return true;
    }

    function boxFee(uint amount, address[2] memory parents, address[2] memory partners) private returns(bool){
        if(parents[0] != address(0)){
            // 一级2%
            totalIncome[parents[0]].boxAmount += amount.mul(2).div(100);
        }
        if(parents[1] != address(0)){
            // 二级1%
            totalIncome[parents[1]].boxAmount += amount.mul(1).div(100);
        }
        if(partners[0] != address(0)){
            // 工会
            totalIncome[partners[0]].boxAmount += amount.mul(4).div(100);
        }
        return true;
    }

    function marketFee(uint amount, address[2] memory parents, address[2] memory partners) private returns(bool){
        if(parents[0] != address(0)){
            // 一级2%
            totalIncome[parents[0]].marketAmount += amount.mul(2).div(100);
        }
        if(parents[1] != address(0)){
            // 二级1%
            totalIncome[parents[1]].marketAmount += amount.mul(1).div(100);
        }
        if(partners[0] != address(0)){
            // 工会
            totalIncome[partners[0]].marketAmount += amount.mul(1).div(100);
        }
        return true;
    }

    function pledgeFee(uint amount, address[2] memory parents, address[2] memory partners) private returns(bool){
        if(parents[0] != address(0)){
            // 一级2%
            totalIncome[parents[0]].pledgeAmount += amount.mul(2).div(100);
        }
        if(parents[1] != address(0)){
            // 二级1%
            totalIncome[parents[1]].pledgeAmount += amount.mul(1).div(100);
        }
        if(partners[0] != address(0)){
            // 工会
            totalIncome[partners[0]].pledgeAmount += amount.mul(4).div(100);
        }
        return true;
    }


    function withdraw(uint256 typeValue) external returns(bool){
        require(settleToken != address(0), 'Tip: 1001');
        uint amount;
        address token = settleToken;
        if(typeValue == 1){
            amount = totalIncome[msg.sender].attrsAmount - totalIncome[msg.sender].attrsWithdrawAmount;
            totalIncome[msg.sender].attrsWithdrawAmount += amount;
        } else if(typeValue == 2) {
            amount = totalIncome[msg.sender].heroAmount - totalIncome[msg.sender].heroWithdrawAmount;
            totalIncome[msg.sender].heroWithdrawAmount += amount;
        } else if(typeValue == 3) {
            amount = totalIncome[msg.sender].boxAmount - totalIncome[msg.sender].boxWithdrawAmount;
            totalIncome[msg.sender].boxWithdrawAmount += amount;
        } else if(typeValue == 4) {
            amount = totalIncome[msg.sender].marketAmount - totalIncome[msg.sender].marketWithdrawAmount;
            totalIncome[msg.sender].marketWithdrawAmount += amount;
        } else if(typeValue == 5) {
            amount = totalIncome[msg.sender].pledgeAmount - totalIncome[msg.sender].pledgeWithdrawAmount;
            totalIncome[msg.sender].pledgeWithdrawAmount += amount;
        }
        require(amount > 0, 'Tip: 1002');
        IERC20(token).safeTransfer(msg.sender, amount);

        return true;
    }

    function setInvite(address _inviteAddress) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        inviteAddress = _inviteAddress;
        return true;
    }

    function setPartner(address _partnerAddress) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        partnerAddress = _partnerAddress;
        return true;
    }

    function setGroupFeeTo(address _groupFeeTo) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        groupFeeTo = _groupFeeTo;
        return true;
    }

    function setSettleToken(address _settleToken) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        settleToken = _settleToken;
        return true;
    }

    function setWhitelist(address _address) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        whitelist[_address] = true;
        return true;
    }

    function removeWhitelist(address _address) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        delete whitelist[_address];
        return true;
    }

}
