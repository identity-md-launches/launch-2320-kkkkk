// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Guard} from "./libraries/Guard.sol";
import {QuoteTransfer} from "./libraries/QuoteTransfer.sol";
import {IKeelHeart} from "./interfaces/IKeelHeart.sol";

interface ICheckpointToken {
    function balanceAt(address account, uint256 blockNumber) external view returns (uint256);
}

/// @notice One heartbeat for every Keel v2 pool. Immutable; the owner only tunes thresholds and quotes.
/// @dev Pots are split lazily. A round end records only its result; prizes are derived from per-quote
///      funding anchors, so `onBuy` stays O(1) regardless of how many quotes are listed.
contract KeelHeart is Guard, IKeelHeart {
    error OnlyHook();
    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();
    error InvalidAmount();
    error QuoteNotListed();
    error AlreadyListed();
    error TooManyQuotes();
    error NoRound();
    error RoundRunning();
    error NotWinner();
    error NotEligible();
    error AlreadyClaimed();
    error Insolvent();

    uint256 public constant ROUND_LENGTH = 300;
    uint256 public constant EXTENSION = 30;
    uint256 public constant MAX_REMAINING = 600;
    uint256 public constant MAX_QUOTES = 16;
    uint256 public constant PRIZE_BPS = 7000;
    uint256 public constant BPS = 10_000;
    address public immutable hook;
    address public owner;
    address public pendingOwner;

    struct Live {
        address lastBuyer;
        uint40 deadline;
        uint24 round;
        uint24 eligibleRounds;
    }

    struct LastBuy {
        address token;
        uint96 tokens;
    }

    struct Result {
        address winner;
        uint40 endBlock;
        uint24 ordinal;
        bool eligible;
        bool claimed;
        address token;
    }

    /// @dev Pot after every eligible round with ordinal <= `ordinal` was split out of it.
    struct Anchor {
        uint24 ordinal;
        uint224 amount;
    }

    Live private _live;
    LastBuy private _last;
    address[] private _quotes;
    mapping(address => bool) private _listed;
    mapping(address => uint256) private _minBuy;
    mapping(uint256 => Result) private _results;
    mapping(address => Anchor[]) private _anchors;
    mapping(address => uint256) public liability;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MinBuySet(address indexed quote, uint256 amount);
    event QuoteListed(address indexed quote);
    event Beat(
        uint256 indexed round,
        address indexed buyer,
        address indexed token,
        address quote,
        uint256 grossQuoteIn,
        uint256 deadline
    );
    event Funded(uint256 indexed round, address indexed quote, address indexed from, uint256 amount);
    event Flatline(uint256 indexed round, address indexed winner, bool eligible);
    event Claimed(uint256 indexed round, address indexed winner, address indexed to);

    constructor(address hook_, address owner_) {
        if (hook_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        hook = hook_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function setMinBuy(address quote, uint256 rawAmount) external onlyOwner {
        _minBuy[quote] = rawAmount;
        emit MinBuySet(quote, rawAmount);
    }

    function addQuote(address quote) external onlyOwner {
        if (_listed[quote]) revert AlreadyListed();
        if (_quotes.length >= MAX_QUOTES) revert TooManyQuotes();
        _listed[quote] = true;
        _quotes.push(quote);
        emit QuoteListed(quote);
    }

    /// @inheritdoc IKeelHeart
    function onBuy(address token, address quote, address buyer, uint256 grossQuoteIn, uint256 tokensOut)
        external
    {
        if (msg.sender != hook) revert OnlyHook();
        uint256 threshold = _minBuy[quote];
        if (threshold == 0 || grossQuoteIn < threshold || buyer == address(0)) return;
        Live memory live = _live;
        if (live.deadline != 0 && block.timestamp >= live.deadline) _finish(live);
        uint256 deadline;
        if (live.deadline == 0) {
            live.round += 1;
            deadline = block.timestamp + ROUND_LENGTH;
        } else {
            deadline = live.deadline + EXTENSION;
            uint256 cap = block.timestamp + MAX_REMAINING;
            if (deadline > cap) deadline = cap;
        }
        live.deadline = uint40(deadline);
        live.lastBuyer = buyer;
        _live = live;
        _last = LastBuy(token, tokensOut > type(uint96).max ? type(uint96).max : uint96(tokensOut));
        emit Beat(live.round, buyer, token, quote, grossQuoteIn, deadline);
    }

    /// @notice Adds to the running pot of a listed quote. ETH uses `msg.value` with quote = address(0).
    function fund(address quote, uint256 amount) external payable nonReentrant {
        if (!_listed[quote]) revert QuoteNotListed();
        if (amount == 0) revert InvalidAmount();
        if (quote == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            uint256 before = QuoteTransfer.balance(quote, address(this));
            QuoteTransfer.pull(quote, msg.sender, amount);
            if (QuoteTransfer.balance(quote, address(this)) != before + amount) {
                revert QuoteTransfer.NonStandardQuote();
            }
        }
        Live memory live = _live;
        uint256 pot = _potAt(quote, live.eligibleRounds) + amount;
        if (pot > type(uint224).max) revert InvalidAmount();
        Anchor[] storage anchors = _anchors[quote];
        uint256 count = anchors.length;
        if (count != 0 && anchors[count - 1].ordinal == live.eligibleRounds) {
            anchors[count - 1].amount = uint224(pot);
        } else {
            anchors.push(Anchor(live.eligibleRounds, uint224(pot)));
        }
        liability[quote] += amount;
        emit Funded(live.round, quote, msg.sender, amount);
    }

    /// @notice Ends the round once its deadline has passed. The next round starts on the next counted buy.
    function end() external nonReentrant {
        Live memory live = _live;
        if (live.deadline == 0) revert NoRound();
        if (block.timestamp < live.deadline) revert RoundRunning();
        _finish(live);
        _live = live;
    }

    /// @notice Pays every listed quote's prize of `round` to `to`. Winner only, once.
    function claim(uint256 round, address to) external nonReentrant {
        Result storage stored = _results[round];
        if (stored.winner == address(0) || msg.sender != stored.winner) revert NotWinner();
        if (!stored.eligible) revert NotEligible();
        if (stored.claimed) revert AlreadyClaimed();
        if (to == address(0) || to == address(this)) revert InvalidAddress();
        stored.claimed = true;
        uint256 ordinal = stored.ordinal;
        uint256 count = _quotes.length;
        for (uint256 i; i < count; ++i) {
            address quote = _quotes[i];
            uint256 amount = _prizeAt(quote, ordinal);
            if (amount == 0) continue;
            liability[quote] -= amount;
            _pay(quote, to, amount);
        }
        emit Claimed(round, msg.sender, to);
    }

    function state()
        external
        view
        returns (uint256 round, uint256 deadline, address lastBuyer, address lastToken)
    {
        Live memory live = _live;
        return (live.round, live.deadline, live.lastBuyer, _last.token);
    }

    function lastTokens() external view returns (uint256) {
        return _last.tokens;
    }

    function eligibleRounds() external view returns (uint256) {
        return _live.eligibleRounds;
    }

    function quoteList() external view returns (address[] memory) {
        return _quotes;
    }

    function potOf(address quote) external view returns (uint256) {
        return _potAt(quote, _live.eligibleRounds);
    }

    function minBuy(address quote) external view returns (uint256) {
        return _minBuy[quote];
    }

    function prizeOf(uint256 round, address quote) external view returns (uint256) {
        Result storage stored = _results[round];
        if (!stored.eligible) return 0;
        return _prizeAt(quote, stored.ordinal);
    }

    function result(uint256 round)
        external
        view
        returns (address winner, address token, uint256 endBlock, bool eligible, bool claimed)
    {
        Result storage stored = _results[round];
        return (stored.winner, stored.token, stored.endBlock, stored.eligible, stored.claimed);
    }

    function anchorCount(address quote) external view returns (uint256) {
        return _anchors[quote].length;
    }

    /// @dev Settles the running round into `live` (memory). The caller persists `live`.
    function _finish(Live memory live) private {
        LastBuy memory last = _last;
        // Only completed blocks count: the token refuses the current block, so nothing done inside
        // this block can change eligibility.
        uint256 held = ICheckpointToken(last.token).balanceAt(live.lastBuyer, block.number - 1);
        bool eligible = held >= last.tokens;
        uint24 ordinal;
        if (eligible) {
            live.eligibleRounds += 1;
            ordinal = live.eligibleRounds;
        }
        _results[live.round] =
            Result(live.lastBuyer, uint40(block.number), ordinal, eligible, false, last.token);
        live.deadline = 0;
        emit Flatline(live.round, live.lastBuyer, eligible);
    }

    /// @dev Pot of `quote` after all eligible rounds with ordinal <= `ordinal` were split out.
    function _potAt(address quote, uint256 ordinal) private view returns (uint256 amount) {
        (bool found, uint256 anchorOrdinal, uint256 anchored) = _anchorBefore(quote, ordinal + 1);
        if (!found) return 0;
        amount = anchored;
        for (uint256 i = anchorOrdinal; i < ordinal; ++i) {
            uint256 prize = amount * PRIZE_BPS / BPS;
            if (prize == 0) break;
            amount -= prize;
        }
    }

    /// @dev Prize of the eligible round with ordinal `ordinal` (>= 1): 70% of the pot before its split.
    function _prizeAt(address quote, uint256 ordinal) private view returns (uint256) {
        if (ordinal == 0) return 0;
        return _potAt(quote, ordinal - 1) * PRIZE_BPS / BPS;
    }

    /// @dev Latest anchor with ordinal < `before`.
    function _anchorBefore(address quote, uint256 before)
        private
        view
        returns (bool found, uint256 ordinal, uint256 amount)
    {
        Anchor[] storage anchors = _anchors[quote];
        uint256 low;
        uint256 high = anchors.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (anchors[mid].ordinal < before) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return (false, 0, 0);
        Anchor storage anchor = anchors[low - 1];
        return (true, anchor.ordinal, anchor.amount);
    }

    function _pay(address quote, address to, uint256 amount) private {
        uint256 beforeSelf = QuoteTransfer.balance(quote, address(this));
        uint256 beforeRecipient = quote == address(0) ? 0 : QuoteTransfer.balance(quote, to);
        if (beforeSelf < liability[quote] + amount) revert Insolvent();
        QuoteTransfer.pay(quote, to, amount);
        uint256 afterSelf = QuoteTransfer.balance(quote, address(this));
        if (
            quote != address(0)
                && (afterSelf != beforeSelf - amount
                    || QuoteTransfer.balance(quote, to) != beforeRecipient + amount)
        ) revert QuoteTransfer.NonStandardQuote();
        if (afterSelf < liability[quote]) revert Insolvent();
    }
}
