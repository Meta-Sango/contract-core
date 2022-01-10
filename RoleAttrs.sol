// SPDX-License-Identifier: MIT
pragma solidity =0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import './Shard.sol';
import './interfaces/IRoleAttrs.sol';
import './library/TransferHelper.sol';
import './library/SafeTransferLib.sol';
import './library/AttrsUtil.sol';
import './interfaces/IFeeCallee.sol';
import './interfaces/INFTFactory.sol';
import './interfaces/IPair.sol';
import './Price.sol';
import './Auth.sol';

contract RoleAttrs is IRoleAttrs, ERC721Holder, ERC1155Holder, Auth {
    using SafeMath for uint;
    using SafeMath for uint112;
    using Address for address;
    using SafeERC20 for IERC20;

    mapping(address => bool) private whitelist;
	uint private _rand = 1;
    address[] public shardList; // shard白名单
    mapping(uint256 => Attrs) private attrsList;
	mapping(uint256 => uint256) private roleGrade;
    mapping(uint256 => uint256) private roleEnergy; // 体力值
	uint256[16] public updateGradePrice;
    uint256 public price; // 生成属性价格
    address private feeTo; // 生成属性费用接收地址
    uint256 public createPrice; // 创建英雄价格
    uint256 private burnRate; // 燃烧比例 %
    address private feeToHero; // 创建英雄费用接收地址
    address private burnTo;
    uint256 public lastAttrsId = 1024;
    address private settleToken;
    address private pairAddress;
    address private priceUtilAddress;
    address private nftFactory; // nft工厂
    mapping(address => address) public userNftAddress; // 用户地址 => nftAddress 一个人只能创建一个栏目

    event AttrsGenerated(uint256, uint256[6]);
    event CreatedHero(address, address, uint256, uint256);

    constructor(address _settleToken, address _nftFactory) {
        require(_settleToken != address(0), "Tip: 001");
        require(_nftFactory != address(0), "Tip: 002");
        settleToken = _settleToken;
        nftFactory = _nftFactory;
        burnTo = 0x0000000000000000000000000000000000001010;
        burnRate = 93; // 默认燃烧 93%
        _createNewAttr();
    }

    // 计算需要花费的settleToken动态数量。要求用 settleToken 结算，传入一个数值 _price，计算出实际需要花费的settleToken的数量
    function _cauSettleAmount(uint256 _price) private view returns(uint256) {
        if(_price == 0){
            return 0;
        }
        require(priceUtilAddress != address(0), 'Tip: 0001');
        require(pairAddress != address(0), 'Tip: 0002');
        require(settleToken != address(0), 'Tip: 0003');
        Price priceUtil = Price(priceUtilAddress);
        uint256 amount = priceUtil.tokenAmount(pairAddress, settleToken, _price);
        require(amount > 0, 'Tip: 0002');
        return amount;
    }

    function getSettleAmount(uint256 _price) external virtual returns(uint256){
        return _cauSettleAmount(_price);
    }

    // 生成属性。调用此函数给attrsList中最后一条数据绑定有效regionSn，同时产生6个随机数和regionSn=0赋到下一个Attrs中，等下次有人调用此函数，再给regionSn赋有效值
    function generateAttrs(uint256 regionSn) external virtual override returns(uint256 attrsId, uint256[6] memory attrValues) {
        // 当price为0时，表示免费，可能会有免费活动
        uint256 amount = _cauSettleAmount(price);
        if(amount > 0){
            require(feeTo != address(0), 'Tip: 1001');
            require(settleToken != address(0), 'Tip: 1002');
            TransferHelper.safeTransferFrom(settleToken, msg.sender, feeTo, amount);
            if(feeTo.isContract()){
                IFeeCallee(feeTo).feeCall(msg.sender, amount, 1);
            }
        }
        attrsId = lastAttrsId;
        Attrs memory _attrs = attrsList[attrsId];
        attrValues = [_attrs.attrValue1, _attrs.attrValue2, _attrs.attrValue3, _attrs.attrValue4, _attrs.attrValue5, _attrs.attrValue6];
        attrsList[attrsId].regionSn = regionSn;
        lastAttrsId++;
        _createNewAttr();

        emit AttrsGenerated(attrsId, attrValues);
    }

    function _createNewAttr() private {
        // 计算概率
        uint256 randValue = _getRandom(10, 100);
        uint[2] memory range = AttrsUtil.getRandomRange(randValue);
        uint256 attrValue6 = _getRandom(range[0], range[1]);
        Attrs memory _newAttrs = Attrs(
            address(0),
            0, 0,
            _getRandom(10, 100), _getRandom(10, 100), _getRandom(10, 100),
            _getRandom(10, 100), _getRandom(10, 100), attrValue6,
			address(0),
            msg.sender
        );
        attrsList[lastAttrsId] = _newAttrs;
    }

    // 生成指定范围随机数，存在安全问题，不可在交易过程中使用
    function _getRandom(uint256 _start, uint256 _end) private returns(uint256) {
        uint256 _length = _end - _start;
        uint256 random = uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp, _rand)));
        random = random % _length + _start;
        _rand = random;
        return random;
    }

    // 铸造英雄NFT
    function mintHero(uint256 attrsId, address linkShard, string memory tokenURI) external virtual override returns (bool){
        require(_checkShard(linkShard), 'Tip: 0001'); // 验证shard白名单
        Attrs memory _attrs = attrsList[attrsId];
        // 验证属性没有绑定nft
        require(_attrs.nftAddress == address(0), 'Tips: 0002');
        require(_attrs.tokenId == 0, 'Tips: 0003');
        // 验证属性值有效性，确保绑定英雄的属性不会出现0值
        require(_attrs.attrValue6 > 0, 'Tips: 0004');
        // 只有属性创建人可以绑定
        require(_attrs.creator == msg.sender, 'Tips: 0005');
        // createPrice为0表示可以免费创造英雄，或许会有免费活动
        uint256 amount = _cauSettleAmount(createPrice);
        if(amount > 0){
            require(feeToHero != address(0), 'Tip: 1001');
            require(settleToken != address(0), 'Tip: 1002');
            uint _burnNum = amount.mul(burnRate).div(100);
            IERC20(settleToken).safeTransferFrom(msg.sender, burnTo, _burnNum);
            TransferHelper.safeTransferFrom(settleToken, msg.sender, feeToHero, amount.sub(_burnNum));
            if(feeToHero.isContract()){
                IFeeCallee(feeToHero).feeCall(msg.sender, amount, 2);
            }
        }
        uint tokenId;
        address nftAddress = userNftAddress[msg.sender];
        if(nftAddress != address(0)){
            (nftAddress, tokenId) = INFTFactory(nftFactory).createToken(nftAddress, tokenURI);
        } else {
            (nftAddress, tokenId) = INFTFactory(nftFactory).createNFT('MetaSango Characters', 'HEROS', tokenURI, '');
            userNftAddress[msg.sender] = nftAddress;
        }
        attrsList[attrsId].nftAddress = nftAddress;
        attrsList[attrsId].tokenId = tokenId;
        attrsList[attrsId].linkShard = linkShard;
        roleEnergy[attrsId] = _attrs.attrValue6; // 初始能量值等于施政能力
        // 转给个人
        SafeTransferLib.safeTransferFrom(nftAddress, address(this), msg.sender, tokenId, 1);

        emit CreatedHero(msg.sender, nftAddress, tokenId, attrsId);

        return true;
    }

    // 获取有效的属性值
    function getAttrs(address user, uint256 attrsId) external virtual override view returns(Attrs memory attrs, uint256 grade, uint256 energy){
        attrs = attrsList[attrsId];
        require(attrs.nftAddress != address(0), 'Tips: 0005');
        require(attrs.tokenId > 0, 'Tips: 0006');
        require(attrs.attrValue6 > 0, 'Tips: 0007');
        grade = roleGrade[attrsId];
        energy = roleEnergy[attrsId];
    }

	// 升级
	function upgrade(uint256 attrsId) external virtual override returns(bool){
		Attrs memory _attrs = attrsList[attrsId];
		require(_attrs.nftAddress != address(0), 'Tips: 0005');
		require(_attrs.tokenId > 0, 'Tips: 0006');
		require(_attrs.attrValue6 > 0, 'Tips: 0007'); // 任何一个值 >0 视为有效
		require(_attrs.linkShard != address(0), 'Tips: 00021');
		uint256 _grade = roleGrade[attrsId];
		uint256 _price = updateGradePrice[_grade + 1];
		require(_price > 0, 'Tips: 0022');
        IERC20(_attrs.linkShard).safeTransferFrom(msg.sender, burnTo, _price.mul(_grade.add(1)));
		roleGrade[attrsId] = _grade + 1;
        // 提升体能
        roleEnergy[attrsId] = roleEnergy[attrsId] + roleGrade[attrsId]*_attrs.attrValue6;
		return true;
	}

    // 提升体力
    function recoverEnergy(uint256 attrsId, uint256 amount) external virtual override returns(bool){
        Attrs memory _attrs = attrsList[attrsId];
        require(_attrs.nftAddress != address(0), 'Tips: 0005');
        require(_attrs.tokenId > 0, 'Tips: 0006');
        require(_attrs.attrValue6 > 0, 'Tips: 0007'); // 任何一个值 >0 视为有效
        require(_attrs.linkShard != address(0), 'Tips: 00021');
        // 1个碎片提升1个体能值
        require(amount > 0, 'Tips: 0022');
        uint256 decimals = Shard(_attrs.linkShard).decimals();
        IERC20(_attrs.linkShard).safeTransferFrom(msg.sender, burnTo, amount);
        roleEnergy[attrsId] = roleEnergy[attrsId] + amount.div(10 ** decimals);

        return true;
    }

    function addEnergy(uint256 attrsId, uint256 num) external virtual override returns(bool){
        require(whitelist[msg.sender], 'Tip: 0001');
        roleEnergy[attrsId] = roleEnergy[attrsId] + num;
        return true;
    }

    function subEnergy(uint256 attrsId, uint256 num) external virtual override returns(bool){
        require(whitelist[msg.sender], 'Tip: 0002');
        roleEnergy[attrsId] = roleEnergy[attrsId] - num;
        return true;
    }

    // 设置属性价格(可以为0)
    function setPrice(uint256 _price) external virtual onlyAuth returns(bool){
        price = _price;
        return true;
    }

    // 设置创造英雄价格
    function setCreatePrice(uint256 _createPrice) external virtual onlyAuth returns(bool){
        createPrice = _createPrice;
        return true;
    }

    // 设置属性feeTo
    function setFeeTo(address _feeTo) external virtual onlyAuth returns(bool){
        require(_feeTo != address(0), 'Tips: 0008');
        feeTo = _feeTo;
        return true;
    }

    // 设置创造英雄feeTo
    function setFeeToHero(address _feeToHero) external virtual onlyAuth returns(bool){
        require(_feeToHero != address(0), 'Tips: 0008');
        feeToHero = _feeToHero;
        return true;
    }

    // 设置创造英雄价格销毁比例(可以为0)
    function setBurnRate(uint256 _burnRate) external virtual onlyAuth returns(bool){
        burnRate = _burnRate; // %
        return true;
    }

    // 设置升级价格(可以为0)
	function setUpgradePrice(uint256[16] memory _updateGradePrice) external onlyAuth virtual returns(bool){
        updateGradePrice = _updateGradePrice;
        return true;
    }

    // 设置nftFactory
    function setNftFactory(address _nftFactory) external virtual onlyAuth returns(bool){
        require(_nftFactory != address(0), 'Tips: 0010');
        nftFactory = _nftFactory;
        return true;
    }

    function setSettleToken(address _settleToken) external virtual onlyAuth returns(bool){
        require(_settleToken != address(0), 'Tips: 0009');
        settleToken = _settleToken;
        return true;
    }

    function setPairAddress(address _pairAddress) external virtual onlyAuth returns(bool){
        require(_pairAddress != address(0), 'Tips: 0009');
        pairAddress = _pairAddress;
        return true;
    }

    // 录入shards地址
    function setShardList(address _shard) external virtual onlyAuth returns(bool){
        require(_shard != address(0), 'Tips: 0009');
        require(shardList.length < 200, 'Tips: 0010');
        require(!_checkShard(_shard), 'Tips: 0011');
        shardList.push(_shard);
        return true;
    }

    function _checkShard(address _shard) private view returns(bool){
        bool flag = false;
        for(uint i; i < shardList.length; i++){
            if(shardList[i] == _shard){
                flag = true;
                break;
            }
        }
        return flag;
    }

    // 绑定燃烧地址
    function setBurnTo(address _burnTo) external virtual onlyAuth returns(bool){
        burnTo = _burnTo;
        return true;
    }

    // 价格计算器
    function setPriceUtilAddress(address _priceUtilAddress) external virtual onlyAuth returns(bool){
        priceUtilAddress = _priceUtilAddress;
        return true;
    }

    // 设置白名单
    function setWhitelist(address _address, uint _status) external virtual onlyAuth returns(bool){
        if(_status == 1){
            whitelist[_address] = true;
        } else {
            delete whitelist[_address];
        }
        return true;
    }
}
