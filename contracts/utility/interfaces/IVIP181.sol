// Copyright (c) 2018 The VeChainThor developers

// Distributed under the GNU Lesser General Public License v3.0 software license, see the accompanying
// file LICENSE or <https://www.gnu.org/licenses/lgpl-3.0.html>

pragma solidity ^0.4.24;

import "./IVIP181Basic.sol";


 /// @title VIP181 Non-Fungible Token Standard, optional enumeration extension
contract IVIP181Enumerable is IVIP181Basic {
    function totalSupply() public view returns (uint256);
    function tokenOfOwnerByIndex(address _owner, uint256 _index) public view returns (uint256 _tokenId);

    function tokenByIndex(uint256 _index) public view returns (uint256);
}


/// @title VIP181 Non-Fungible Token Standard, optional metadata extension
contract IVIP181Metadata is IVIP181Basic {
    function name() external view returns (string _name);
    function symbol() external view returns (string _symbol);
    function tokenURI(uint256 _tokenId) public view returns (string);
}


/// @title EVIP181 Non-Fungible Token Standard, full implementation interface
contract IVIP181 is IVIP181Basic, IVIP181Enumerable, IVIP181Metadata {}
