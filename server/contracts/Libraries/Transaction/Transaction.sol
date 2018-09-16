pragma solidity ^0.4.24;

import "./RLP.sol";
import "./RLPEncode.sol";


library Transaction {

    using RLP for bytes;
    using RLP for RLP.RLPItem;

    struct TX {
        uint64 slot;
        address owner;
        bytes32 hash;
        uint256 prevBlock;
        uint256 denomination; 
    }

    function encode(uint64 slot, uint256 prevBlock, address owner) internal pure returns (bytes) {
        bytes memory _slot = RLPEncode.encodeUint(slot);
        bytes memory _prevBlock = RLPEncode.encodeUint(prevBlock);
        bytes memory _owner = RLPEncode.encodeAddress(owner);

        return RLPEncode.encodeList([_slot, _prevBlock, _owner]);
    }

    function createDepositRoot(bytes txBytes, uint256 depth) internal pure returns (bytes32) {
        uint256 index = getSlot(txBytes);
        bytes32 root = keccak256(abi.encodePacked(txBytes, new bytes(66))); // empty sig 66 bytes long
        bytes32 zero = keccak256(abi.encodePacked(uint256(0)));
        for (uint256 i = 0; i < depth; i++) {
            if (index % 2 == 0) {
                root = keccak256(abi.encodePacked(root, zero));
            } else {
                root = keccak256(abi.encodePacked(zero, root));
            }
            zero = keccak256(abi.encodePacked(zero, zero));
            index = index / 2;
        }
        return root;
    }


    function getTx(bytes memory txBytes) internal pure returns (TX memory) {
        RLP.RLPItem[] memory rlpTx = txBytes.toRLPItem().toList(4);
        TX memory transaction;

        transaction.slot = uint64(rlpTx[0].toUint());
        transaction.prevBlock = rlpTx[1].toUint();
        transaction.denomination = rlpTx[2].toUint();
        transaction.owner = rlpTx[3].toAddress();
        transaction.hash = keccak256(txBytes);

        return transaction;
    }

    function getHash(bytes memory txBytes) internal pure returns (bytes32 hash) {
        hash = keccak256(txBytes);
    }

    function getSlot(bytes memory txBytes) internal pure returns (uint256 slot) {
        RLP.RLPItem[] memory rlpTx = txBytes.toRLPItem().toList(4);
        slot = rlpTx[0].toUint();
    }

    function getOwner(bytes memory txBytes) internal pure returns (address owner) {
        RLP.RLPItem[] memory rlpTx = txBytes.toRLPItem().toList(4);
        owner = rlpTx[3].toAddress();
    }
}
