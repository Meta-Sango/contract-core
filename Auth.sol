// SPDX-License-Identifier: MIT
pragma solidity =0.8.0;

abstract contract Auth {
    address private _owner;
    address[2] private priviledge; // 授权账户
    uint256 private authTime; // 授权时长 秒

    constructor() {
        _owner = msg.sender;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyAuth() {
        require(owner() == msg.sender, "Auth: caller is not the owner");
        require(authTime > block.timestamp, 'Auth: timeout');
        _;
    }

    // 更换owner
    function setOwner(address _newOwner) external virtual onlyAuth returns(bool) {
        _owner = _newOwner;
        return true;
    }
    // 绑定为授权账户(要求两人授权)
    function bindPriviledge() external virtual returns(bool) {
        require(priviledge[0] == address(0) || priviledge[1] == address(0), 'Auth: error');
        if(priviledge[0] == address(0)){
            priviledge[0] = msg.sender;
        } else {
            priviledge[1] = msg.sender;
        }
        return true;
    }
    // 设置授权时间
    function setAuthTime() external virtual returns(bool) {
        require(priviledge[0] == msg.sender || priviledge[1] == msg.sender, 'Tip: error');
        // 第一个人将授权时间置1，第二个人设置有效时间
        if(authTime == 1){
            authTime = block.timestamp + 60*60; // 授权一个小时
        } else {
            authTime == 1;
        }
        return true;
    }
    // 清除授权账户
    function removePriviledge() external virtual onlyAuth returns(bool) {
        priviledge = [address(0), address(0)];
        return true;
    }
}
