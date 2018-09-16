pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC721/ERC721.sol";

import "./Plasma/PlasmaFinalizeExits.sol";

contract PlasmaCash is PlasmaFinalizeExits {

    /**
     * Event to log the withdrawal of a bond
     * @param from The address of the user who withdrew bonds
     * @param amount The bond amount which has been withdrawn
     */
    event WithdrewBonds(address indexed from, uint256 amount);

    /**
     * Event to log the withdrawal of a coin
     * @param from The address of the user who withdrew bonds
     * @param mode The type of coin that is being withdrawn (ERC20/ERC721/ETH)
     * @param contractAddress The contract address where the coin is being withdrawn from
              is same as `from` when withdrawing a ETH coin
     * @param uid The uid of the coin being withdrawn if ERC721, else 0
     * @param denomination The denomination of the coin which has been withdrawn (=1 for ERC721)
     */
    event Withdrew(address indexed from, Mode mode, address contractAddress, uint uid, uint denomination);

    // Empty constructor, sets the VMC
    constructor (ValidatorManagerContract _vmc) PlasmaAuthority(_vmc) public { }


    /// @dev Withdraw a UTXO that has been exited
    /// @param slot The slot of the coin being withdrawn
    function withdraw(uint64 slot) external isState(slot, State.EXITED) {
        require(coins[slot].owner == msg.sender, "You do not own that UTXO");
        uint256 uid = coins[slot].uid;
        uint256 denomination = coins[slot].denomination;

        // Delete the coin that is being withdrawn
        Coin memory c = coins[slot];
        delete coins[slot];
        if (c.mode == Mode.ETH) {
            msg.sender.transfer(denomination);
        } else if (c.mode == Mode.ERC20) {
            ERC20(c.contractAddress).transfer(msg.sender, denomination);
        } else if (c.mode == Mode.ERC721) {
            ERC721(c.contractAddress).safeTransferFrom(address(this), msg.sender, uid);
        } else {
            revert("Invalid coin mode");
        }

        emit Withdrew(
            msg.sender,
            c.mode,
            c.contractAddress,
            uid,
            denomination
        );
    }

    /******************** BOND RELATED ********************/
    function withdrawBonds() external {
        // Can only withdraw bond if the msg.sender
        uint256 amount = balances[msg.sender].withdrawable;
        balances[msg.sender].withdrawable = 0; // no reentrancy!

        msg.sender.transfer(amount);
        emit WithdrewBonds(msg.sender, amount);
    }

}
