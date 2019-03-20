// Copyright (c) 2018 The VeChainThor developers

// Distributed under the GNU Lesser General Public License v3.0 software license, see the accompanying
// file LICENSE or <https://www.gnu.org/licenses/lgpl-3.0.html>

pragma solidity ^0.4.24;

import "./XAccessControl.sol";
import "./auction/ClockAuction.sol";
import "./utility/interfaces/IVIP181.sol";

contract IEnergy {
    function transfer(address _to, uint256 _amount) external;
}

contract ThunderFactory is XAccessControl {

    IEnergy constant Energy = IEnergy(uint160(bytes6("Energy")));

    // This is the token contract address for the token that is required to be held in order to apply for a node.
    IVIP181 public requiredToken;

    /// @dev The address of the ClockAuction contract that handles sales of xtoken
    ClockAuction public saleAuction;
    /// @dev The interval between two transfers
    uint64 public transferCooldown = 1 days;
    /// @dev A time delay when to start monitor after the token is transfered
    uint64 public leadTime = 4 hours;

    /// @dev The XToken param struct
    struct TokenParameters {
        uint256 minBalance;
        uint64  ripeDays;
        uint64  rewardRatio;
    }

    enum strengthLevel {
        None,
        Connect,
        Harbor,
        Consensus,
        Legacy
    }

    /// @dev Mapping from strength level to token params
    mapping(uint8 => TokenParameters) internal strengthParams;

    /// @dev The main Token struct. Each token is represented by a copy of this structure.
    struct Token {
        uint64 createdAt;
        uint64 updatedAt;

        bool onUpgrade;
        strengthLevel level;

        uint64 lastTransferTime;
    }

    /// @dev An array containing the Token struct for all XTokens in existence.
    ///      The ID of each token is actually an index into this array and starts at 1.
    Token[] internal tokens;
    /// @dev The counter of normal tokens and xtokens
    uint64 public normalTokenCount;

    /// @dev Mapping from token ID to owner and its reverse mapping.
    ///      Every address can only hold one token at most.
    mapping(uint256 => address) public idToOwner;
    mapping(address => uint256) public ownerToId;

    // Mapping from token ID to approved address
    mapping (uint256 => address) internal tokenApprovals;

    event Transfer(address indexed _from, address indexed _to, uint256 indexed _tokenId);
    event Approval(address indexed _owner, address indexed _approved, uint256 indexed _tokenId);
    event NewUpgradeApply(uint256 indexed _tokenId, address indexed _applier, strengthLevel _level, uint64 _applyTime, uint64 _applyBlockno);
    event CancelUpgrade(uint256 indexed _tokenId, address indexed _owner);
    event LevelChanged(uint256 indexed _tokenId, address indexed _owner, strengthLevel _fromLevel, strengthLevel _toLevel);
    event AuctionCancelled(uint256 indexed _auctionId, uint256 indexed _tokenId);

    constructor(address requiredTokenAddress) public {
        requiredToken = IVIP181(requiredTokenAddress);

        // the index of valid tokens should start from 1
        tokens.push(Token(0, 0, false, strengthLevel.None, 0));

        strengthParams[1] = TokenParameters(1000000 ether, 30, 0);     // Connect
        strengthParams[2] = TokenParameters(2500000 ether, 45, 8);    // Harbor
        strengthParams[3] = TokenParameters(10000000 ether, 60, 32);  // Consensus
        strengthParams[4] = TokenParameters(30000000 ether, 90, 57);  // Legacy
    }

    /// @dev To tell whether the address is holding a token(x or normal)
    function isToken(address _target)
        public
        view
        returns(bool)
    {
        return tokens[ownerToId[_target]].level > strengthLevel.None;
    }

    /// @dev Apply for a token or upgrade the holding token.
    ///      Note that bypassing a level is forbidden, it has to upgrade one by one.
    function applyUpgrade(strengthLevel _toLvl)
        external
        whenNotPaused
    {
        uint256 _tokenId = ownerToId[msg.sender];
        if (_tokenId == 0) {
            // a new token
            _tokenId = _add(msg.sender, strengthLevel.None, false);
        }

        Token storage token = tokens[_tokenId];
        require(!token.onUpgrade, "still upgrading");
        require(!saleAuction.isOnAuction(_tokenId), "cancel auction first");

        // Bypass check.
        require(
            uint8(token.level) + 1 == uint8(_toLvl)
            && _toLvl <= strengthLevel.Legacy,
            "invalid _toLvl");
        // The balance of msg.sender must meet the requirement of target level's minbalance
        require(requiredToken.balanceOf(msg.sender) >= strengthParams[uint8(_toLvl)].minBalance, "insufficient balance");

        token.onUpgrade = true;
        token.updatedAt = uint64(now);

        emit NewUpgradeApply(_tokenId, msg.sender, _toLvl, uint64(block.timestamp), uint64(block.number));
    }

    /// @dev Cancel the upgrade application.
    ///      Note that this method can be called by the token holder or admin.
    function cancelUpgrade(uint256 _tokenId)
        public
    {
        require(_exist(_tokenId), "token not exist");

        Token storage token = tokens[_tokenId];
        address _owner = idToOwner[_tokenId];

        require(token.onUpgrade, "not on upgrading");
        // The token holder or admin allowed.
        require(_owner == msg.sender || operators[msg.sender], "permission denied");

        if (token.level == strengthLevel.None) {
            _destroy(_tokenId);
        } else {
            token.onUpgrade = false;
            token.updatedAt = uint64(now);
        }

        emit CancelUpgrade(_tokenId, _owner);
    }

    function getMetadata(uint256 _tokenId)
        public
        view
        returns(address, strengthLevel, bool, bool, uint64, uint64, uint64)
    {
        if (_exist(_tokenId)) {
            Token memory token = tokens[_tokenId];
            return (
                idToOwner[_tokenId],
                token.level,
                token.onUpgrade,
                saleAuction.isOnAuction(_tokenId),
                token.lastTransferTime,
                token.createdAt,
                token.updatedAt
            );
        }
    }

    function getTokenParams(strengthLevel _level)
        public
        view
        returns(uint256, uint64, uint64)
    {
        TokenParameters memory _params = strengthParams[uint8(_level)];
        return (_params.minBalance, _params.ripeDays, _params.rewardRatio);
    }

    /// @dev To tell whether a token can be transfered.
    function canTransfer(uint256 _tokenId)
        public
        view
        returns(bool)
    {
        return
            _exist(_tokenId)
            && !tokens[_tokenId].onUpgrade
            && !blackList[idToOwner[_tokenId]] // token not in black list
            && now > (tokens[_tokenId].lastTransferTime + transferCooldown);
    }

    /// Admin Methods

    function setTransferCooldown(uint64 _cooldown)
        external
        onlyOperator
    {
        transferCooldown = _cooldown;
    }

    function setLeadTime(uint64 _leadtime)
        external
        onlyOperator
    {
        leadTime = _leadtime;
    }

    /// @dev Upgrade a token to the passed level.
    function upgradeTo(uint256 _tokenId, strengthLevel _toLvl)
        external
        onlyOperator
    {
        require(tokens[_tokenId].level < _toLvl, "invalid level");
        require(!saleAuction.isOnAuction(_tokenId), "cancel auction first");

        tokens[_tokenId].onUpgrade = false;

        _levelChange(_tokenId, _toLvl);
    }

    /// @dev Downgrade a token to the passed level.
    function downgradeTo(uint256 _tokenId, strengthLevel _toLvl)
        external
        onlyOperator
    {
        require(tokens[_tokenId].level > _toLvl, "invalid level");
        require(now > (tokens[_tokenId].lastTransferTime + leadTime), "cannot downgrade token");

        if (saleAuction.isOnAuction(_tokenId)) {
            _cancelAuction(_tokenId);
        }
        if (tokens[_tokenId].onUpgrade) {
            cancelUpgrade(_tokenId);
        }

        _levelChange(_tokenId, _toLvl);
    }

    /// @dev Adds a new token and stores it. This method should be called
    ///      when the input data is known to be valid and will generate a Transfer event.
    function addToken(address _addr, strengthLevel _lvl, bool _onUpgrade, uint64 _applyUpgradeTime, uint64 _applyUpgradeBlockno)
        external
        onlyOperator
    {
        require(!_exist(_addr), "you already hold a token");

        // This will assign ownership, and also emit the Transfer event.
        uint256 newTokenId = _add(_addr, _lvl, _onUpgrade);

        // Update token counter
        normalTokenCount++;

        // For data imgaration
        if (_onUpgrade) {
            emit NewUpgradeApply(newTokenId, _addr, _lvl, _applyUpgradeTime, _applyUpgradeBlockno);
        }
    }

    /// @dev Send VTHO bonus to the token's holder
    function sendBonusTo(address _to, uint256 _amount)
        external
        onlyOperator
    {
        require(_to != address(0), "invalid address");
        require(_amount > 0, "invalid amount");
        // Transfer VTHO from this contract to _to address, it will throw when fail
        Energy.transfer(_to, _amount);
    }

    /// Internal Methods

    function _add(address _owner, strengthLevel _lvl, bool _onUpgrade)
        internal
        returns(uint256)
    {
        Token memory _token = Token(uint64(now), uint64(now), _onUpgrade, _lvl, uint64(now));
        uint256 _newTokenId = tokens.push(_token) - 1;

        ownerToId[_owner] = _newTokenId;
        idToOwner[_newTokenId] = _owner;

        emit Transfer(0, _owner, _newTokenId);

        return _newTokenId;
    }

    function _destroy(uint256 _tokenId)
        internal
    {
        address _owner = idToOwner[_tokenId];
        delete idToOwner[_tokenId];
        delete ownerToId[_owner];
        delete tokens[_tokenId];
        //
        emit Transfer(_owner, 0, _tokenId);
    }

    function _levelChange(uint256 _tokenId, strengthLevel _toLvl)
        internal
    {
        address _owner = idToOwner[_tokenId];
        Token storage token = tokens[_tokenId];

        strengthLevel _fromLvl = token.level;
        if (_toLvl == strengthLevel.None) {
            _destroy(_tokenId);
        } else {
            token.level = _toLvl;
            token.updatedAt = uint64(now);
        }

        // Update token counter
        if(strengthLevel.Connect <= _fromLvl && _fromLvl <= strengthLevel.Legacy) {
            normalTokenCount--;
        }
        if(strengthLevel.Connect <= _toLvl && _toLvl <= strengthLevel.Legacy ) {
            normalTokenCount++;
        }

        emit LevelChanged(_tokenId, _owner, _fromLvl,  _toLvl);
    }

    function _exist(uint256 _tokenId)
        internal
        view
        returns(bool)
    {
        return idToOwner[_tokenId] > address(0);
    }

    function _exist(address _owner)
        internal
        view
        returns(bool)
    {
        return ownerToId[_owner] > 0;
    }

    /// @notice Internal function to clear current approval of a given token ID
    /// @param _tokenId uint256 ID of the token to be transferred
    function _clearApproval(uint256 _tokenId)
        internal
    {
        delete tokenApprovals[_tokenId];
    }

    /// @notice Internal function to cancel the ongoing auction
    /// @param _tokenId uint256 ID of the token
    function _cancelAuction(uint256 _tokenId)
        internal
    {
        _clearApproval(_tokenId);
        (uint256 _autionId,,,,,) = saleAuction.getAuction(_tokenId);
        emit AuctionCancelled(_autionId, _tokenId);
        saleAuction.cancelAuction(_tokenId);
    }

}
