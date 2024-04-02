// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./NFT.sol";
import "./Escrow.sol";

// Import SafeMath library for safe arithmetic operations
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Add SafeMath library usage
using SafeMath for uint256;

contract Advert {
    address public owner;
    address escrowAddress;
    event NFTSubmitted(uint256 indexed tokenId, address indexed owner, string tokenURI);
    event DebugTokenInfo(uint256 tokenId, string ipfsLink, string secondPart, uint16 totalScore);
    event TotalScoreReceived(string ipfsLink1, string ipfsLink2, uint16 totalScore);
    event TotalScoreCheck(uint256 _tokenId, string ipfsLink1, string ipfsLink2, uint16 totalScore);
    event AdvertSet(string indexed _nftLink);
    event ExecutionTime(uint256 time);

    // Event to indicate the total score update
    event TotalScoreUpdated(string ipfsLink1, string ipfsLink2, uint16 newScore);
    // Event to emit the top 5 applications and their scores for a specific advertisement ID
    event TopApplications(uint32 indexed advertId, uint256[] tokenIds, uint16[] scores);

    // Store qualified applications and their scores
    uint256[] public qualifiedTokenIds;
    uint16[] public qualifiedScores;

    constructor() {
        //the employer should be the owner of the contract
        owner = msg.sender; 
    }

    //modifier to restrict access to some functions
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    //modifier to allow CV submission
    modifier nftSubmissionAllowed(uint32 _advertId) {
        require(nftSubmissionEnabled[_advertId], "NFT submission is not allowed for this advert");
        _;
    }
    
    //a struct for all adverts set by the employer
    struct Ad {
        uint32 advertId;
        uint256 deadline;
        string nftLink;
    }

    //initialization of an advert
    Ad internal advert;
    uint32 public numAdverts;

    //initializing the Nft contrat where nfts will be minted
    NFT nftContract;

    //initialising the Escrow contract where the second part of the cv submission is stored
    EscrowService escrow;

    //a struct for all CV applications
    struct Application {
        uint256 nftTokenId;
        string ipfsLink;
        uint16 totalScore;
        uint32 advertId; // storing the advert ID
    }

    // Define SafeMath usage
    using SafeMath for uint256;

    // Mapping to store whether NFT submission is allowed for each advertId
    mapping(uint32 => bool) public nftSubmissionEnabled;

    //given the token Id, points to the corresponding Application struct
    mapping(uint256 => Application) private tokenToApplication;

    //given the advert Id, points to the corresponding Ad struct
    mapping(uint256 => Ad) public idToAdvert;

    //given the first CV link (ipfs), points to the corresponding block hash
    mapping(string => bytes32) public cvHash;

    //given the first CV links (ipfs) points to the corresponding second link
    mapping(string => string) public cvPartOneToPartTwo;

    //given the first CV link (ipfs) points to the corresponding score
    mapping(string => uint16) public linkToScore;

    //given the pair of the two CV links (ipfs) points to the corresponding score
    mapping(string => mapping(string => uint16)) internal linkPairToScore;


    //setting the Escrow address needed to access the second part of the cv application
    function setEscrow(address _escrowAddress) public onlyOwner {
        escrow = EscrowService(_escrowAddress);
    }

    //setting the NFT contract where ipfs links will be minted following strandard ERC721
    function setNFTContract(address _nftContractAddress) public onlyOwner {
        nftContract = NFT(_nftContractAddress);
        //setNFTSubmission(true);
    }

    //allow submission of cvs
    function setNFTSubmission(uint32 _advertId, bool _enabled) public onlyOwner {
        require(idToAdvert[_advertId].advertId == _advertId, "Advert does not exist");
        nftSubmissionEnabled[_advertId] = _enabled;
    }

    //setting a job advert by the owner of the contract(employer)
    function setAdvert(uint32 _advertId,uint32 _period, string calldata _nftLink) public payable onlyOwner{

        // Record the start time
        uint256 startTime = block.timestamp;

        //period is entered in the form of  YYYY MM DD and transformed into Unix Timestamp
        uint256 deadline = getTime() + DateUtils.dateToTimestamp(_period);

        // Check if the IPFS link already exists for any advert
        require(!advertExists(_nftLink), "IPFS link already exists for another advert");

        //allows submission of CVs for a specific advert
        setNFTSubmission(_advertId, true);

        //the advert is also mined as an NFT
        advert.nftLink = setAdvertNFT(_nftLink);
        idToAdvert[_advertId] = Ad(_advertId, deadline, _nftLink);
        numAdverts++;
        emit AdvertSet(_nftLink);

        // Calculate execution time
        uint256 executionTime = block.timestamp.sub(startTime);
        emit ExecutionTime(executionTime); // Emit an event with the execution time
    }

    //minting the advert as an NFT in the specified NFT contract (address)
    function setAdvertNFT(string calldata _nft) internal onlyOwner returns (string memory) {
        nftContract.mint(msg.sender, _nft);
        return _nft;
    }
    
    //getting the advert details for a corresponding Id - nftLink is given to the advert_reading py script (local)
    function getAdvert(uint32 _advertId) public view returns (uint256, string memory) {

        //checking if an advert exists with the specified advert ID
        require(idToAdvert[_advertId].advertId == _advertId, "Advert does not exist");

        Ad storage ad = idToAdvert[_advertId];
        return (ad.deadline, ad.nftLink);
    }

    // function to allow the owner to view the application data for a specific token ID
    function getApplicationData(uint256 tokenId) public view onlyOwner returns (Application memory) {
        return tokenToApplication[tokenId];
    }

    //getting the current block's timestamp - used in the deadline Unix timestamp calculation
    function getTime() public view returns (uint256) {
        return block.timestamp;
    }

    function getAllSecondParts(uint32 _advertId) public onlyOwner {
        require(address(escrow) != address(0), "Escrow address not set");
        
        // Check if the NFT submission deadline has passed for the given advert ID
        require(block.timestamp > idToAdvert[_advertId].deadline, "NFT submission deadline has not passed yet");

        // Iterate over all token IDs for the specified advert
        uint256[] memory tokenIds = getTokenIdsForAdvert(_advertId);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Get the first link hash corresponding to this application
            bytes32 partOneHash = cvHash[tokenToApplication[tokenId].ipfsLink];
            
            // Request the second link (cv) from escrow by providing the first link's blockhash (aka confirmation of mining)
            string memory secondPart = escrow.requestAccess(partOneHash);

            // Add the second link to the mapping so the first link points to the second
            cvPartOneToPartTwo[tokenToApplication[tokenId].ipfsLink] = secondPart;
        }
    }

    // retrieve the block hash where a specific token (represented by its ID) was mined
    function getBlockHashForToken(uint256 tokenId) public view returns (bytes32) {
        require(nftContract.tokenExists(tokenId), "Token does not exist");
        return blockhash(tokenId);
    }

    function getTokenIdsForAdvert(uint32 _advertId) public view onlyOwner returns (uint256[] memory) {
        uint256 totalTokens = nftContract.totalSupply();
        uint256[] memory advertTokenIds = new uint256[](totalTokens);
        uint256 count = 0; //initializing the count of relevant tokens

        //iterating over all tokens
        for (uint256 i = 0; i < totalTokens; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            require(nftContract.tokenExists(tokenId), "Token does not exist");

            //checking if the application is for the specified advert
            if (tokenToApplication[tokenId].advertId == _advertId) {
                advertTokenIds[count] = tokenId;
                count++;
            }
        }
        //trimming the array to remove any empty slots
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = advertTokenIds[i];
        }
        return result;
    }

    //fetching all token Ids and ipfs links for a job advert with a specified Id
    function getAllIPFSLinks(uint32 _advertId) public onlyOwner returns (uint256[] memory, string[] memory, string[] memory) {
        uint256 totalTokens = nftContract.totalSupply();
        uint256[] memory tokenIds = new uint256[](totalTokens);
        string[] memory ipfsLinks = new string[](totalTokens);
        string[] memory secondParts = new string[](totalTokens);

        uint256 count = 0; // Initialize count of relevant applications

        // Iterate over all tokens
        for (uint256 i = 0; i < totalTokens; i++) {
            uint256 tokenId = nftContract.tokenByIndex(i);
            require(nftContract.tokenExists(tokenId), "Token does not exist");

            // Check if the application is for the specified advert
            if (tokenToApplication[tokenId].advertId == _advertId) {
                string memory ipfsLink = tokenToApplication[tokenId].ipfsLink;
                string memory secondPart = cvPartOneToPartTwo[ipfsLink];
                uint16 score = linkToScore[ipfsLink];
                emit DebugTokenInfo(tokenId, ipfsLink, secondPart, score);

                // Store application details
                tokenIds[count] = tokenId;
                ipfsLinks[count] = ipfsLink;
                secondParts[count] = secondPart;
                count++;
            }
        }
        return (tokenIds, ipfsLinks, secondParts);
    }

    //getting the linkPairToScore mapping for given ipfs links
    function getScoreForLinkPair(string memory ipfsLink1, string memory ipfsLink2) public view returns (uint16) {
        return linkPairToScore[ipfsLink1][ipfsLink2];
    }

    // Function to check if the given IPFS link already exists for any advert
    function advertExists(string memory _ipfsLink) internal view returns (bool) {
        // Iterate through all adverts to check if the IPFS link exists
        for (uint32 i = 0; i < numAdverts; i++) {
            if (keccak256(bytes(idToAdvert[i].nftLink)) == keccak256(bytes(_ipfsLink))) {
                return true; // IPFS link already exists for another advert
            }
        }
        return false; // IPFS link doesn't exist for any advert
    }

    //CV submission of the first ipfs link to the corresponding job advert
    function submitCvNFT(uint32 _advertId, string calldata _nft) public payable nftSubmissionAllowed(_advertId) {
        require(idToAdvert[_advertId].advertId == _advertId, "Advert does not exist");
        require(block.timestamp <= idToAdvert[_advertId].deadline, "Submissions are closed for this advert");

        //setting a token Id for the application by calling the mint function on the _nft
        uint256 tokenId = nftContract.mint(owner, _nft);

        //adding the token to point to the corresponding application
        tokenToApplication[tokenId] = Application(tokenId, _nft, 0, _advertId);

        //getting the blockhash of where the nft was minted
        bytes32 blockHash = getBlockHashForToken(tokenId);
        
        //adding the hash to the link - for retrieval
        cvHash[_nft] = blockHash;

        //emitting an event with the corresponding token id, owner address and nft link
        emit NFTSubmitted(tokenId, owner, _nft);
    }

    // updating the total score for a pair of IPFS links - for the oracle
    function updateTotalScore(string memory ipfsLink1, string memory ipfsLink2, uint16 newScore) public onlyOwner {
        //storing the new total score for the given pair of IPFS links
        linkPairToScore[ipfsLink1][ipfsLink2] = newScore;
        
        //emitting an event to indicate the total score update
        emit TotalScoreUpdated(ipfsLink1, ipfsLink2, newScore);
    }

    //receiving the total score for a pair given the token id - for the oracle
    function receiveTotalScoreForPair(uint256 tokenId, uint16 totalScore) external onlyOwner {
        require(nftContract.tokenExists(tokenId), "Token does not exist");
        
        //retrieving the total score for a given token id using the mapping
        tokenToApplication[tokenId].totalScore = totalScore;

        //emitting an event of the two links and the total score
        emit TotalScoreReceived(tokenToApplication[tokenId].ipfsLink, cvPartOneToPartTwo[tokenToApplication[tokenId].ipfsLink], totalScore);

        //updating the mapping for link score
        linkToScore[tokenToApplication[tokenId].ipfsLink] = totalScore;
    }

    //deleting a CV submission
    function removeCvApplication(uint256 tokenId, string memory ipfsLink1) public {
        require(nftContract.tokenExists(tokenId), "Token does not exist");
        
        //removing the CV application from mappings
        delete tokenToApplication[tokenId];
        delete cvHash[ipfsLink1];
        delete cvPartOneToPartTwo[ipfsLink1];
        delete linkToScore[ipfsLink1];
        
        //burnning the NFT representing the CV application
        nftContract.burn(tokenId);
    }

    //receiving the total score from the Oracle
    function checkTotalScore(uint256 _tokenId, string memory ipfsLink1, string memory ipfsLink2) external {
        emit TotalScoreCheck(_tokenId, ipfsLink1, ipfsLink2, linkPairToScore[ipfsLink1][ipfsLink2]);
    }

    //getting the top applications for a given advert and specified threshold
    function getTopApplications(uint32 _advertId, uint16 _threshold) public onlyOwner{
        //getting all token IDs for the specified advert
        uint256[] memory tokenIds = getTokenIdsForAdvert(_advertId);

        // Preallocate memory for qualifiedTokenIds and qualifiedScores arrays
        qualifiedTokenIds = new uint256[](tokenIds.length);
        qualifiedScores = new uint16[](tokenIds.length);
        uint256 qualifiedCount = 0; // Counter for qualified applications
        
        // Iterate through all applications
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint16 score = tokenToApplication[tokenId].totalScore;
            
            // Check if the score is above the threshold
            if (score >= _threshold) {
                // Store the token ID and score
                qualifiedTokenIds[qualifiedCount] = tokenId;
                qualifiedScores[qualifiedCount] = score;
                qualifiedCount++;
            }
        }

        // Resize arrays to remove unused slots
        assembly {
            mstore(qualifiedTokenIds.slot, qualifiedCount)
            mstore(qualifiedScores.slot, qualifiedCount)
        }
            // Emitting the event with the qualified token IDs and scores
        emit TopApplications(_advertId, qualifiedTokenIds, qualifiedScores);
    }

    function displayQualifiedApplications() public view returns (uint256[] memory, uint16[] memory) {
        // Returning the qualified token IDs and their scores
        return (qualifiedTokenIds, qualifiedScores);
    }
}

//a library to handle date conversion to Unix timestamp
library DateUtils {
    
    //parsing the entered YYYY-MM-DD
    function dateToTimestamp(uint32 date) internal pure returns (uint256) {

        //taking the first four digits entered
        uint16 year = uint16(date / 10000);
        
        //then the next two
        uint8 month = uint8((date / 100) % 100);

        //and the final two
        uint8 day = uint8(date % 100);

        //format requirements
        require(year >= 1970, "Year must be greater than or equal to 1970");
        require(month >= 1 && month <= 12, "Month must be between 1 and 12");
        require(day >= 1 && day <= 31, "Day must be between 1 and 31");

        //passing the parsed input to the unix timestamp calculation
        uint256 timestamp = toTimestamp(year, month, day);
        return timestamp;
    }

    //converting a date (given by year, month, and day) into a Unix timestamp
    //Unix timestamps = the number of seconds that have elapsed since January 1st, 1970 at 00:00:00 UTC.
    function toTimestamp(uint16 year, uint8 month, uint8 day) internal pure returns (uint256) {

        //calculateing the base timestamp by taking the difference (in years) from 1970 and 
        //multiplying it with the approximate number of seconds in a year (365 days * 24 hours * 60 minutes * 60 seconds).
        uint256 timestamp = (uint256(year) - 1970) * 31536000;

        //iterateing through the months prior to the given one and
        //determines the number of days and adds the corresponding number of seconds 
        for (uint8 i = 1; i < month; i++) {

            //for (leap) February adds and extra day's worth of seconds
            if (i == 2 && isLeapYear(year)) {
                timestamp += 29 * 86400;
            } else {
                timestamp += getDaysInMonth(i, year) * 86400;
            }
        }

        //adds the seconds corresponding to the days within the given month (subtracts 1 since days are counted from 1)
        timestamp += (uint256(day) - 1) * 86400;
        return timestamp;
    }

    //determining if a year is leap
    function isLeapYear(uint16 year) internal pure returns (bool) {
        return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    }

    //determining the days within a given month
    function getDaysInMonth(uint8 month, uint16 year) internal pure returns (uint8) {
        if (month == 2 && isLeapYear(year)) {
            return 29;
        } else {
            uint8[12] memory monthDayCounts = [31,28,31,30,31,30,31,31,30,31,30,31];
            return monthDayCounts[month - 1];
        }
    }
}
