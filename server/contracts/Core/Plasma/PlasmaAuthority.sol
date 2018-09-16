pragma solidity ^0.4.24;

import "./../../Helpers/ValidatorManagerContract.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";

contract PlasmaAuthority {

    using SafeMath for uint256;

    /**
     * Event for block submission logging
     * @notice The event indicates the addition of a new Plasma block
     * @param blockNumber The block number of the submitted block
     * @param root The root hash of the Merkle tree containing all of a block's
     *             transactions.
     * @param timestamp The time when a block was added to the Plasma chain
     */
    event SubmittedBlock(uint256 blockNumber, bytes32 root, uint256 timestamp);

    ValidatorManagerContract vmc;

    uint256 public childBlockInterval = 1000;
    uint256 public currentBlock = 0;
    struct ChildBlock {
        bytes32 root;
        uint256 createdAt;
    }

    mapping(uint256 => ChildBlock) public childChain;

    /*
     * Modifiers
     */
    modifier isValidator() {
        require(vmc.checkValidator(msg.sender));
        _;
    }

    constructor (ValidatorManagerContract _vmc) public {
        vmc = _vmc;
    }


    /// @dev called by a Validator to append a Plasma block to the Plasma chain
    /// @param root The transaction root hash of the Plasma block being added
    function submitBlock(bytes32 root)
        public
        isValidator
    {
        // rounding to next whole `childBlockInterval`
        currentBlock = currentBlock.add(childBlockInterval)
            .div(childBlockInterval)
            .mul(childBlockInterval);

        childChain[currentBlock] = ChildBlock({
            root: root,
            createdAt: block.timestamp
        });

        emit SubmittedBlock(currentBlock, root, block.timestamp);
    }

    function getBlockRoot(uint256 blockNumber) public view returns (bytes32 root) {
        root = childChain[blockNumber].root;
    }
}
