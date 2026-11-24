
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Raffle is VRFConsumerBaseV2Plus {
    struct Entry {
        address player;
        uint256 cumulativeStart;
        uint256 cumulativeEnd;
    }

    IERC20 public immutable token;
    AggregatorV3Interface public immutable priceFeed;
    uint256 public immutable drawTime;

    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;
    uint32 public immutable callbackGasLimit;

    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 1;
    uint256 public constant MAX_PRICE_AGE = 1 hours;

    Entry[] public entries;

    uint256 public totalWeight;
    uint256 public totalDeposited;

    uint256 public requestId;
    uint256 public randomWord;

    address public winner;

    bool public drawRequested;
    bool public randomWordReceived;
    bool public claimed;

    error InvalidClaim();
    error InvalidDeposit();
    error InvalidPrice();
    error DrawNotReady();
    error DrawAlreadyRequested();
    error InvalidRequest();

    event Deposited(address indexed who, uint256 amount, uint256 weight);
    event DrawRequested(uint256 requestId);
    event WinnerPicked(address indexed winner);
    event Claimed(address indexed winner, uint256 amount);

    constructor(
        IERC20 _token,
        AggregatorV3Interface _priceFeed,
        uint256 _drawTime,
        address _coordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit
    ) VRFConsumerBaseV2Plus(_coordinator) {
        token = _token;
        priceFeed = _priceFeed;
        drawTime = _drawTime;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        callbackGasLimit = _callbackGasLimit;
    }

    function deposit(uint256 amount) external {
        if (amount == 0 || block.timestamp >= drawTime || drawRequested) {
            revert InvalidDeposit();
        }

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (
            answer <= 0 ||
            updatedAt == 0 ||
            answeredInRound < roundId ||
            updatedAt > block.timestamp ||
            block.timestamp - updatedAt > MAX_PRICE_AGE
        ) {
            revert InvalidPrice();
        }

        uint256 weight = amount * uint256(answer);

        uint256 start = totalWeight;
        uint256 end = start + weight;

        token.transferFrom(msg.sender, address(this), amount);

        entries.push(
            Entry({
                player: msg.sender,
                cumulativeStart: start,
                cumulativeEnd: end
            })
        );

        totalWeight = end;
        totalDeposited += amount;

        emit Deposited(msg.sender, amount, weight);
    }

    function drawWinner() external returns (uint256) {
        if (block.timestamp < drawTime || entries.length == 0) {
            revert DrawNotReady();
        }

        if (drawRequested) {
            revert DrawAlreadyRequested();
        }

        drawRequested = true;

        uint256 reqId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: false
                    })
                )
            })
        );

        requestId = reqId;

        emit DrawRequested(reqId);

        return reqId;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata randomWords
    ) internal override {
        if (_requestId != requestId) {
            revert InvalidRequest();
        }

        randomWord = randomWords[0];
        randomWordReceived = true;
    }

    function claim(uint256 entryIndex) external {
        if (
            !randomWordReceived ||
            claimed ||
            entryIndex >= entries.length
        ) {
            revert InvalidClaim();
        }

        uint256 winningTicket = randomWord % totalWeight;

        Entry storage entry = entries[entryIndex];

        if (
            entry.player != msg.sender ||
            winningTicket < entry.cumulativeStart ||
            winningTicket >= entry.cumulativeEnd
        ) {
            revert InvalidClaim();
        }

        claimed = true;
        winner = msg.sender;

        uint256 prize = token.balanceOf(address(this));

        token.transfer(msg.sender, prize);

        emit WinnerPicked(msg.sender);
        emit Claimed(msg.sender, prize);
    }
}
