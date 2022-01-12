// SPDX-License-Identifier: MIT
pragma solidity =0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import './library/ArrayUtil.sol';
import './library/SafeTransferLib.sol';

import './interfaces/IRoleAttrs.sol';
import './interfaces/IFeeCallee.sol';
import './Price.sol';
import './Auth.sol';

contract HeroPledge is ERC721Holder, ERC1155Holder, Auth {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using Address for address;

    address private factory; // 合约创建地址
    address private priceUtilAddress;
    address private pairAddress;
    // 系统参数
    address private feeTo; // 上级佣金接收地址
    address private roleAttrsAddress; // 属性合约地址
    // 质押hero nft，产出tokenB
    address public tokenB;
    uint256 public tokenBAmount; // tokenB总量
    uint256 public startTime; // s 矿池开始时间
    uint256 public endTime; // s 矿池结束时间

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
    uint256 public totalAbilityAmount; // 全部施政能力总和
    mapping(address => mapping(uint256 => uint256[])) public userPledgeOrders; // 用户地址=>城池id=>orderIds

    event SettleIncome(uint256, uint256, uint256);
    event PledgeHero(address, uint256, uint256, uint256);

    constructor () {
        factory = msg.sender;
    }

    // 质押
    function doPledge(address nftAddress, uint256 tokenId, uint256 attrId, uint256 capitalId) external returns(bool){
        require(block.timestamp >= startTime && block.timestamp < endTime, 'Tip: 1050');
        // 调用属性合约，验证nft是否有效
        (IRoleAttrs.Attrs memory attrs, uint256 grade,) = IRoleAttrs(roleAttrsAddress).getAttrs(attrId);
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
        totalAbilityAmount += attrs.attrValue6*(grade + 1);

        emit PledgeHero(nftAddress, tokenId, capitalId, orderIdx);

        return true;
    }

    // 提取
    function extract(address nftAddress, uint256 tokenId) external returns(bool){
        (Order memory order, uint256 _orderIdx) = _getMyOrder(nftAddress, tokenId);
        require(order.incomeAmount > order.extractAmount, 'Tip: 1014');
        require(tokenB != address(0), 'Tip: 1015');
        // 计算收益
        uint256 newAmount = order.incomeAmount - order.extractAmount;
        if(newAmount <= 0){
            return true;
        }
        uint256 tokenBBalance = IERC20(tokenB).balanceOf(address(this));
        require(tokenBBalance >= newAmount, 'Tip: 1050');
        // 结算收益
        IERC20(tokenB).safeTransfer(feeTo, newAmount);
        if(feeTo != address(0) && feeTo.isContract()){
            IFeeCallee(feeTo).feeCall(msg.sender, newAmount, 5);
        }
        pledgeOrders[_orderIdx].extractAmount += newAmount; // 记录已提取总额

        return true;
    }

    // 撤出
    function stopOrder(address nftAddress, uint256 tokenId, uint256 attrId) external returns(bool){
        (IRoleAttrs.Attrs memory attrs, uint256 grade,) = IRoleAttrs(roleAttrsAddress).getAttrs(attrId);
        require(attrs.nftAddress == nftAddress && attrs.tokenId == tokenId, 'Tip: 1051');
        (, uint256 _orderIdx) = _getMyOrder(nftAddress, tokenId);
        // 距上一次结算收益大于72小时才能撤出 3600*24*5 TODO 正式版5天
        require(block.timestamp - pledgeOrders[_orderIdx].lastActionTime > 3600*1, 'Tip: 1052');
        // 转出NFT
        SafeTransferLib.safeTransferFrom(nftAddress, address(this), msg.sender, tokenId, 1);
        // 删除记录（用户未提取的收益直接清零）
        uint256 _capitalId = pledgeOrders[_orderIdx].capitalId;
        totalAbility[_capitalId] -= attrs.attrValue6;
        totalAbilityAmount -= attrs.attrValue6*(grade + 1);
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
        (IRoleAttrs.Attrs memory attrs, uint256 grade, uint256 energy) = IRoleAttrs(roleAttrsAddress).getAttrs(attrId);
        uint maxEnergy = attrs.attrValue6 * (grade + 1)*(grade + 2)/2;
        require(energy > maxEnergy.mul(10).div(100) && energy > 100, 'Tip: 1053'); // 体能 大于最大体能10%
        require(attrs.nftAddress == nftAddress && attrs.tokenId == tokenId, 'Tip: 1051');
        (Order memory order, uint256 _orderIdx) = _getMyOrder(nftAddress, tokenId);
        require(totalAbility[order.capitalId] > 0, 'Tip: 1062');
        // 押入tokenB的总量，分3年释放，按小时算 3*365*24
        uint256 hourNum = (block.timestamp - order.lastActionTime).div(3600); // 距离上一次结算的小时数
        if(hourNum == 0){
            return true;
        }
        uint256 hourProductAmount = tokenBAmount.div(3*365*24); // 每小时的释放量
        uint256 _newIncome = hourNum.mul(hourProductAmount).mul(attrs.attrValue6).mul(grade + 1).div(totalAbilityAmount);
        // 降低体能 _newIncome 换算成U
        uint256 _price = Price(priceUtilAddress).tokenPrice(pairAddress, tokenB);
        uint256 num = _newIncome.div(_price);
        if(num > energy || energy - num < 100){
            num = energy - 100;
            _newIncome = num.mul(_price);
        }
        IRoleAttrs(roleAttrsAddress).subEnergy(attrId, num);
        // 记录收益
        pledgeOrders[_orderIdx].incomeAmount += _newIncome;
        pledgeOrders[_orderIdx].lastActionTime = block.timestamp;

        emit SettleIncome(_newIncome, num, _price);

        return true;
    }

    // 根据tokenId获取我的订单并验证有效性
    function _getMyOrder(address nftAddress, uint256 tokenId) private view returns(Order memory order, uint256 _orderIdx){
        _orderIdx = heroLinkOrder[nftAddress][tokenId];
        require(_orderIdx > 0, 'Tip: 1011');
        order = pledgeOrders[_orderIdx];
        require(order.nftAddress == nftAddress && order.tokenId == tokenId, 'Tip: 1012');
        require(order.userAddress == msg.sender, 'Tip: 1013');
    }

    // 获取指定用户在指定城池的质押记录
    function getUserOrders(address userAddress, uint256 capitalId) external view returns(uint256[] memory) {
        return userPledgeOrders[userAddress][capitalId];
    }

    // 设置起始时间
    function setTime(uint256 _startTime, uint256 _endTime) external virtual onlyAuth returns(bool){
        // 设为0则表示关闭质押，但是依旧可提取
        startTime = _startTime;
        endTime = _endTime;
        return true;
    }
    // 押入产物TokenB
    function setTokenB(address _tokenB, uint256 _amount) external virtual onlyAuth returns(bool){
        require(_tokenB != address(0), "Tip: 1001");
        require(_amount > 0, "Tip: 1002");
        tokenB = _tokenB;
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), _amount);
        tokenBAmount += _amount;
        return true;
    }
    // 移除产物TokenB
    function removeTokenB(uint256 _amount) external virtual onlyAuth returns(bool){
        require(tokenBAmount >= _amount, 'Tip: 1006');
        address burnTo = 0x0000000000000000000000000000000000000001;
        IERC20(tokenB).safeTransfer(burnTo, _amount);
        tokenBAmount -= _amount;
        return true;
    }
    // 绑定英雄属性合约
    function setRoleAttrs(address _roleAttrsAddress) external virtual onlyAuth returns(bool){
        require(_roleAttrsAddress != address(0), "Tip: 1001");
        roleAttrsAddress = _roleAttrsAddress;
        return true;
    }
    function setPairAddress(address _pairAddress) external virtual onlyAuth returns(bool){
        require(_pairAddress != address(0), 'Tips: 0009');
        pairAddress = _pairAddress;
        return true;
    }

    // 价格计算器
    function setPriceUtilAddress(address _priceUtilAddress) external virtual onlyAuth returns(bool){
        priceUtilAddress = _priceUtilAddress;
        return true;
    }

    function setFeeTo(address _feeTo) external virtual onlyAuth returns(bool){
        require(_feeTo != address(0), 'Tips: 0008');
        feeTo = _feeTo;
        return true;
    }

}
