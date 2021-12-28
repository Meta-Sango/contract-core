// SPDX-License-Identifier: MIT
pragma solidity =0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MvsgToken is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    mapping (address => bool) private _isExcluded;
    address[] private _excluded;

    uint256 private constant MAX = ~uint256(0);
    string private _name = 'MetaSango';
    string private _symbol = 'MVSG';
    uint8 private _decimals = 18;
    uint256 private  _tTotal = 100000000 * 10**_decimals;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;

    uint256 private _tBurnTotal;

    address public _burnPool = 0x000000000000000000000000000000000000dEaD;
    address public lpAddress = 0x474f059D022DB51Eed5c63e8F1A3cCE48b6D7005;
    address public fundAddress = 0x618592626d737A062C04eA17A10Cb6A9A439Ee2a;

    mapping(address => bool) private _isExcludedFromFee;

    uint256 public _taxFee = 3;
    uint256 private _previousTaxFee = _taxFee; // 之前的taxFee
    uint256 public _burnFee = 0;
    uint256 private _previousBurnFee = _burnFee;
    uint256 public _fundFee = 4;
    uint256 private _previousFundFee = _fundFee;
    uint256 public _lpFee = 2;
    uint256 private _previousLPFee = _lpFee;

    constructor () {
        _rOwned[_msgSender()] = _rTotal;
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    // 设置基金会地址
    function setFundAddress(address _fundAddress) public onlyOwner {
        fundAddress = _fundAddress;
    }

    function setLpAddress(address _lpAddress) public onlyOwner {
        lpAddress = _lpAddress;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcluded(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    // 总手续费
    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    // 总燃烧
    function totalBurn() public view returns (uint256) {
        return _tBurnTotal;
    }

    // tAmount 手续费
    function reflect(uint256 tAmount) public {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Excluded addresses cannot call this function"); // 验证黑名单
        (uint256 rAmount,,,,,,) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    function excludeAccount(address account) external onlyOwner() {
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeAccount(address account) external onlyOwner() {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");


        if(_isExcludedFromFee[sender])
            removeAllFee();

        _transferStandard(sender, recipient, amount);

        if(_isExcludedFromFee[sender])
            restoreAllFee();

    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        uint256 tLP = calculateLPFee(tAmount);

        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tBurn, uint256 tFund) = _getValues(tAmount);

        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _rOwned[fundAddress] = _rOwned[fundAddress].add(tFund.mul(currentRate));
        _rOwned[lpAddress] = _rOwned[lpAddress].add(tLP.mul(currentRate));

        _reflectFee(rFee, tBurn.mul(currentRate), tFee, tBurn);

        emit Transfer(sender, recipient, tTransferAmount);

        if(tBurn > 0)
            emit Transfer(sender, _burnPool, tBurn);

        if(tFund > 0)
            emit Transfer(sender, fundAddress, tFund);

        if(tLP > 0)
            emit Transfer(sender, lpAddress, tLP);
    }

    function calculateTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxFee).div(
            10 ** 3
        );
    }

    function calculateBurnFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_burnFee).div(
            10 ** 3
        );
    }

    function calculateFundFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_fundFee).div(
            10 ** 3
        );
    }

    function calculateLPFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_lpFee).div(
            10 ** 3
        );
    }

    function removeAllFee() private {
        if(_taxFee == 0 && _burnFee == 0 && _fundFee == 0 && _lpFee == 0) return;
        _previousTaxFee = _taxFee;
        _previousBurnFee = _burnFee;
        _previousFundFee = _fundFee;
        _previousLPFee = _lpFee;
        _taxFee = 0;
        _burnFee = 0;
        _fundFee = 0;
        _lpFee = 0;
    }
    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _burnFee = _previousBurnFee;
        _fundFee = _previousFundFee;
        _lpFee = _previousLPFee;
    }

    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function _reflectFee(uint256 rFee, uint256 rBurn, uint256 tFee, uint256 tBurn) private {
        _rTotal = _rTotal.sub(rFee).sub(rBurn);
        _tFeeTotal = _tFeeTotal.add(tFee);
        _tBurnTotal = _tBurnTotal.add(tBurn);

        _tTotal = _tTotal.sub(tBurn);
    }

    // 计算各种fee
    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tBurn, uint256 tFund) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tBurn, tFund);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tBurn,  tFund);
    }

    function _getTValues(uint256 tAmount) private view returns (uint256, uint256,uint256, uint256) {
        uint256 tFee = calculateTaxFee(tAmount);
        uint256 tBurn = calculateBurnFee(tAmount);
        uint256 tFund = calculateFundFee(tAmount);
        uint256 tLP = calculateLPFee(tAmount);

        uint256 tTransferAmount = tAmount-tFee-tBurn-tFund-tLP;

        return (tTransferAmount, tFee, tBurn, tFund);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tBurn, uint256 tFund) private view returns (uint256, uint256, uint256) {
        uint256 currentRate =  _getRate();

        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rBurn = tBurn.mul(currentRate);
        uint256 rFund = tFund.mul(currentRate);
        uint256 tLP = calculateLPFee(tAmount);
        uint256 rLP = tLP.mul(currentRate);

        uint256 rTransferAmount = rAmount.sub(rFee).sub(rBurn).sub(rFund).sub(rLP);

        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
}
