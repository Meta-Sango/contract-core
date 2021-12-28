// SPDX-License-Identifier: MIT
pragma solidity =0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import './interfaces/IRoleAttrs.sol';
import './library/TransferHelper.sol';
import './library/SafeTransferLib.sol';
import './interfaces/IFeeCallee.sol';
import './interfaces/INFTFactory.sol';
import './interfaces/IPair.sol';

contract RoleAttrs is IRoleAttrs, ERC721Holder, ERC1155Holder {
    using SafeMath for uint;
    using SafeMath for uint112;
    using Address for address;

    address public factory;

	uint private _rand = 1;
    mapping(uint256 => Attrs) private attrsList;
	mapping(uint256 => uint256) private roleGrade;
	uint256[16] public updateGradePrice;
    uint256 public price; // 生成属性价格
    address private feeTo; // 生成属性费用接收地址
    uint256 public createPrice; // 创建英雄价格
    uint256 private burnRate = 93; // 燃烧比例 %
    address private feeToHero; // 创建英雄费用接收地址
    address private _burnTo = 0x0000000000000000000000000000000000001010;
    uint256 public lastAttrsId = 1024;
    address private settleToken;
    address private pairAddress;
    address private nftFactory; // nft工厂
    mapping(address => address) public userNftAddress; // 用户地址 => nftAddress 一个人只能创建一个栏目

    event AttrsGenerated(uint256, uint256[6]);
    event CreatedHero(address, address, uint256, uint256);

    constructor(address _settleToken, address _nftFactory) {
        factory = msg.sender;
        settleToken = _settleToken;
        nftFactory = _nftFactory;
        _createNewAttr();
    }

    function _cauSettleAmount(uint256 _price) private pure returns(uint256) {
        return _price;
//        if(pairAddress == address(0) || _price == 0){
//            return 0;
//        }
//        (address token0, address token1) = IPair(pairAddress).getTokens();
//        if(token0 != settleToken && token1 != settleToken){
//            return 0;
//        }
//        (uint112 reserve0, uint112 reserve1,) = IPair(pairAddress).getReserves();
//        require(reserve0 > 0 && reserve1 > 0, 'Tip: 1001');
//        if(settleToken == token0){
//            return uint256(_price.mul(reserve1.div(reserve0)));
//        } else {
//            return uint256(_price.mul(reserve0.div(reserve1)));
//        }
    }

    function getSettleAmount(uint256 _price) external virtual returns(uint256){
        return _cauSettleAmount(_price);
    }

    // 生成属性
    function generateAttrs(uint256 regionSn) external virtual override returns(uint256 attrsId, uint256[6] memory attrValues) {
        uint256 amount = _cauSettleAmount(price);
        if(feeTo != address(0) && amount > 0 && settleToken != address(0)){
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
        Attrs memory _newAttrs = Attrs(
            address(0),
            0, 0,
            _getRandom(10, 100), _getRandom(10, 100), _getRandom(10, 100),
            _getRandom(10, 100), _getRandom(10, 100), _getRandom(100, 1000),
			address(0)
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
        Attrs memory _attrs = attrsList[attrsId];
        require(_attrs.nftAddress == address(0), 'Tips: 0002');
        require(_attrs.tokenId == 0, 'Tips: 0003');
        require(_attrs.attrValue1 > 0, 'Tips: 0004');

        uint256 amount = _cauSettleAmount(createPrice);
        if(feeToHero != address(0) && amount > 0 && settleToken != address(0)){
            uint _burnNum = amount.mul(burnRate).div(100);
            IERC20(settleToken).transferFrom(msg.sender, _burnTo, _burnNum);
            TransferHelper.safeTransferFrom(settleToken, msg.sender, feeToHero, amount.sub(_burnNum));
            if(feeToHero.isContract()){
                IFeeCallee(feeToHero).feeCall(msg.sender, amount, 2);
            }
        }
        uint tokenId;
        address nftAddress = userNftAddress[msg.sender];
        if(nftAddress != address(0)){
            tokenId = INFTFactory(nftFactory).createToken(nftAddress, tokenURI);
        } else {
            nftAddress = INFTFactory(nftFactory).createNFT('MetaSango Characters', 'HEROS', tokenURI, '');
            tokenId = 1025;
            userNftAddress[msg.sender] = nftAddress;
        }
        attrsList[attrsId].nftAddress = nftAddress;
        attrsList[attrsId].tokenId = tokenId;
        attrsList[attrsId].linkShard = linkShard;
        // 转给个人
        SafeTransferLib.safeTransferFrom(nftAddress, address(this), msg.sender, tokenId, 1);

        emit CreatedHero(msg.sender, nftAddress, tokenId, attrsId);

        return true;
    }

    // 获取有效的属性值
    function getAttrs(uint256 attrsId) external virtual override view returns(Attrs memory attrs, uint256 grade){
        attrs = attrsList[attrsId];
		if(msg.sender != factory){
			require(attrs.nftAddress != address(0), 'Tips: 0005');
			require(attrs.tokenId > 0, 'Tips: 0006');
			require(attrs.attrValue1 > 0, 'Tips: 0007');
		}
        grade = roleGrade[attrsId];
    }

	// 升级
	function upgrade(uint256 attrsId) external virtual override returns(bool){
		Attrs memory _attrs = attrsList[attrsId];
		require(_attrs.nftAddress != address(0), 'Tips: 0005');
		require(_attrs.tokenId > 0, 'Tips: 0006');
		require(_attrs.attrValue1 > 0, 'Tips: 0007'); // 任何一个值 >0 视为有效
		require(_attrs.linkShard != address(0), 'Tips: 00021');
		uint256 grade = roleGrade[attrsId];
		uint256 _price = updateGradePrice[grade + 1];
		require(_price > 0, 'Tips: 0022');
        IERC20(_attrs.linkShard).transferFrom(msg.sender, _burnTo, _price);
		roleGrade[attrsId] = grade + 1;
		return true;
	}

    // 设置属性feeTo
    function setFeeTo(address _feeTo) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0008');
        feeTo = _feeTo;
        return true;
    }

    // 设置属性价格
    function setPrice(uint256 _price) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0009');
        price = _price;
        return true;
    }

    // 设置创造英雄feeTo
    function setFeeToHero(address _feeTo) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0021');
        feeToHero = _feeTo;
        return true;
    }

    // 设置创造英雄价格
    function setCreatePrice(uint256 _price) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0022');
        createPrice = _price;
        return true;
    }

    // 设置创造英雄价格销毁比例
    function setBurnRate(uint256 _burnRate) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0023');
        burnRate = _burnRate; // %
        return true;
    }

    // 设置升级价格
	function setUpgradePrice(uint256[16] memory _updateGradePrice) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0010');
        updateGradePrice = _updateGradePrice;
        return true;
    }

    // 设置nftFactory
    function setNftFactory(address _nftFactory) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0010');
        nftFactory = _nftFactory;
        return true;
    }

    function setSettleToken(address _settleToken) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0009');
        settleToken = _settleToken;
        return true;
    }

    function setPairAddress(address _pairAddress) external virtual returns(bool){
        require(msg.sender == factory, 'Tips: 0009');
        pairAddress = _pairAddress;
        return true;
    }
}
