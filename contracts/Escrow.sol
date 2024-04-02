// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./Advert.sol";

contract EscrowService {
    using DateUtils for uint32;

    struct Escrow {
        bytes32 blockHash;
        string ipfsCiphertext;
        uint256 activationDate;
        uint256 expiryDate; // Expiry date in Unix timestamp
    }

    mapping(bytes32 => Escrow) escrows;

    event SuccessfulSubmission(bytes32 indexed blockHash, uint256 indexed activationDate, uint256 indexed expiryDate);
    event AccessGranted(bytes32 indexed blockHash, string indexed ipfsMetadata);

    function getAddress() public view returns(address){
        return address(this);
    }

    //ipfs or normal ciphertext
    function submitCiphertext(bytes32 blockHash, string memory _ipfsCiphertext, uint32 _activationDate) public {
        uint256 timestamp = _activationDate.dateToTimestamp();
        uint256 expiryTimestamp = timestamp + (3 * 30 days); // Expiry date is 3 months (90 days) after activation date
        escrows[blockHash] = Escrow(blockHash, _ipfsCiphertext, timestamp, expiryTimestamp);
        emit SuccessfulSubmission(blockHash, _activationDate, expiryTimestamp);
    }

    function getBlockTimestamp(uint256 blockNumber) internal view returns (uint256) {
        require(blockNumber <= block.number, "Block number must be less than or equal to current block");
        bytes32 blockHash = blockhash(blockNumber);
        require(blockHash != bytes32(0), "Block not found"); // Ensure block exists
        return block.timestamp; // Get the timestamp of the block
    }
    
    // Use the timestamp of a specific block in your existing function
    function requestAccess(bytes32 blockHash) public returns (string memory) {
        uint256 blockNumber = block.number - 1; // Get the number of the last mined block
        uint256 blockTimestamp = getBlockTimestamp(blockNumber);
        Escrow memory escrow = escrows[blockHash];
        require(escrow.activationDate <= blockTimestamp, "Access not yet permitted");
        require(blockTimestamp <= escrow.expiryDate, "Access expired");
        emit AccessGranted(escrow.blockHash, escrow.ipfsCiphertext);
        return escrow.ipfsCiphertext;
    }
}
