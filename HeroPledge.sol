// SPDX-License-Identifier: MIT
pragma solidity =0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import './library/ArrayUtil.sol';
import './library/SafeTransferLib.sol';
import './library/TransferHelper.sol';
import './interfaces/IInvite.sol';
import './interfaces/IRoleAttrs.sol';

contract HeroPledge is ERC721Holder, ERC1155Holder {
    using SafeMath for uint;
    // 质押hero nft，产出tokenB
    address public factory;
    address private inviteAddress; // 邀请合约地址
    address private roleAttrsAddress; // 属性合约地址

    address public tokenB;
    uint256 public tokenBAmount; // tokenB总量
    uint256 public startTime; // s 矿池开始时间
    uint256 public endTime; // s 矿池结束时间
    uint256 private settleUnit = 24; // 结算周期 小时

    struct Order {
        address userAddress; // 用户 address
        address nftAddress; // hero address
        uint256 tokenId; // hero tokenid
        uint256 capitalId; // 城池id
        uint256 incomeAmount; // 收成总量
        uint256 extractAmount; // 已提取总额
        uint256 lastActionTime; // 最后一次点击时间
        uint256 time; // 订单开始时间
    }
    mapping(uint256 => Order) public pledgeOrders; // 质押记录 orderIdx => Order, 一个order对应一个hero, orderIdx 从1开始，一直累加
    mapping(address => mapping(uint256 => uint256)) public heroLinkOrder; // hero与订单的索引关联 nftAddress=>tokenId=>orderIdx
    uint256 public orderIdx;
    uint256 public totalHeros; // 总质押英雄数
    mapping(uint256 => uint256) public totalCapitalHeros; // 总质押英雄数 按城池分
    mapping(uint256 => uint256) public totalAbility; // 施政能力总和 按城池分
    mapping(address => uint256) public totalReward; // 每个人获取的总分销奖
    mapping(address => mapping(uint256 => uint256[])) public userPledgeOrders; // 用户地址=>城池id=>orderIds

    constructor (address _roleAttrsAddress) {
        factory = msg.sender;
        roleAttrsAddress = _roleAttrsAddress;
    }

    // 质押
    function doPledge(address nftAddress, uint256 tokenId, uint256 attrId, uint256 capitalId) external returns(bool){
        require(block.timestamp >= startTime && block.timestamp < endTime, 'Tip: 1050');
        // 调用属性合约，验证nft是否有效
        (IRoleAttrs.Attrs memory attrs, uint256 grade) = IRoleAttrs(roleAttrsAddress).getAttrs(attrId);
        require(attrs.nftAddress == nftAddress && attrs.tokenId == tokenId, 'Tip: 1051');
        require(grade >= capitalId, 'Tip: 1052');
        require(heroLinkOrder[nftAddress][tokenId] == 0, 'Tip: 1053');
        // 将nft转入合约
        SafeTransferLib.safeTransferFrom(nftAddress, msg.sender, address(this), tokenId, 1);
        // 记录订单
        orderIdx++;
        Order memory order = Order(msg.sender, nftAddress, tokenId, capitalId, 0, 0, block.timestamp, block.timestamp);
        pledgeOrders[orderIdx] = order;
        heroLinkOrder[nftAddress][tokenId] = orderIdx;
        userPledgeOrders[msg.sender][capitalId].push(orderIdx);
        totalHeros++;
        totalCapitalHeros[capitalId]++;
        totalAbility[capitalId] += attrs.attrValue6;

//        if(inviteAddress != address(0) && parent != address(0)){
//            IInvite(inviteAddress).addRecord(parent, msg.sender);
//        }

        return true;
    }

    // 提取
    function extract(address nftAddress, uint256 tokenId) external returns(bool){
        (Order memory order, uint256 _orderIdx) = _getMyOrder(nftAddress, tokenId);
        require(order.incomeAmount > order.extractAmount, 'Tip: 1014');
        require(tokenB != address(0), 'Tip: 1015');
        require(inviteAddress != address(0), 'Tip: 1016');
        // 计算收益
        uint256 myAmount = order.incomeAmount - order.extractAmount;
        uint256 tokenBBalance = IERC20(tokenB).balanceOf(address(this));
        require(tokenBBalance >= myAmount, 'Tip: 1050');
        // 结算收益
        uint256 _selfAmount = myAmount;
        address[2] memory parents = IInvite(inviteAddress).getParents(msg.sender);
        if(parents[0] != address(0)){
            uint256 _shareAmount1 = myAmount.mul(3).div(100);
            _selfAmount = _selfAmount.sub(_shareAmount1);
            IERC20(tokenB).transfer(parents[0], _shareAmount1);
            totalReward[parents[0]] += _shareAmount1;
        }
        if(parents[1] != address(0)){
            uint256 _shareAmount2 = myAmount.mul(1).div(100);
            _selfAmount = _selfAmount.sub(_shareAmount2);
            IERC20(tokenB).transfer(parents[1], _shareAmount2);
            totalReward[parents[1]] += _shareAmount2;
        }
        IERC20(tokenB).transfer(msg.sender, _selfAmount);
        pledgeOrders[_orderIdx].extractAmount += myAmount; // 记录已提取总额

        return true;
    }

    // 撤出
    function stopOrder(address nftAddress, uint256 tokenId, uint256 attrId) external returns(bool){
        (IRoleAttrs.Attrs memory attrs,) = IRoleAttrs(roleAttrsAddress).getAttrs(attrId);
        require(attrs.nftAddress == nftAddress && attrs.tokenId == tokenId, 'Tip: 1051');
        (, uint256 _orderIdx) = _getMyOrder(nftAddress, tokenId);
        // 距上一次结算收益大于48小时才能撤出 3600*48
        require(block.timestamp - pledgeOrders[_orderIdx].lastActionTime > 60, 'Tip: 1052');
        // 转出NFT
        SafeTransferLib.safeTransferFrom(nftAddress, address(this), msg.sender, tokenId, 1);
        // 删除记录
        uint256 _capitalId = pledgeOrders[_orderIdx].capitalId;
        totalAbility[_capitalId] -= attrs.attrValue6;
        delete pledgeOrders[_orderIdx];
        delete heroLinkOrder[nftAddress][tokenId];
        userPledgeOrders[msg.sender][_capitalId] = ArrayUtil.removeValue(userPledgeOrders[msg.sender][_capitalId], _orderIdx);
        // 更新统计
        totalCapitalHeros[_capitalId]--;
        totalHeros--;

        return true;
    }

    // 结算收入
    function settleIncome(address nftAddress, uint256 tokenId, uint256 attrId) external returns(bool) {
        require(block.timestamp >= startTime && block.timestamp < endTime, 'Tip: 1050');
        require(tokenBAmount > 0, 'Tip: 1052');
        (IRoleAttrs.Attrs memory attrs, uint256 grade) = IRoleAttrs(roleAttrsAddress).getAttrs(attrId);
        require(attrs.nftAddress == nftAddress && attrs.tokenId == tokenId, 'Tip: 1051');
        (Order memory order, uint256 _orderIdx) = _getMyOrder(nftAddress, tokenId);
        require(totalAbility[order.capitalId] > 0, 'Tip: 1062');
        // 验证时间
        // require(block.timestamp - order.lastActionTime > 3600*settleUnit, 'Tip: 1061'); // 测试期关闭
        uint256 hourProductAmount = tokenBAmount.div(3*365*24*12);
        pledgeOrders[_orderIdx].incomeAmount += settleUnit.mul(hourProductAmount).mul(attrs.attrValue6).div(totalAbility[grade]);
        pledgeOrders[_orderIdx].lastActionTime = block.timestamp;
        return true;
    }

    function _getMyOrder(address nftAddress, uint256 tokenId) private view returns(Order memory order, uint256 _orderIdx){
        _orderIdx = heroLinkOrder[nftAddress][tokenId];
        require(_orderIdx > 0, 'Tip: 1011');
        order = pledgeOrders[_orderIdx];
        require(order.nftAddress == nftAddress && order.tokenId == tokenId, 'Tip: 1012');
        require(order.userAddress == msg.sender, 'Tip: 1013');
    }

    function getUserOrders(address userAddress, uint256 capitalId) external view returns(uint256[] memory) {
        return userPledgeOrders[userAddress][capitalId];
    }

    function blockTime() external view returns(uint256){
        return block.timestamp;
    }

    function setTime(uint256 _startTime, uint256 _endTime) external returns(bool){
        require(msg.sender == factory, 'Tip: 1004');
        startTime = _startTime;
        endTime = _endTime;
        return true;
    }

    function setTokenB(address _tokenB, uint256 _amount) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        tokenB = _tokenB;
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), _amount);
        tokenBAmount += _amount;
        return true;
    }
    function delTokenB(uint256 _amount) external returns(bool){
        require(msg.sender == factory, 'Tip: 1006');
        require(tokenBAmount >= _amount, 'Tip: 1006');
        address _burnTo = 0x0000000000000000000000000000000000001010;
        TransferHelper.safeTransferFrom(tokenB, address(this), _burnTo, _amount);
        tokenBAmount -= _amount;
        return true;
    }

    function setInvite(address _inviteAddress) external returns(bool){
        require(msg.sender == factory, 'Tip: 1008');
        inviteAddress = _inviteAddress;
        return true;
    }
}
