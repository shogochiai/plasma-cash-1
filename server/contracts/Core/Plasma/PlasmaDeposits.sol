pragma solidity ^0.4.24;

import "./PlasmaAuthority.sol";

import "openzeppelin-solidity/contracts/token/ERC721/ERC721Receiver.sol";
import "./../../Helpers/Tokens/ERC20Receiver.sol";
import "./../../Libraries/Transaction/Transaction.sol";

contract PlasmaDeposits is PlasmaAuthority, ERC721Receiver, ERC20Receiver {

    /**
     * Event for coin deposit logging.
     * @notice The Deposit event indicates that a deposit block has been added
     *         to the Plasma chain
     * @param slot Plasma slot, a unique identifier, assigned to the deposit
     * @param blockNumber The index of the block in which a deposit transaction
     *                    is included
     * @param denomination Quantity of a particular coin deposited
     * @param from The address of the depositor
     * @param contractAddress The address of the contract making the deposit
     */
    event Deposit(uint64 indexed slot, uint256 blockNumber, uint256 denomination, 
                  address indexed from, address indexed contractAddress);

    // tracking of NFTs deposited in each slot
    enum Mode {
        ETH,
        ERC20,
        ERC721
    }

    uint64 public numCoins = 0;
    mapping (uint64 => Coin) coins;
    struct Coin {
        Mode mode;
        State state;
        address owner; // who owns that nft
        address contractAddress; // which contract does the coin belong to
        Exit exit;
        uint256 uid; 
        uint256 denomination;
        uint256 depositBlock;
    }

    struct Exit {
        address parentOwner; // parent owner of coin
        address owner;
        uint256 createdAt;
        uint256 bond;
        uint256 parentBlock;
        uint256 exitBlock;
    }
    enum State {
        DEPOSITED,
        EXITING,
        EXITED
    }

    modifier isTokenApproved(address _address) {
        require(vmc.allowedTokens(_address));
        _;
    }

    function onERC20Received(address _from, uint256 _amount, bytes)
        public
        isTokenApproved(msg.sender)
        returns(bytes4)
    {
        deposit(_from, 0, _amount, Mode.ERC20);
        return ERC20_RECEIVED;
    }


    function onERC721Received(address _from, uint256 _uid, bytes)
        public
        isTokenApproved(msg.sender)
        returns(bytes4)
    {
        deposit(_from, _uid, 1, Mode.ERC721);
        return ERC721_RECEIVED;
    }

    function() payable public {
        deposit(msg.sender, 0, msg.value, Mode.ETH);
    }



    /// @dev Allows anyone to deposit funds into the Plasma chain, called when
    //       contract receives ERC721
    /// @notice Appends a deposit block to the Plasma chain
    /// @param from The address of the user who is depositing a coin
    /// @param uid The uid of the ERC721 coin being deposited. This is an
    ///            identifier allocated by the ERC721 token contract; it is not
    ///            related to `slot`. If the coin is ETH or ERC20 the uid is 0
    /// @param denomination The quantity of a particular coin being deposited
    /// @param mode The type of coin that is being deposited (ETH/ERC721/ERC20)
    function deposit(
        address from, 
        uint256 uid, 
        uint256 denomination, 
        Mode mode
    )
        private
    {
        currentBlock = currentBlock.add(1);
        uint64 slot = uint64(bytes8(keccak256(abi.encodePacked(numCoins, msg.sender, from))));

        // Update state. Leave `exit` empty
        Coin storage coin = coins[slot];
        coin.uid = uid;
        coin.contractAddress = msg.sender;
        coin.denomination = denomination;
        coin.depositBlock = currentBlock;
        coin.owner = from;
        coin.state = State.DEPOSITED;
        coin.mode = mode;

        bytes memory rlpTx = Transaction.encode(slot, 0, msg.sender); // 17.5k gas
        bytes32 root = Transaction.createDepositRoot(rlpTx, 64); // depth 64 merkle root

        childChain[currentBlock] = ChildBlock({
            // save signed transaction hash as root
            // hash for deposit transactions is the hash of its slot
            root: root,
            createdAt: block.timestamp
        });

        // create a utxo at `slot`
        emit Deposit(
            slot,
            currentBlock,
            denomination,
            from,
            msg.sender
        );

        numCoins += 1;
    }

    function getPlasmaCoin(uint64 slot) external view returns(uint256, uint256, uint256, address, State, Mode, address) {
        Coin memory c = coins[slot];
        return (c.uid, c.depositBlock, c.denomination, c.owner, c.state, c.mode, c.contractAddress);
    }

}
