// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface ISafetyNetVault {
    function protocolExecuteRestitution(address recipient, uint256 amount) external;
}

contract GHM21Protocol {
    error Denied();

    struct Node {
        address upliner;
        uint256 currentTier;
        uint256 totalPHProvided;
        uint256 totalGHReceived;
        uint256 cycleStep;
        uint256 cooldownExpiry;
        uint256 pendingBalance;
        bool isGraduated;
        bool isPaused;
        bool hasProvidedHelp;
        bool isActive;
        bool hasPendingLOH;
    }

    struct NodeExtended {
        uint256 originalBaselineTier; 
        uint256 activeWindowExpiry;   
        uint256 activeSliceNeed;
        uint256 directCount;          
        uint256 directVolume;         
        uint8 rank;                 // 0 = Member, 1 = Guider, 2 = Leader, 3 = Manager
        uint8 verifiedPillarsCount;   
        bool isInQueue;               
        uint8 currentLane;            
        bool hasClaimedRestitution;   
    }

    struct ParkedSlot {
        uint256 tier;
        uint256 pendingBalance;
        uint256 activeSliceNeed;
        uint256 cycleStep;
        uint256 originalBaselineTier;
        bool isParked;
    }

    struct TaskSubmission {
        address performer;
        string taskTitle;
        string proofLink;
        uint256 tipCount;
        uint256 totalTipsCollected;
        bool isVerified;
        uint256 likeCount;
        uint256 verifiedAt;
        bool isRejected;
        bool isClearanceTask;
    }

    struct UserTxRecord {
        uint8 txType;
        uint256 amount;
        uint256 timestamp;
    }

    uint256 private constant LIFETIME_VOLUME_CAP = 21_000_000 * 10**18;
    uint256 private constant MILESTONE_2_1M_VOL  = 2_100_000 * 10**18;
    uint256 private constant MAX_TIER_INITIAL    = 5_000 * 10**18;
    uint256 private constant MAX_TIER_EXPANDED   = 10_000 * 10**18;
    uint256 private constant MAX_TRANCHE_BLOCK   = 100 * 10**18;
    uint256 private constant MIN_ENTRY_TIER      = 20 * 10**18;  
    uint256 private constant MIN_RECOMMIT_TIER   = 10 * 10**18;  
    uint256 private constant ACTIVENESS_WINDOW   = 24 hours;
    uint256 private constant CYCLE_COOLDOWN      = 30 minutes;
    uint256 private constant GRACE_PERIOD        = 30 minutes;
    uint256 private constant DORMANT_THRESHOLD   = 90 days;
    uint256 private constant RELIEF_CLAIM_WINDOW = 30 days;

    IERC20 internal immutable usdtToken;
    address internal immutable safetyNetVault;
    address internal immutable operationsWallet;
    uint256 internal immutable launchTimestamp;
    address internal auditorAddress;

    bool internal sunsetReached;
    uint256 internal totalProtocolVolume;
    uint256 internal totalRegisteredNodes;
    bool internal managerSurplusDistributed;
    uint256 internal lastProtocolActivityTime;

    mapping(address => Node) internal nodes;
    mapping(address => NodeExtended) public _nodeExt;
    mapping(address => ParkedSlot[]) internal parkedSlots;
    mapping(address => UserTxRecord[]) internal userTxHistory;
    mapping(address => string) public nodeTelegramId;
    mapping(bytes32 => address) internal telegramIdOwner;
    mapping(address => bool) public isTaskVerifier;
    mapping(bytes32 => bool) internal usedProofLinks;

    mapping(address => bool) internal inL1Map;
    mapping(address => bool) internal inL2Map;
    mapping(address => uint256) internal activeL2QueueIndexPlusOne;
    mapping(address => uint256) public lane2SliceNeed;
    mapping(address => uint256) internal stepGHReceived;
    mapping(address => uint256) internal pausedCooldownRemaining;
    mapping(address => uint256) internal lastPayoutAmount;
    mapping(address => bool) internal cycleTaskCleared;
    mapping(address => uint8) internal completedPillarsMask;
    mapping(address => bool) internal hasQualifiedPH;
    mapping(address => uint8) internal recommitsDoneInCycle;

    address[] internal allRegisteredNodes;
    address[] internal newcomerQueue;
    address[] internal resumedQueue;
    address[] internal surplusQueue;
    uint256 internal resumedHead;
    uint256 internal lane1Head;
    uint256 internal lane2Head;
    mapping(address => bool) internal inResumedQueue;

    TaskSubmission[] public _tasks;
    mapping(uint256 => uint8) internal taskPillarType;
    mapping(uint256 => mapping(address => bool)) public hasTippedTask;
    mapping(uint256 => mapping(address => bool)) public hasLikedTask;

    event ProvideHelpExecuted(address indexed donor, address indexed seeker, uint256 amount, uint256 seekerPayout, bool isRecommitting);
    event PayoutDispatched(address indexed seeker, uint256 payoutAmount, uint256 remainingBalance, uint8 lane);
    event LOHSubmitted(address indexed node);

    constructor(
        address _usdtToken,
        address _safetyNetVault,
        address _operationsWallet,
        address _auditorAddress,
        address[] memory _v1Leaders,
        address[] memory _v1Guiders
    ) {
        usdtToken = IERC20(_usdtToken);
        safetyNetVault = _safetyNetVault;
        operationsWallet = _operationsWallet;
        launchTimestamp = block.timestamp;
        auditorAddress = _auditorAddress != address(0) ? _auditorAddress : _operationsWallet;
        lastProtocolActivityTime = block.timestamp;

        nodes[_operationsWallet].isActive = true;
        nodes[_operationsWallet].isGraduated = true;
        nodes[_operationsWallet].cycleStep = 1;
        _nodeExt[_operationsWallet].rank = 3;
        cycleTaskCleared[_operationsWallet] = true;
        hasQualifiedPH[_operationsWallet] = true;
        allRegisteredNodes.push(_operationsWallet);
        totalRegisteredNodes = 1;

        for (uint256 i = 0; i < _v1Leaders.length; i++) {
            address ldr = _v1Leaders[i];
            if (ldr != address(0)) {
                nodes[ldr].isGraduated = true;
                _nodeExt[ldr].rank = 2;
                _nodeExt[ldr].verifiedPillarsCount = 2;
            }
        }
        for (uint256 j = 0; j < _v1Guiders.length; j++) {
            address gdr = _v1Guiders[j];
            if (gdr != address(0)) {
                nodes[gdr].isGraduated = true;
                if (_nodeExt[gdr].rank < 1) _nodeExt[gdr].rank = 1;
                if (_nodeExt[gdr].verifiedPillarsCount < 1) _nodeExt[gdr].verifiedPillarsCount = 1;
            }
        }
    }

    function _req(bool _cond) internal pure {
        if (!_cond) revert Denied();
    }

    function _recordTx(address _user, uint8 _type, uint256 _amt) internal {
        userTxHistory[_user].push(UserTxRecord(_type, _amt, block.timestamp));
    }

    function _onlyTaskVerifierOrAuditor() internal view {
        _req(msg.sender == auditorAddress || msg.sender == operationsWallet || isTaskVerifier[msg.sender]);
    }

    function setAuditorAddress(address _newAuditor) external {
        _req(msg.sender == operationsWallet && _newAuditor != address(0));
        auditorAddress = _newAuditor;
    }

    function setTaskVerifier(address _verifier, bool _status) external {
        _req((msg.sender == auditorAddress || msg.sender == operationsWallet) && _verifier != address(0));
        isTaskVerifier[_verifier] = _status;
    }

    function _normalizeTgHash(string memory _raw) internal pure returns (bytes32) {
        bytes memory b = bytes(_raw);
        uint256 start = (b.length > 0 && b[0] == "@") ? 1 : 0;
        _req(b.length >= start + 4 && b.length <= 36);
        bytes memory out = new bytes(b.length - start);
        for (uint256 i = start; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) c += 32;
            _req((c >= 48 && c <= 57) || (c >= 97 && c <= 122) || c == 95 || c == 45);
            out[i - start] = bytes1(c);
        }
        return keccak256(out);
    }

    function setTelegramId(string calldata _telegramId) external {
        bytes32 newHash = _normalizeTgHash(_telegramId);
        address currentOwner = telegramIdOwner[newHash];
        require(currentOwner == address(0) || currentOwner == msg.sender);

        if (bytes(nodeTelegramId[msg.sender]).length >= 4) {
            bytes32 oldHash = _normalizeTgHash(nodeTelegramId[msg.sender]);
            if (telegramIdOwner[oldHash] == msg.sender) delete telegramIdOwner[oldHash];
        }

        telegramIdOwner[newHash] = msg.sender;
        nodeTelegramId[msg.sender] = _telegramId;
    }

    function _setL2Status(address _u, bool _status) internal {
        if (_status && !inL2Map[_u]) {
            inL2Map[_u] = true;
        } else if (!_status && inL2Map[_u]) {
            inL2Map[_u] = false;
            activeL2QueueIndexPlusOne[_u] = 0;
        }
    }

    function _enqueueL2(address _user) internal {
        if (!inL2Map[_user]) {
            surplusQueue.push(_user);
            activeL2QueueIndexPlusOne[_user] = surplusQueue.length;
            _setL2Status(_user, true);
        }
    }

    function _isActiveL2QueueEntry(uint256 _index, address _user) internal view returns (bool) {
        return activeL2QueueIndexPlusOne[_user] == _index + 1;
    }

    function _capL2Slice(uint256 _bal) internal pure returns (uint256) {
        return _bal > MAX_TRANCHE_BLOCK ? MAX_TRANCHE_BLOCK : _bal;
    }

    function _capSlice(uint256 _bal) internal pure returns (uint256) {
        return _bal > MAX_TRANCHE_BLOCK ? MAX_TRANCHE_BLOCK : _bal;
    }

    function _initNewNode(address _user, address _upliner) internal {
        Node storage node = nodes[_user];
        if (node.isActive) return;

        address validUp = (_upliner != address(0) && _upliner != _user && (nodes[_upliner].isActive || _upliner == operationsWallet))
            ? _upliner
            : operationsWallet;

        address trace = validUp;
        for (uint8 i = 0; i < 9; i++) {
            if (trace == address(0)) break;
            if (trace == _user) { validUp = operationsWallet; break; }
            trace = nodes[trace].upliner;
        }

        node.upliner = validUp;
        node.isActive = true;
        node.cycleStep = 1;
        cycleTaskCleared[_user] = true;
        allRegisteredNodes.push(_user);
        totalRegisteredNodes += 1;
        _nodeExt[validUp].directCount += 1;
    }

    function registerNode(address _upliner) external {
        _req(!sunsetReached && !nodes[msg.sender].isActive && _upliner != msg.sender);
        _initNewNode(msg.sender, _upliner);
    }

    function _isValidL1(address _u) internal view returns (bool) {
        return inL1Map[_u] && !nodes[_u].hasPendingLOH && nodes[_u].pendingBalance > 0;
    }

    function _isValidL2(address _u) internal view returns (bool) {
        // A pending LOH from an L1 payout must not block a user who already
        // holds an active L2 position. A completed L2 tranche still removes
        // the user from L2 and requires LOH before rejoining at the tail.
        return inL2Map[_u] && lane2SliceNeed[_u] > 0 && nodes[_u].pendingBalance > 0;
    }

    function _isQueuedL1(address _u) internal view returns (bool) {
        return inL1Map[_u] && nodes[_u].pendingBalance > 0;
    }

    function _isQueuedL2(address _u) internal view returns (bool) {
        return inL2Map[_u] && lane2SliceNeed[_u] > 0 && nodes[_u].pendingBalance > 0;
    }

    function _syncQueueFlags(address _user) internal {
        bool l1 = inL1Map[_user];
        bool l2 = inL2Map[_user];
        _nodeExt[_user].isInQueue = l1 || l2;
        _nodeExt[_user].currentLane = l1 ? 1 : (l2 ? 2 : 0);
    }

    function _advanceStaleHeads() internal {
        while (resumedHead < resumedQueue.length) {
            address u = resumedQueue[resumedHead];
            if (!inResumedQueue[u] || !inL1Map[u] || nodes[u].pendingBalance == 0) {
                inResumedQueue[u] = false;
                resumedHead++;
            } else if (nodes[u].hasPendingLOH) break;
            else break;
        }
        while (lane1Head < newcomerQueue.length) {
            address u = newcomerQueue[lane1Head];
            if (!inL1Map[u] || nodes[u].pendingBalance == 0) { lane1Head++; _syncQueueFlags(u); }
            else if (nodes[u].hasPendingLOH) break;
            else break;
        }
        while (lane2Head < surplusQueue.length) {
            address u = surplusQueue[lane2Head];
            if (!_isActiveL2QueueEntry(lane2Head, u) || !inL2Map[u] || lane2SliceNeed[u] == 0 || nodes[u].pendingBalance == 0) { lane2Head++; _syncQueueFlags(u); }
            else if (nodes[u].hasPendingLOH) break;
            else break;
        }
    }

    function _handleLOHUnlock(address _user) internal {
        Node storage node = nodes[_user];
        NodeExtended storage ext = _nodeExt[_user];

        node.hasPendingLOH = false;
        node.hasProvidedHelp = true;

        bool inL1 = inL1Map[_user];
        bool inL2 = inL2Map[_user];
        uint256 l1Slice = inL1 ? ext.activeSliceNeed : 0;
        uint256 remForL2 = node.pendingBalance > l1Slice ? (node.pendingBalance - l1Slice) : 0;

        if (remForL2 > 0) {
            if (!inL2) { _enqueueL2(_user); inL2 = true; }
            lane2SliceNeed[_user] = _capL2Slice(remForL2);
            if (!inL1) ext.activeSliceNeed = lane2SliceNeed[_user];
        } else {
            lane2SliceNeed[_user] = 0;
            _setL2Status(_user, false);
            inL2 = false;
            if (!inL1) ext.activeSliceNeed = 0;
        }

        ext.isInQueue = inL1 || inL2;
        ext.currentLane = inL1 ? 1 : (inL2 ? 2 : 0);

        if (pausedCooldownRemaining[_user] > 0) {
            node.cooldownExpiry = block.timestamp + pausedCooldownRemaining[_user];
            pausedCooldownRemaining[_user] = 0;
            ext.activeWindowExpiry = 0;
        } else if (node.cooldownExpiry <= block.timestamp) {
            if (node.pendingBalance == 0 || stepGHReceived[_user] >= getExpectedRecommit(_user)) {
                _advanceSeekerCycleState(_user);
            } else {
                ext.activeWindowExpiry = 0;
            }
        }

        _recordTx(_user, 4, lastPayoutAmount[_user]);
        emit LOHSubmitted(_user);
    }

    function submitLetterOfHappiness() external {
        _req(nodes[msg.sender].hasPendingLOH);
        _handleLOHUnlock(msg.sender);
    }

    function getExpectedRecommit(address _account) public view returns (uint256) {
        if (nodes[_account].totalPHProvided == 0) return MIN_ENTRY_TIER;
        uint256 base = _nodeExt[_account].originalBaselineTier;
        if (base == 0) base = nodes[_account].currentTier;
        uint256 rec = base / 2;
        return rec < MIN_RECOMMIT_TIER ? MIN_RECOMMIT_TIER : rec;
    }

    function isNodeEligibleForRecommit(address _account) public view returns (bool) {
        Node storage n = nodes[_account];
        if (!n.isActive || n.totalPHProvided == 0 || n.hasPendingLOH || n.cooldownExpiry > 0 || pausedCooldownRemaining[_account] > 0 || inL1Map[_account]) return false;
        if (recommitsDoneInCycle[_account] >= 2) return false;
        return (n.cycleStep == 2 || n.cycleStep == 3) && (n.pendingBalance == 0 || stepGHReceived[_account] >= getExpectedRecommit(_account));
    }

    function provideHelp(uint256 _amount, uint256 _isRecommitFlag, address _upliner) external {
        _req(!sunsetReached);
        Node storage donor = nodes[msg.sender];
        NodeExtended storage ext = _nodeExt[msg.sender];

        _req(!donor.hasPendingLOH && _amount <= (totalProtocolVolume >= MILESTONE_2_1M_VOL ? MAX_TIER_EXPANDED : MAX_TIER_INITIAL));

        lastProtocolActivityTime = block.timestamp;
        bool isRecommitment = false;

        if (!donor.isActive) _initNewNode(msg.sender, _upliner);
        require(_amount >= (donor.totalPHProvided == 0 ? MIN_ENTRY_TIER : MIN_RECOMMIT_TIER));

        bool hadCooldown = donor.cooldownExpiry > 0;
        if (hadCooldown) {
            _req(block.timestamp >= donor.cooldownExpiry);
            if (block.timestamp > donor.cooldownExpiry + GRACE_PERIOD) donor.hasProvidedHelp = false;
            donor.cooldownExpiry = 0;
            donor.cycleStep = 1;
            recommitsDoneInCycle[msg.sender] = 0;
        }
        if (ext.activeWindowExpiry > 0 && block.timestamp > ext.activeWindowExpiry) {
            donor.hasProvidedHelp = false;
            ext.activeWindowExpiry = 0;
        }

        if (_isRecommitFlag == 1 && !hadCooldown && isNodeEligibleForRecommit(msg.sender) && _amount == getExpectedRecommit(msg.sender)) {
            isRecommitment = true;
            if (ext.originalBaselineTier == 0) ext.originalBaselineTier = donor.currentTier;
            donor.currentTier = _amount;
            recommitsDoneInCycle[msg.sender] += 1;
            donor.cycleStep = recommitsDoneInCycle[msg.sender] == 1 ? 2 : 3;
        } else if (donor.pendingBalance > 0 && !hadCooldown) {
            (address nextSeeker,) = _peekNextSeeker(address(0));
            _req(_amount % (10 * 10**18) == 0 && nextSeeker != msg.sender);
            if (ext.originalBaselineTier > 0) _req(_amount <= (ext.originalBaselineTier * 25) / 10);

            inL1Map[msg.sender] = false;
            _setL2Status(msg.sender, false);
            ext.isInQueue = false;
            ext.currentLane = 0;

            parkedSlots[msg.sender].push(ParkedSlot({
                tier: donor.currentTier,
                pendingBalance: donor.pendingBalance,
                activeSliceNeed: _capSlice(donor.pendingBalance),
                cycleStep: donor.cycleStep > 0 ? donor.cycleStep : 1,
                originalBaselineTier: ext.originalBaselineTier > 0 ? ext.originalBaselineTier : donor.currentTier,
                isParked: true
            }));
            _recordTx(msg.sender, 5, donor.currentTier);

            donor.pendingBalance = 0;
            ext.activeSliceNeed = 0;
            lane2SliceNeed[msg.sender] = 0;
            donor.currentTier = _amount;
            donor.cycleStep = 1;
            recommitsDoneInCycle[msg.sender] = 0;
            ext.originalBaselineTier = _amount;
        } else {
            _req(_amount % (10 * 10**18) == 0);
            uint256 prevBase = ext.originalBaselineTier > 0 ? ext.originalBaselineTier : donor.currentTier;
            if (prevBase > 0) _req(_amount <= (prevBase * 25) / 10);
            ext.originalBaselineTier = _amount;
            donor.currentTier = _amount;
            donor.cycleStep = 1;
            recommitsDoneInCycle[msg.sender] = 0;
        }

        stepGHReceived[msg.sender] = 0;

        uint256 totalPaidByDonor = isRecommitment ? (_amount + (_amount * 4) / 100) : _amount;
        _req(usdtToken.transferFrom(msg.sender, address(this), totalPaidByDonor));
        _distributeMatrixOrSupport(msg.sender, _amount, isRecommitment ? ((_amount * 4) / 100) : _amount, isRecommitment);

        totalProtocolVolume += totalPaidByDonor;
        donor.totalPHProvided += _amount;
        donor.hasProvidedHelp = true;
        ext.activeWindowExpiry = 0;
        _recordTx(msg.sender, isRecommitment ? 2 : 1, totalPaidByDonor);

        address up = donor.upliner;
        if (!hasQualifiedPH[msg.sender] && _amount >= MIN_ENTRY_TIER) {
            hasQualifiedPH[msg.sender] = true;
            if (up != address(0)) {
                cycleTaskCleared[up] = true;
                if (_nodeExt[up].verifiedPillarsCount < 4) _nodeExt[up].verifiedPillarsCount += 1;
            }
        }

        if (up != address(0)) {
            _nodeExt[up].directVolume += _amount;
            _updateLeadershipRank(up);
        }

        uint256 cashToDispatch = isRecommitment ? _amount : (_amount * 65) / 100;
        uint256 seekerEntitlement = isRecommitment ? (_amount * 165) / 100 : (_amount * 65) / 100;

        address matchedSeeker = _dispatchAndQueue(msg.sender, cashToDispatch, seekerEntitlement);
        if (totalProtocolVolume >= LIFETIME_VOLUME_CAP) sunsetReached = true;

        emit ProvideHelpExecuted(msg.sender, matchedSeeker, totalPaidByDonor, seekerEntitlement, isRecommitment);
    }

    function _getLevelRateBps(uint8 _lvl) internal pure returns (uint256) {
        if (_lvl == 1) return 100;
        if (_lvl == 2) return 30;
        if (_lvl == 3) return 10;
        if (_lvl == 4) return 8;
        if (_lvl == 5) return 6;
        if (_lvl == 6) return 5;
        if (_lvl <= 8) return 4;
        return 3;
    }

    function _distributeMatrixOrSupport(address _donor, uint256 _phBaseAmt, uint256 _val, bool _isSupportFee) internal {
        uint256 baseOps;
        uint256 baseVault;
        uint256 maxMatrixPool;

        if (_isSupportFee) {
            uint256 q = _val / 4;
            baseOps = q;
            maxMatrixPool = q * 2;
            baseVault = _val - (q * 3);
        } else {
            usdtToken.transfer(_donor, (_val * 15) / 100);
            baseOps = (_val * 2) / 100;
            baseVault = (_val * 1) / 100;
            maxMatrixPool = (_val * 17) / 100;
        }

        uint256 paidMatrix = 0;
        address curr = nodes[_donor].upliner;
        uint8 rewardLevel = 1;
        uint8 hops = 0;

        while (curr != address(0) && rewardLevel <= 9 && hops < 18) {
            hops++;
            if (curr != _donor && _isNodeBonusEligible(curr, rewardLevel)) {
                uint256 upBase = _nodeExt[curr].originalBaselineTier > nodes[curr].currentTier
                    ? _nodeExt[curr].originalBaselineTier
                    : nodes[curr].currentTier;
                if (curr == operationsWallet || upBase > _phBaseAmt) upBase = _phBaseAmt;

                uint256 reward = _isSupportFee
                    ? ((_phBaseAmt > 0) ? ((((rewardLevel == 1) ? (_val / 4) : ((_val / 4) / 8)) * upBase) / _phBaseAmt) : 0)
                    : ((upBase * _getLevelRateBps(rewardLevel)) / 1000);

                if (reward > 0 && paidMatrix + reward <= maxMatrixPool) {
                    usdtToken.transfer(curr, reward);
                    paidMatrix += reward;
                }
                if (curr == operationsWallet) break;
                rewardLevel++;
            }
            curr = nodes[curr].upliner;
        }

        uint256 leftover = maxMatrixPool > paidMatrix ? (maxMatrixPool - paidMatrix) : 0;
        uint256 opsExtra = leftover / 4;
        usdtToken.transfer(operationsWallet, baseOps + opsExtra);
        usdtToken.transfer(safetyNetVault, baseVault + (leftover - opsExtra));
    }

    function resumeParkedSlot(uint256 _slotIndex) external {
        Node storage node = nodes[msg.sender];
        NodeExtended storage ext = _nodeExt[msg.sender];
        _req(!sunsetReached && node.pendingBalance == 0 && !ext.isInQueue && !node.hasPendingLOH && _slotIndex < parkedSlots[msg.sender].length);

        ParkedSlot storage pSlot = parkedSlots[msg.sender][_slotIndex];
        _req(pSlot.isParked && pSlot.pendingBalance > 0);

        pSlot.isParked = false;
        node.currentTier = pSlot.tier;
        node.pendingBalance = pSlot.pendingBalance;
        node.cycleStep = pSlot.cycleStep;
        recommitsDoneInCycle[msg.sender] = pSlot.cycleStep > 1 ? uint8(pSlot.cycleStep - 1) : 0;
        stepGHReceived[msg.sender] = 0;
        ext.originalBaselineTier = pSlot.originalBaselineTier;
        ext.activeSliceNeed = _capSlice(node.pendingBalance);
        lane2SliceNeed[msg.sender] = 0;

        resumedQueue.push(msg.sender);
        inResumedQueue[msg.sender] = true;
        inL1Map[msg.sender] = true;
        ext.isInQueue = true;
        ext.currentLane = 1;
        ext.activeWindowExpiry = 0;

        _recordTx(msg.sender, 6, pSlot.tier);
    }

    function _settleSeekerPayout(address _seekerAddr, uint256 _payout, uint8 _lane, bool _ejectSeeker) internal {
        Node storage seeker = nodes[_seekerAddr];
        NodeExtended storage sExt = _nodeExt[_seekerAddr];

        usdtToken.transfer(_seekerAddr, _payout);
        seeker.totalGHReceived += _payout;
        stepGHReceived[_seekerAddr] += _payout;
        lastPayoutAmount[_seekerAddr] = _payout;
        seeker.pendingBalance = seeker.pendingBalance >= _payout ? (seeker.pendingBalance - _payout) : 0;
        _recordTx(_seekerAddr, 3, _payout);

        if (_ejectSeeker) {
            seeker.hasPendingLOH = true;
            if (seeker.cooldownExpiry > block.timestamp) {
                pausedCooldownRemaining[_seekerAddr] = seeker.cooldownExpiry - block.timestamp;
                seeker.cooldownExpiry = 0;
            }
            if (_lane == 1) {
                inL1Map[_seekerAddr] = false;
                inResumedQueue[_seekerAddr] = false;
                // Move any unpaid balance into L2 immediately. LOH is not
                // required for this first L2 entry after an L1 payout.
                if (seeker.pendingBalance > 0) {
                    if (!inL2Map[_seekerAddr]) _enqueueL2(_seekerAddr);
                    if (lane2SliceNeed[_seekerAddr] == 0) {
                        lane2SliceNeed[_seekerAddr] = _capL2Slice(seeker.pendingBalance);
                    }
                }
                sExt.activeSliceNeed = lane2SliceNeed[_seekerAddr];
            } else {
                bool wasL2Head = lane2Head < surplusQueue.length && _isActiveL2QueueEntry(lane2Head, _seekerAddr);
                _setL2Status(_seekerAddr, false);
                if (wasL2Head) lane2Head++;
                lane2SliceNeed[_seekerAddr] = 0;
                if (!inL1Map[_seekerAddr]) sExt.activeSliceNeed = 0;
            }
            _syncQueueFlags(_seekerAddr);
            sExt.activeWindowExpiry = block.timestamp + ACTIVENESS_WINDOW;
        } else {
            if (_lane == 1) {
                sExt.activeSliceNeed -= _payout;
            } else {
                lane2SliceNeed[_seekerAddr] -= _payout;
                if (!inL1Map[_seekerAddr]) sExt.activeSliceNeed = lane2SliceNeed[_seekerAddr];
                if (seeker.cooldownExpiry <= block.timestamp && pausedCooldownRemaining[_seekerAddr] == 0 && recommitsDoneInCycle[_seekerAddr] < 2 && stepGHReceived[_seekerAddr] >= getExpectedRecommit(_seekerAddr)) {
                    seeker.cycleStep = recommitsDoneInCycle[_seekerAddr] == 0 ? 2 : 3;
                }
            }
        }
        emit PayoutDispatched(_seekerAddr, _payout, seeker.pendingBalance, _lane);
    }

    function _dispatchAndQueue(address _donor, uint256 _cashToDispatch, uint256 _seekerEntitlement) internal returns (address) {
        uint256 rem = _cashToDispatch;
        address firstSeeker = address(0);

        for (uint256 loops = 0; rem > 0 && loops < 128; loops++) {
            _advanceStaleHeads();
            (address activeSeeker, bool isL1) = _peekNextSeeker(_donor);
            if (activeSeeker == address(0) || activeSeeker == _donor) break;
            if (firstSeeker == address(0)) firstSeeker = activeSeeker;

            Node storage seeker = nodes[activeSeeker];
            NodeExtended storage sExt = _nodeExt[activeSeeker];

            if (isL1) {
                if (sExt.activeSliceNeed == 0) sExt.activeSliceNeed = _capSlice(seeker.pendingBalance);
                uint256 need = sExt.activeSliceNeed;
                uint256 pay = rem >= need ? need : rem;
                rem -= pay;
                _settleSeekerPayout(activeSeeker, pay, 1, true);
            } else {
                if (lane2SliceNeed[activeSeeker] == 0) lane2SliceNeed[activeSeeker] = _capL2Slice(seeker.pendingBalance);
                uint256 need = lane2SliceNeed[activeSeeker];
                if (rem >= need) {
                    rem -= need;
                    _settleSeekerPayout(activeSeeker, need, 2, true);
                } else {
                    uint256 part = rem;
                    rem = 0;
                    _settleSeekerPayout(activeSeeker, part, 2, false);
                    break;
                }
            }
        }

        if (rem > 0) usdtToken.transfer(safetyNetVault, rem);

        Node storage donorNode = nodes[_donor];
        NodeExtended storage dExt = _nodeExt[_donor];

        donorNode.pendingBalance += _seekerEntitlement;
        uint256 newL1Slice = _capSlice(donorNode.pendingBalance);
        dExt.activeSliceNeed = newL1Slice;

        uint256 remAfterL1 = donorNode.pendingBalance > newL1Slice ? (donorNode.pendingBalance - newL1Slice) : 0;
        if (remAfterL1 == 0) {
            _setL2Status(_donor, false);
            lane2SliceNeed[_donor] = 0;
        } else {
            if (!inL2Map[_donor]) _enqueueL2(_donor);
            lane2SliceNeed[_donor] = _capL2Slice(remAfterL1);
        }

        if (!inL1Map[_donor]) { newcomerQueue.push(_donor); inL1Map[_donor] = true; }
        dExt.currentLane = 1;
        dExt.isInQueue = true;

        _advanceStaleHeads();
        return firstSeeker;
    }

    function _advanceSeekerCycleState(address _seeker) internal {
        Node storage seeker = nodes[_seeker];
        NodeExtended storage sExt = _nodeExt[_seeker];
        if (recommitsDoneInCycle[_seeker] < 2) {
            seeker.cycleStep = recommitsDoneInCycle[_seeker] == 0 ? 2 : 3;
            seeker.cooldownExpiry = 0;
            sExt.activeWindowExpiry = seeker.pendingBalance == 0 ? (block.timestamp + ACTIVENESS_WINDOW) : 0;
        } else {
            seeker.cycleStep = 1;
            recommitsDoneInCycle[_seeker] = 0;
            sExt.activeWindowExpiry = 0;
            seeker.cooldownExpiry = block.timestamp + CYCLE_COOLDOWN;
            if (_seeker != operationsWallet) cycleTaskCleared[_seeker] = false;
        }
    }

    function _peekNextSeeker(address _excludeDonor) internal view returns (address, bool) {
        for (uint256 i = resumedHead; i < resumedQueue.length; i++) {
            address u = resumedQueue[i];
            if (inResumedQueue[u] && _isValidL1(u) && u != _excludeDonor) return (u, true);
        }
        for (uint256 i = lane1Head; i < newcomerQueue.length; i++) {
            address u = newcomerQueue[i];
            if (_isValidL1(u) && u != _excludeDonor) return (u, true);
        }
        for (uint256 j = lane2Head; j < surplusQueue.length; j++) {
            address u = surplusQueue[j];
            if (_isActiveL2QueueEntry(j, u) && _isValidL2(u) && u != _excludeDonor) return (u, false);
        }
        return (address(0), false);
    }

    function _isNodeBonusEligible(address _node, uint8 _level) internal view returns (bool) {
        if (_node == address(0)) return false;
        if (_node == operationsWallet) return true;

        Node storage n = nodes[_node];
        NodeExtended storage e = _nodeExt[_node];

        if (!n.isActive || !n.hasProvidedHelp) return false;
        if (e.activeWindowExpiry > 0 && block.timestamp > e.activeWindowExpiry) return false;
        if (n.cooldownExpiry > 0 && block.timestamp > n.cooldownExpiry + GRACE_PERIOD) return false;

        bool inActiveCooldownWindow = (n.cooldownExpiry > 0 && block.timestamp <= n.cooldownExpiry + GRACE_PERIOD) || pausedCooldownRemaining[_node] > 0;
        if (!inActiveCooldownWindow && !cycleTaskCleared[_node]) return false;

        if (_level >= 2) {
            if (!n.isGraduated) return false;
            if (_level <= 3 && e.rank < 1) return false;
            if (_level >= 4 && _level <= 6 && e.rank < 2) return false;
            if (_level >= 7 && e.rank < 3) return false;
        }
        return true;
    }

    function _updateLeadershipRank(address _node) internal {
        if (!nodes[_node].isGraduated) return;
        NodeExtended storage e = _nodeExt[_node];
        uint8 newRank = e.rank;

        if (e.directCount >= 50 && e.directVolume >= 100_000 * 10**18 && e.verifiedPillarsCount >= 3) newRank = 3;
        else if (e.directCount >= 25 && e.directVolume >= 25_000 * 10**18 && e.verifiedPillarsCount >= 2 && newRank < 2) newRank = 2;
        else if (e.directCount >= 10 && e.directVolume >= 5_000 * 10**18 && e.verifiedPillarsCount >= 1 && newRank < 1) newRank = 1;

        if (newRank > e.rank) e.rank = newRank;
    }

    function _pullFromSafetyVault(address _recipient, uint256 _amount) internal {
        uint256 vaultBal = usdtToken.balanceOf(safetyNetVault);
        uint256 payout = _amount > vaultBal ? vaultBal : _amount;
        _req(payout > 0);
        try ISafetyNetVault(safetyNetVault).protocolExecuteRestitution(_recipient, payout) {}
        catch { usdtToken.transferFrom(safetyNetVault, _recipient, payout); }
    }

    function _claimDeficitInternal() internal {
        Node storage sNode = nodes[msg.sender];
        NodeExtended storage sExt = _nodeExt[msg.sender];
        _req(sNode.isActive && !sExt.hasClaimedRestitution && sNode.totalGHReceived < sNode.totalPHProvided);
        sExt.hasClaimedRestitution = true;
        _pullFromSafetyVault(msg.sender, sNode.totalPHProvided - sNode.totalGHReceived);
    }

    function claimEmergencyRelief() external {
        uint256 start = lastProtocolActivityTime + DORMANT_THRESHOLD;
        _req(block.timestamp >= start && block.timestamp <= start + RELIEF_CLAIM_WINDOW);
        _claimDeficitInternal();
    }

    function claimRestitution() external {
        _req(sunsetReached);
        _claimDeficitInternal();
    }

    function sweepSurplusToOperations() external {
        _req(msg.sender == operationsWallet && (block.timestamp > lastProtocolActivityTime + DORMANT_THRESHOLD + RELIEF_CLAIM_WINDOW || sunsetReached));
        _pullFromSafetyVault(operationsWallet, usdtToken.balanceOf(safetyNetVault));
    }

    function distributeManagerSurplus(address[] calldata _managers, uint256[] calldata _amounts) external {
        _req(msg.sender == operationsWallet && sunsetReached && !managerSurplusDistributed && _managers.length == _amounts.length);
        managerSurplusDistributed = true;
        for (uint256 i = 0; i < _managers.length; i++) {
            _req(_nodeExt[_managers[i]].rank == 3);
            _pullFromSafetyVault(_managers[i], _amounts[i]);
        }
    }

    function _extractPillar(string calldata _title) internal pure returns (uint8) {
        bytes memory b = bytes(_title);
        if (b.length >= 8) {
            if (b[7] == "2") return 2;
            if (b[7] == "3") return 3;
            if (b[7] == "4") return 4;
        }
        return 1;
    }

    function _recordPillarCompletion(address _user, uint8 _pillar) internal {
        uint8 bit = uint8(1 << (_pillar - 1));
        uint8 mask = completedPillarsMask[_user];
        if ((mask & bit) == 0) {
            mask |= bit;
            completedPillarsMask[_user] = (mask == 15) ? 0 : mask;
        }
        cycleTaskCleared[_user] = true;
        _nodeExt[_user].verifiedPillarsCount += 1;
        _updateLeadershipRank(_user);
    }

    function submitTask(string calldata _taskTitle, string calldata _proofLink) external {
        _req(!sunsetReached);
        bytes32 linkHash = keccak256(bytes(_proofLink));
        require(bytes(_proofLink).length > 8 && !usedProofLinks[linkHash]);
        usedProofLinks[linkHash] = true;

        uint8 pillar = _extractPillar(_taskTitle);
        bool isClearance = (completedPillarsMask[msg.sender] & uint8(1 << (pillar - 1))) == 0;

        taskPillarType[_tasks.length] = pillar;
        _tasks.push(TaskSubmission(msg.sender, _taskTitle, _proofLink, 0, 0, false, 0, 0, false, isClearance));
        _recordTx(msg.sender, 9, uint256(pillar) * 10**18);
    }

    function likeTask(uint256 _taskId) external {
        _req(!sunsetReached && _taskId < _tasks.length && !_tasks[_taskId].isRejected && !hasLikedTask[_taskId][msg.sender]);
        hasLikedTask[_taskId][msg.sender] = true;
        _tasks[_taskId].likeCount += 1;
    }

    function tipTask(uint256 _taskId, uint256 _amount) external {
        _req(!sunsetReached && _taskId < _tasks.length && _amount > 0);
        TaskSubmission storage sub = _tasks[_taskId];
        _req(!sub.isRejected && sub.performer != msg.sender && !hasTippedTask[_taskId][msg.sender]);

        _req(usdtToken.transferFrom(msg.sender, address(this), _amount));
        uint256 toPerformer = (_amount * 70) / 100;

        usdtToken.transfer(sub.performer, toPerformer);
        usdtToken.transfer(safetyNetVault, _amount - toPerformer);

        sub.tipCount += 1;
        sub.totalTipsCollected += _amount;
        hasTippedTask[_taskId][msg.sender] = true;
        _recordTx(msg.sender, 12, _amount);
        _recordTx(sub.performer, 12, toPerformer);
    }

    function verifyTask(uint256 _taskId) external {
        _onlyTaskVerifierOrAuditor();
        _req(_taskId < _tasks.length);
        TaskSubmission storage sub = _tasks[_taskId];
        _req(!sub.isRejected && !sub.isVerified);

        sub.isVerified = true;
        sub.verifiedAt = block.timestamp;

        uint8 pType = taskPillarType[_taskId];
        if (sub.isClearanceTask) _recordPillarCompletion(sub.performer, pType);
        else cycleTaskCleared[sub.performer] = true;

        _recordTx(sub.performer, 10, uint256(pType) * 10**18);
    }

    function rejectTask(uint256 _taskId, string calldata) external {
        _onlyTaskVerifierOrAuditor();
        _req(_taskId < _tasks.length && !_tasks[_taskId].isVerified);
        _tasks[_taskId].isRejected = true;
        _recordTx(_tasks[_taskId].performer, 11, uint256(taskPillarType[_taskId]) * 10**18);
    }

    function autoGraduateSchool() external {
        _req(!sunsetReached);
        nodes[msg.sender].isGraduated = true;
        _updateLeadershipRank(msg.sender);
        _recordTx(msg.sender, 8, 0);
    }

    function payFastPass(uint256 _feeAmount, string calldata _purpose) external {
        _req(!sunsetReached);
        bytes32 pHash = keccak256(bytes(_purpose));

        if (pHash == keccak256(bytes("EMERGENCY_GRACE_1H"))) {
            Node storage n = nodes[msg.sender];
            NodeExtended storage e = _nodeExt[msg.sender];
            bool inCoolWin = n.cooldownExpiry > 0 && block.timestamp <= n.cooldownExpiry + GRACE_PERIOD;
            bool inActWin = e.activeWindowExpiry > 0 && block.timestamp <= e.activeWindowExpiry;
            _req(n.hasProvidedHelp && (inCoolWin || inActWin));

            _req(_feeAmount > 0 && usdtToken.transferFrom(msg.sender, safetyNetVault, _feeAmount));
            _recordTx(msg.sender, 7, _feeAmount);

            if (inCoolWin) n.cooldownExpiry += GRACE_PERIOD;
            else e.activeWindowExpiry += GRACE_PERIOD;
            return;
        }

        _req(_feeAmount > 0 && usdtToken.transferFrom(msg.sender, safetyNetVault, _feeAmount));
        _recordTx(msg.sender, 7, _feeAmount);

        if (pHash == keccak256(bytes("LOH_FAST_PASS"))) {
            _handleLOHUnlock(msg.sender);
        } else if (pHash == keccak256(bytes("BUNDLE_FAST_PASS"))) {
            completedPillarsMask[msg.sender] = 0;
            cycleTaskCleared[msg.sender] = true;
            _nodeExt[msg.sender].verifiedPillarsCount += 4;
            _updateLeadershipRank(msg.sender);
        } else {
            _recordPillarCompletion(msg.sender, _extractPillar(_purpose));
        }
    }

    function getLaneQueues() public view returns (address[] memory lane1, address[] memory lane2) {
        uint256 l1Count = 0;
        for (uint256 i = resumedHead; i < resumedQueue.length; i++) if (inResumedQueue[resumedQueue[i]] && _isQueuedL1(resumedQueue[i])) l1Count++;
        for (uint256 i = lane1Head; i < newcomerQueue.length; i++) {
            address u = newcomerQueue[i];
            if (!inResumedQueue[u] && _isQueuedL1(u)) l1Count++;
        }
        uint256 l2Count = 0;
        for (uint256 j = lane2Head; j < surplusQueue.length; j++) if (_isActiveL2QueueEntry(j, surplusQueue[j]) && _isQueuedL2(surplusQueue[j])) l2Count++;
        lane1 = new address[](l1Count);
        lane2 = new address[](l2Count);
        uint256 k1 = 0;
        for (uint256 i = resumedHead; i < resumedQueue.length; i++) {
            address u = resumedQueue[i];
            if (inResumedQueue[u] && _isQueuedL1(u)) lane1[k1++] = u;
        }
        for (uint256 i = lane1Head; i < newcomerQueue.length; i++) {
            address u = newcomerQueue[i];
            if (!inResumedQueue[u] && _isQueuedL1(u)) lane1[k1++] = u;
        }
        uint256 k2 = 0;
        for (uint256 j = lane2Head; j < surplusQueue.length; j++) if (_isActiveL2QueueEntry(j, surplusQueue[j]) && _isQueuedL2(surplusQueue[j])) lane2[k2++] = surplusQueue[j];
    }

    function getProtocolStats() external view returns (
        uint256 protocolVolume,
        uint256 registeredNodes,
        uint256 launchedAt,
        bool sunset,
        uint256 lastActivity
    ) {
        return (totalProtocolVolume, totalRegisteredNodes, launchTimestamp, sunsetReached, lastProtocolActivityTime);
    }

    function getQueueLength() public view returns (uint256) {
        (address[] memory l1, address[] memory l2) = getLaneQueues();
        return l1.length + l2.length;
    }

    function fifoQueue(uint256 _index) external view returns (address) {
        (address[] memory l1, address[] memory l2) = getLaneQueues();
        _req(_index < l1.length + l2.length);
        return _index < l1.length ? l1[_index] : l2[_index - l1.length];
    }

    function getAllRegisteredNodes() external view returns (address[] memory) {
        return allRegisteredNodes;
    }

    function getParkedSlots(address _account) external view returns (ParkedSlot[] memory) {
        return parkedSlots[_account];
    }

    function getUserTxHistory(address _account) external view returns (UserTxRecord[] memory) {
        return userTxHistory[_account];
    }

    function getNode(address account) external view returns (Node memory) {
        return nodes[account];
    }

    // function nodeExt(address account) external view returns (NodeExtended memory) {
    //     return _nodeExt[account];
    // }

    // function taskSubmissions(uint256 _id) external view returns (TaskSubmission memory) {
    //     return _tasks[_id];
    // }

    function getNodeTaskState(address _account) external view returns (bool isCycleCleared, uint8 pillarsMask, uint256 lastPayout) {
        return (cycleTaskCleared[_account], completedPillarsMask[_account], lastPayoutAmount[_account]);
    }

    function getTaskSubmissionsCount() external view returns (uint256) {
        return _tasks.length;
    }
}
